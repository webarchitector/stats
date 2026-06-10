//
//  FanCurveEngine.swift
//  FanCore
//
//  Created on 2026-06-09.
//
//  Pure-logic body of the curve controller. Decoupled from AppKit, Kit.Store,
//  ProfileStore, and NSWorkspace observers — the app's `FanCurveController`
//  wraps this and installs the OS-level hooks; the daemon (Phase 3) will wrap
//  it with its own sleep/wake + profile-change plumbing.
//

import Foundation

public final class FanCurveEngine {
    private let helper: FanCurveHelper
    private let takeover: TakeoverStore
    private let clock: FanCoreClock
    private let logger: FanCoreLogger

    private var activeProfile: FanProfile? = nil
    private var profiles: [FanProfile] = []

    private var managedFans: Set<Int> = []
    private var lastApplied: [Int: Int] = [:]
    private var lastTempForHyst: [Int: Double] = [:]
    private var isAsleep: Bool = false

    /// Recent (timestamp, effective-temp) samples — used both for median
    /// smoothing of the current reading and for the rising-temp derivative
    /// pre-ramp bonus. Anything older than `sampleWindowSeconds` is pruned
    /// each tick. Reset on profile change / sleep / wake / relinquish so a
    /// stale sample can never bias a fresh session's first decision.
    private var tempSamples: [(ts: Date, temp: Double)] = []
    // Tunable per instance because tick cadence differs: the daemon ticks every
    // 5s, the in-app controller ~1s. Defaults suit ~1s ticks; the daemon passes
    // wider windows so the 3-sample median and the derivative pre-ramp still see
    // enough samples at its slower cadence. The derivative is a rate (°C/s), so
    // the threshold below is cadence-independent and stays a shared constant —
    // a sustained rise yields the same rate whether sampled over 2s or 10s.
    private let sampleWindowSeconds: TimeInterval
    private let derivativeWindowSeconds: TimeInterval
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
    // Sensor KEYS (not display names) that report battery temperature.
    // Intel: TB0T/TB1T/TB2T; Apple Silicon HID exposes "gas gauge battery".
    private static let batteryKeys: Set<String> = [
        "TB0T", "TB1T", "TB2T", "gas gauge battery"
    ]

    /// Apple-firmware override failsafe state. After we issue setFanMode(.forced)
    /// for fan id X, `lastSetMode[X] = .forced`. On the next tick we compare
    /// against the snapshot's per-fan `smcMode`. If firmware (or another
    /// process) silently reverted us to `.automatic`, `overrideStreak[X]`
    /// increments; at 3 consecutive mismatches we add X to `appleOverridden`
    /// and stop writing SMC for it for the rest of the session. Cleared on
    /// `applyProfileChange` (user picker action) and reset across process
    /// restarts (in-memory only).
    private var appleOverridden: Set<Int> = []
    private var lastSetMode: [Int: FanMode] = [:]
    private var overrideStreak: [Int: Int] = [:]
    private static let appleOverrideThreshold: Int = 3

    /// All mutable state above is guarded by this lock. tick() may be called
    /// from a background queue; sleep/wake/profile-change forwarders may be
    /// called from .main. Swift Dictionary is not thread-safe.
    private let stateLock = NSLock()

    /// Last snapshot processed by tick(). Cached so `applyProfileChange` can
    /// synchronously re-tick on user picker action instead of waiting for the
    /// next external tick. nil until the first non-sleeping, non-nil tick.
    private var lastSnapshot: EngineSnapshot? = nil

    public init(helper: FanCurveHelper,
                takeover: TakeoverStore,
                clock: FanCoreClock = SystemFanCoreClock(),
                logger: FanCoreLogger = NoopFanCoreLogger(),
                sampleWindowSeconds: TimeInterval = 5.0,
                derivativeWindowSeconds: TimeInterval = 2.0) {
        self.helper = helper
        self.takeover = takeover
        self.clock = clock
        self.logger = logger
        self.sampleWindowSeconds = sampleWindowSeconds
        self.derivativeWindowSeconds = derivativeWindowSeconds
    }

    // MARK: - External plumbing inputs

    public func setProfiles(_ profiles: [FanProfile]) {
        stateLock.lock()
        self.profiles = profiles
        stateLock.unlock()
    }

