//
//  fanController.swift
//  Sensors
//
//  Created on 08/06/2026.
//

import Foundation
import AppKit
import Kit

/// Narrow protocol for what FanCurveController needs from SMCHelper.
/// Lets tests inject a fake.
public protocol FanCurveHelper: AnyObject {
    func isActive() -> Bool
    func setFanMode(id: Int, mode: Int)
    func setFanSpeed(id: Int, value: Int)
}

#if DEBUG
public final class FakeFanCurveHelper: FanCurveHelper {
    public struct ModeCall: Equatable { public let id: Int; public let mode: Int }
    public struct SpeedCall: Equatable { public let id: Int; public let rpm: Int }

    public var isActiveValue: Bool = true
    public private(set) var modeCalls: [ModeCall] = []
    public private(set) var speedCalls: [SpeedCall] = []

    public init() {}
    public func isActive() -> Bool { isActiveValue }
    public func setFanMode(id: Int, mode: Int) { modeCalls.append(.init(id: id, mode: mode)) }
    public func setFanSpeed(id: Int, value: Int) { speedCalls.append(.init(id: id, rpm: value)) }
    public func reset() { modeCalls.removeAll(); speedCalls.removeAll() }
}
#endif

/// Injected clock so time-windowed controller behaviors (sample-window pruning,
/// derivative computation, battery-hot dwell timer) are deterministic in tests.
public protocol FanControllerClock: AnyObject { func now() -> Date }

public final class SystemFanControllerClock: FanControllerClock {
    public init() {}
    public func now() -> Date { Date() }
}

#if DEBUG
public final class FakeFanControllerClock: FanControllerClock {
    public var current: Date
    public init(_ current: Date = Date(timeIntervalSince1970: 1_000_000)) { self.current = current }
    public func now() -> Date { current }
    public func advance(by seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
}
#endif

public final class FanCurveController {
    private let helper: FanCurveHelper
    private let store: ProfileStore
    private let clock: FanControllerClock
    private var managedFans: Set<Int> = []
    private var lastApplied: [Int: Int] = [:]
    private var lastTempForHyst: [Int: Double] = [:]
    private var isAsleep: Bool = false
    private var didBootstrap: Bool = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// Recent (timestamp, effective-temp) samples — used both for median
    /// smoothing of the current reading and for the rising-temp derivative
    /// pre-ramp bonus. Anything older than `sampleWindowSeconds` is pruned
    /// each tick. Reset on profile change / sleep / wake / relinquish so a
    /// stale sample can never bias a fresh session's first decision.
    private var tempSamples: [(ts: Date, temp: Double)] = []
    private static let sampleWindowSeconds: TimeInterval = 5.0
    private static let derivativeWindowSeconds: TimeInterval = 2.0
    private static let derivativeThresholdCPerSec: Double = 2.0
    private static let derivativeBonusRPM: Int = 500

    /// First clock instant at which a battery sensor exceeded
    /// `batterySafetyTempC`. nil while battery is cool, or after a drop below
    /// threshold clears it. Once dwell ≥ `batterySafetyDelaySeconds`, the
    /// per-fan target is forced to at least `batterySafetyFloorRPM`.
    private var batteryHotSince: Date? = nil
    private static let batterySafetyTempC: Double = 40.0
    private static let batterySafetyDelaySeconds: TimeInterval = 30.0
    private static let batterySafetyFloorRPM: Int = 2500
    private static let batteryKeys: Set<String> = [
        "TB1T", "TB2T", "Battery 1", "Battery 2", "Battery", "gas gauge battery"
    ]

    /// All mutable state above is guarded by this lock. tick() runs on the
    /// SensorsReader's background queue; sleep/wake/profile-change observers
    /// run on .main. Swift Dictionary is not thread-safe — concurrent read/write
    /// can crash or corrupt without this lock.
    private let stateLock = NSLock()

