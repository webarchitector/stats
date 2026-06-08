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

public final class FanCurveController {
    private let helper: FanCurveHelper
    private let store: ProfileStore
    private var managedFans: Set<Int> = []
    private var lastApplied: [Int: Int] = [:]
    private var lastTempForHyst: [Int: Double] = [:]
    private var isAsleep: Bool = false
    private var didBootstrap: Bool = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// All mutable state above is guarded by this lock. tick() runs on the
    /// SensorsReader's background queue; sleep/wake/profile-change observers
    /// run on .main. Swift Dictionary is not thread-safe — concurrent read/write
    /// can crash or corrupt without this lock.
    private let stateLock = NSLock()

    public init(helper: FanCurveHelper, store: ProfileStore) {
        self.helper = helper
        self.store = store
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

        for fan in fans {
            let base = FanCurve.interpolate(points: profile.points, tempC: effTemp)
            let off = (fan.id == 0) ? 0 : profile.fanOffsetRPM
            let target = clamp(base + off, Int(fan.minSpeed), Int(fan.maxSpeed))
            applyIfNeeded(fan: fan, target: target, temp: effTemp,
                          hysteresisC: profile.hysteresisC,
                          deltaThreshold: profile.deltaRpmThreshold)
        }
    }

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