    public func setActiveProfile(_ profile: FanProfile?) {
        stateLock.lock()
        self.activeProfile = profile
        stateLock.unlock()
    }

    /// Read-only probe for the daemon's status reporter (Phase 4). True when
    /// the Apple-firmware override failsafe has quarantined this fan for the
    /// session — i.e. we last wrote `.forced` but SMC kept reverting to
    /// `.automatic` 3 ticks in a row.
    public func isAppleOverridden(fanID: Int) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return appleOverridden.contains(fanID)
    }

    /// Called by the caller's `.fanProfileChanged` observer (app side) or the
    /// equivalent profile-update notification on the daemon side. Wipes
    /// per-tick smoothing/hysteresis state so the new profile's first
    /// decision isn't biased by stale samples or the prior profile's
    /// lastApplied/lastTempForHyst values. Then synchronously applies the
    /// change against the cached snapshot — eliminates ~1s lag waiting for
    /// the next regular tick.
    public func applyProfileChange(snapshot: EngineSnapshot?) {
        stateLock.lock()
        lastApplied.removeAll()
        lastTempForHyst.removeAll()
        tempSamples.removeAll()
        batteryHotSince = nil
        // User-initiated profile change implies fresh intent — drop any
        // Apple-override quarantine so newly-relevant fans get retried.
        appleOverridden.removeAll()
        overrideStreak.removeAll()

        let newProfileIsApple = (activeProfile?.points.isEmpty ?? true)

        if newProfileIsApple {
            // Apple Auto / no curve. relinquishLocked iterates the
            // still-populated managedFans set and writes .automatic to SMC
            // for each fan we own (skipping fans whose takeover says user
            // owns it). It also clears managedFans, lastSetMode, and
            // overrideStreak at the end. CRITICAL: this MUST run before any
            // managedFans.removeAll() — otherwise the iteration is over an
            // empty set and fans stay stuck in .forced mode forever.
            relinquishLocked()
        } else {
            // Non-Apple profile. Clear managedFans + lastSetMode so the
            // immediate re-tick below re-asserts setFanMode(.forced) for
            // each fan and writes the new profile's curve to SMC.
            managedFans.removeAll()
            lastSetMode.removeAll()
        }
        stateLock.unlock()

        // Synchronously apply the new non-Apple profile in this call.
        // tick() re-acquires stateLock so the brief unlock/relock is fine.
        if !newProfileIsApple, let snapshot = snapshot {
            tick(snapshot: snapshot)
        }
    }

    public func handleWillSleep() {
        stateLock.lock()
        isAsleep = true
        relinquishLocked()
        stateLock.unlock()
    }

    public func handleDidWake() {
        stateLock.lock()
        isAsleep = false
        // First post-wake tick must not inherit pre-sleep derivative or
        // smoothed temp — those samples are minutes/hours stale by wallclock.
        tempSamples.removeAll()
        batteryHotSince = nil
        stateLock.unlock()
    }

    // MARK: - Tick

    public func tick(snapshot: EngineSnapshot?) {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard !isAsleep, let snapshot = snapshot else { return }
        lastSnapshot = snapshot

        // Helper went away mid-session — drop our state so the next valid
        // tick rebuilds cleanly.
        guard helper.isActive() else {
            if !managedFans.isEmpty {
                managedFans.removeAll()
                lastApplied.removeAll()
                lastTempForHyst.removeAll()
                tempSamples.removeAll()
                batteryHotSince = nil
                lastSetMode.removeAll()
                overrideStreak.removeAll()
            }
            return
        }

        let fans = snapshot.fans

        // Apple-override detection runs BEFORE the per-fan apply loop so that
        // this tick's writes (lastSetMode updates) don't bias the comparison.
        detectAppleOverridesLocked(fans: fans)

        guard let profile = activeProfile,
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
        tempSamples.removeAll(where: { now.timeIntervalSince($0.ts) > self.sampleWindowSeconds })
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
        let cutoff = now.addingTimeInterval(-self.derivativeWindowSeconds)
        let recent = tempSamples.filter { $0.ts >= cutoff }
        guard let first = recent.first, let last = recent.last, first.ts != last.ts else { return 0 }
        let dt = last.ts.timeIntervalSince(first.ts)
        guard dt > 0 else { return 0 }
        return (last.temp - first.temp) / dt
    }

    /// Returns the battery safety floor in RPM (0 = no floor).
    /// Floor engages only after `batterySafetyDelaySeconds` of sustained heat
    /// so a brief surface spike doesn't spin fans up unnecessarily.
    private func computeBatterySafetyFloor(snapshot: EngineSnapshot, now: Date) -> Int {
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

    /// Compare every fan we last wrote `.forced` to against its current
    /// `smcMode` (per-tick SMC refresh). After `appleOverrideThreshold`
    /// consecutive ticks of finding `.automatic` where we asked for `.forced`,
    /// the fan is considered hijacked by firmware and relinquished for this
    /// session — no more SMC writes for it until profile change / restart.
    /// nil `smcMode` (SMC read failed) leaves the streak unchanged.
    /// Caller MUST hold `stateLock`.
    private func detectAppleOverridesLocked(fans: [FanSnapshot]) {
        for fan in fans {
            guard lastSetMode[fan.id] == .forced else { continue }
            guard let smcMode = fan.smcMode else { continue }
            if smcMode == .forced {
                overrideStreak[fan.id] = 0
                continue
            }
            // Any automatic mode counts as a firmware revert — `.automatic` (0)
            // OR `.auto3` (3). Don't depend on callers collapsing auto3 first;
            // a raw auto3 here would otherwise freeze the streak and silently
            // disable the failsafe.
            if smcMode.isAutomatic {
                let streak = (overrideStreak[fan.id] ?? 0) + 1
                if streak >= Self.appleOverrideThreshold {
                    logger.info("Apple firmware overrode fan \(fan.id), relinquishing for this session")
                    appleOverridden.insert(fan.id)
                    managedFans.remove(fan.id)
                    lastApplied.removeValue(forKey: fan.id)
                    lastTempForHyst.removeValue(forKey: fan.id)
                    lastSetMode.removeValue(forKey: fan.id)
                    overrideStreak.removeValue(forKey: fan.id)
                } else {
                    overrideStreak[fan.id] = streak
                }
            }
        }
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
    }

    #if DEBUG
    /// Test hook — exposes the private median helper without leaking internals
    /// at release.
    public static func _medianForTests(_ values: [Double]) -> Double { median(values) }
    #endif

    private func applyIfNeeded(fan: FanSnapshot, target: Int, temp: Double,
                               hysteresisC: Double, deltaThreshold: Int) {
        // Apple thermal firmware kept reverting our `.forced` write — fan was
        // relinquished for this session. Stay out of its way.
        if appleOverridden.contains(fan.id) { return }
        // User has taken manual control (Manual/Off/Max from popup, etc.) — yield.
        if fan.userTookOver {
            managedFans.remove(fan.id)
            lastApplied.removeValue(forKey: fan.id)
            lastTempForHyst.removeValue(forKey: fan.id)
            return
        }
        if !managedFans.contains(fan.id) {
            helper.setFanMode(id: fan.id, mode: FanMode.forced.rawValue)
            // Record Stats-controlled state so the app/daemon can find
            // managed fans on crash recovery / restart shutdown.
            takeover.setStatsManaged(fan: fan.id)
            managedFans.insert(fan.id)
            // Record successful `.forced` write so next tick's
            // detectAppleOverridesLocked can spot a silent revert by firmware.
            lastSetMode[fan.id] = .forced
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
            if takeover.userTookOver(fan: id) { continue }
            helper.setFanMode(id: id, mode: FanMode.automatic.rawValue)
            takeover.setReleased(fan: id)
        }
        managedFans.removeAll()
        lastApplied.removeAll()
        lastTempForHyst.removeAll()
        tempSamples.removeAll()
        batteryHotSince = nil
        // Clear last-write tracking and streaks so we don't false-positive on
        // a stale `.forced` after we've stopped writing. appleOverridden
        // (session-wide quarantine) is intentionally preserved — only the
        // user picker action or process restart clears it.
        lastSetMode.removeAll()
        overrideStreak.removeAll()
    }

    private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        max(lo, min(hi, v))
    }
}