    public init(helper: FanCurveHelper, store: ProfileStore,
                clock: FanControllerClock = SystemFanControllerClock()) {
        self.helper = helper
        self.store = store
        self.clock = clock
        let workspaceNC = NSWorkspace.shared.notificationCenter
        observers.append((workspaceNC, workspaceNC.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.handleWillSleep()
        }))
        observers.append((workspaceNC, workspaceNC.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.handleDidWake()
        }))
        let defaultNC = NotificationCenter.default
        observers.append((defaultNC, defaultNC.addObserver(
            forName: .fanProfileChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.stateLock.lock()
            self.lastApplied.removeAll()
            self.lastTempForHyst.removeAll()
            self.tempSamples.removeAll()
            self.batteryHotSince = nil
            self.stateLock.unlock()
        }))
    }

    deinit {
        for (center, token) in observers { center.removeObserver(token) }
    }

    private func handleWillSleep() {
        stateLock.lock()
        isAsleep = true
        relinquishLocked()
        stateLock.unlock()
    }

    private func handleDidWake() {
        stateLock.lock()
        isAsleep = false
        // First post-wake tick must not inherit pre-sleep derivative or
        // smoothed temp — those samples are minutes/hours stale by wallclock.
        tempSamples.removeAll()
        batteryHotSince = nil
        stateLock.unlock()
    }

    #if DEBUG
    public func handleWillSleepForTests() { handleWillSleep() }
    public func handleDidWakeForTests() { handleDidWake() }
    #endif

    public func tick(snapshot: Sensors_List?) {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard !isAsleep,
              helper.isActive(),
              let snapshot = snapshot else { return }

        let fans = snapshot.sensors.compactMap { $0 as? Fan }
        if !didBootstrap, !fans.isEmpty {
            let maxRpm = Int(fans.map(\.maxSpeed).max() ?? 7000)
            store.bootstrapIfNeeded(fanCount: fans.count, defaultMaxRPM: maxRpm)
            didBootstrap = true
        }

        guard let profile = store.activeProfile(),
              !profile.points.isEmpty else {
            relinquishLocked()
            return
        }

        guard let effTemp = FanCurve.effectiveTemperature(
            sensors: snapshot.sensors, drivers: profile.drivers) else {
            // Drivers no longer match any sensor — release management so the
            // fan returns to firmware automatic instead of being stuck at the
            // last applied RPM.
            relinquishLocked()
            return
        }

        let now = clock.now()
        tempSamples.append((ts: now, temp: effTemp))
        tempSamples.removeAll(where: { now.timeIntervalSince($0.ts) > Self.sampleWindowSeconds })
        // Median of the last (up to) 3 in-window samples — kills single-tick
        // HID jitter spikes that would otherwise bounce fans up/down.
        let smoothedTemp = Self.median(tempSamples.suffix(3).map(\.temp))
        let derivative = computeDerivative(now: now)
        let derivativeBonus = (derivative >= Self.derivativeThresholdCPerSec)
            ? Self.derivativeBonusRPM : 0
        let batteryFloor = computeBatterySafetyFloor(snapshot: snapshot, now: now)

        for fan in fans {
            let base = FanCurve.interpolate(points: profile.points, tempC: smoothedTemp)
            let off = (fan.id == 0) ? 0 : profile.fanOffsetRPM
            // Clamp to fan limits AFTER adding offset + derivative bonus, then
            // raise to the battery floor (also clamped to maxSpeed so a hot
            // battery on a slow fan can't exceed mechanical limit).
            let raw = base + off + derivativeBonus
            var target = clamp(raw, Int(fan.minSpeed), Int(fan.maxSpeed))
            if batteryFloor > 0 {
                target = max(target, min(batteryFloor, Int(fan.maxSpeed)))
            }
            applyIfNeeded(fan: fan, target: target, temp: smoothedTemp,
                          hysteresisC: profile.hysteresisC,
                          deltaThreshold: profile.deltaRpmThreshold)
        }
    }

    /// dT/dt over the most recent `derivativeWindowSeconds` of samples.
    /// Returns 0 if fewer than 2 samples or zero elapsed time.
    private func computeDerivative(now: Date) -> Double {
        let cutoff = now.addingTimeInterval(-Self.derivativeWindowSeconds)
        let recent = tempSamples.filter { $0.ts >= cutoff }
        guard let first = recent.first, let last = recent.last, first.ts != last.ts else { return 0 }
        let dt = last.ts.timeIntervalSince(first.ts)
        guard dt > 0 else { return 0 }
        return (last.temp - first.temp) / dt
    }

    /// Returns the battery safety floor in RPM (0 = no floor).
    /// Floor engages only after `batterySafetyDelaySeconds` of sustained heat
    /// so a brief surface spike doesn't spin fans up unnecessarily.
    private func computeBatterySafetyFloor(snapshot: Sensors_List, now: Date) -> Int {
        let battTemps = snapshot.sensors
            .filter { Self.batteryKeys.contains($0.key) && $0.type == .temperature }
            .map(\.value)
        guard let maxBatt = battTemps.max() else {
            batteryHotSince = nil
            return 0
        }
        if maxBatt < Self.batterySafetyTempC {
            batteryHotSince = nil
            return 0
        }
        if batteryHotSince == nil {
            batteryHotSince = now
            return 0
        }
        if now.timeIntervalSince(batteryHotSince!) >= Self.batterySafetyDelaySeconds {
            return Self.batterySafetyFloorRPM
        }
        return 0
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
    }

    #if DEBUG
    /// Test hook — exposes the private median helper without leaking internals
    /// at release. Tests assert median behavior directly rather than only via
    /// emergent smoothing output.
    public static func _medianForTests(_ values: [Double]) -> Double { median(values) }
    #endif

    private func applyIfNeeded(fan: Fan, target: Int, temp: Double,
                               hysteresisC: Double, deltaThreshold: Int) {
        // User has taken manual control (Manual/Off/Max from popup) — yield.
        if fan.customMode == .forced {
            managedFans.remove(fan.id)
            lastApplied.removeValue(forKey: fan.id)
            lastTempForHyst.removeValue(forKey: fan.id)
            return
        }
        if !managedFans.contains(fan.id) {
            helper.setFanMode(id: fan.id, mode: FanMode.forced.rawValue)
            // Record Stats-controlled state so popup and willTerminate know not
            // to override us, and so relinquish on next launch can clean up
            // crashed sessions.
            Store.shared.set(key: "fan_\(fan.id)_mode", value: FanMode.curve.rawValue)
            managedFans.insert(fan.id)
        }
        let last = lastApplied[fan.id]
        let lastTemp = lastTempForHyst[fan.id] ?? -.greatestFiniteMagnitude

        if let last = last {
            let isLowering = target < last
            if isLowering && (lastTemp - temp) < hysteresisC {
                return
            }
            if abs(target - last) < deltaThreshold {
                return
            }
        }

        helper.setFanSpeed(id: fan.id, value: target)
        lastApplied[fan.id] = target
        lastTempForHyst[fan.id] = temp
    }

    public func shutdown() {
        stateLock.lock()
        relinquishLocked()
        stateLock.unlock()
    }

    /// Caller MUST hold `stateLock`.
    private func relinquishLocked() {
        for id in managedFans {
            // Don't fight a user who picked Manual/Off/Max — they own this fan.
            let raw = Store.shared.int(key: "fan_\(id)_mode", defaultValue: -1)
            if raw == FanMode.forced.rawValue { continue }
            helper.setFanMode(id: id, mode: FanMode.automatic.rawValue)
            Store.shared.set(key: "fan_\(id)_mode", value: FanMode.automatic.rawValue)
        }
        managedFans.removeAll()
        lastApplied.removeAll()
        lastTempForHyst.removeAll()
        tempSamples.removeAll()
        batteryHotSince = nil
    }

    private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        max(lo, min(hi, v))
    }
}

/// Bridges the existing `Kit.SMCHelper` to the narrow `FanCurveHelper` protocol.
///
/// `isActive` checks for the privileged helper FILE on disk, NOT the XPC connection
/// state. The connection is lazily established by SMCHelper on the first
/// `setFanMode`/`setFanSpeed` call, so checking `SMCHelper.shared.isActive()` here
/// would be a chicken-and-egg deadlock — the controller would never call the helper
/// and the connection would never form.
public final class SMCHelperAdapter: FanCurveHelper {
    public static let shared = SMCHelperAdapter()
    private static let helperPath = "/Library/PrivilegedHelperTools/eu.exelban.Stats.SMC.Helper"
    public init() {}
    public func isActive() -> Bool {
        FileManager.default.fileExists(atPath: Self.helperPath)
    }
    public func setFanMode(id: Int, mode: Int) {
        SMCHelper.shared.setFanMode(id, mode: mode)
    }
    public func setFanSpeed(id: Int, value: Int) {
        SMCHelper.shared.setFanSpeed(id, speed: value)
    }
}
