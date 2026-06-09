//
//  fanController.swift
//  Sensors
//
//  Created on 08/06/2026.
//
//  Thin adapter around `FanCurveEngine` (FanCore). This file is responsible
//  for the AppKit / Kit.Store / NotificationCenter plumbing that the engine
//  is intentionally free of, so the same engine can power the in-app
//  controller and the privileged daemon (Phase 2+).
//

import Foundation
import AppKit
import Kit

// MARK: - Back-compat aliases
//
// The clock protocol + impls moved to FanCore (renamed `FanCoreClock` /
// `SystemFanCoreClock` / `FakeFanCoreClock`). Tests and existing call sites
// reference the old names — keep typealiases in the Sensors namespace.

public typealias FanControllerClock = FanCoreClock
public typealias SystemFanControllerClock = SystemFanCoreClock
#if DEBUG
public typealias FakeFanControllerClock = FakeFanCoreClock
#endif

// MARK: - Store-backed TakeoverStore adapter

/// `TakeoverStore` implementation that reads/writes per-fan custom-mode state
/// to `Kit.Store.shared` under `fan_<id>_mode`. Used by the in-app controller;
/// the daemon will provide its own implementation in Phase 3.
fileprivate final class StoreBackedTakeover: TakeoverStore {
    func userTookOver(fan: Int) -> Bool {
        let raw = Store.shared.int(key: "fan_\(fan)_mode", defaultValue: -1)
        return raw == FanMode.forced.rawValue
    }
    func setStatsManaged(fan: Int) {
        Store.shared.set(key: "fan_\(fan)_mode", value: FanMode.curve.rawValue)
    }
    func setReleased(fan: Int) {
        Store.shared.set(key: "fan_\(fan)_mode", value: FanMode.automatic.rawValue)
    }
}

// MARK: - Kit.info logger adapter

fileprivate struct KitInfoLogger: FanCoreLogger {
    func info(_ message: String) {
        // Forwards to Kit's `info()` global; the engine's logging is sparse
        // (only the Apple-override quarantine event) so the perf cost is nil.
        Kit.info(message)
    }
}

// MARK: - FanCurveController (adapter)

public final class FanCurveController {
    private let engine: FanCurveEngine
    private let store: ProfileStore
    private let helper: FanCurveHelper
    private var didBootstrap: Bool = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// Last snapshot processed by tick(). Cached so the `.fanProfileChanged`
    /// observer can pass the engine the most recent inputs for a synchronous
    /// re-tick. Engine itself ALSO caches its last snapshot, but the engine's
    /// copy is private and the observer dispatches on `.main` (which may not
    /// hold the engine's lock), so the adapter mirrors the cache here.
    private var lastSnapshot: Sensors_List? = nil
    private let lastSnapshotLock = NSLock()

    public init(helper: FanCurveHelper, store: ProfileStore,
                clock: FanControllerClock = SystemFanControllerClock()) {
        self.helper = helper
        self.store = store
        self.engine = FanCurveEngine(
            helper: helper,
            takeover: StoreBackedTakeover(),
            clock: clock,
            logger: KitInfoLogger()
        )
        let workspaceNC = NSWorkspace.shared.notificationCenter
        observers.append((workspaceNC, workspaceNC.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.engine.handleWillSleep()
        }))
        observers.append((workspaceNC, workspaceNC.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.engine.handleDidWake()
        }))
        let defaultNC = NotificationCenter.default
        observers.append((defaultNC, defaultNC.addObserver(
            forName: .fanProfileChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            // Refresh engine's view of profiles + active selection from the
            // (app-side, Store-backed) ProfileStore, then ask the engine to
            // synchronously re-apply against the most recent snapshot.
            self.engine.setProfiles(self.store.loadProfiles())
            self.engine.setActiveProfile(self.store.activeProfile())
            self.lastSnapshotLock.lock()
            let snapshot = self.lastSnapshot?.asEngineSnapshot()
            self.lastSnapshotLock.unlock()
            self.engine.applyProfileChange(snapshot: snapshot)
        }))
    }

    deinit {
        for (center, token) in observers { center.removeObserver(token) }
    }

    #if DEBUG
    public func handleWillSleepForTests() { engine.handleWillSleep() }
    public func handleDidWakeForTests() { engine.handleDidWake() }
    /// Test hook — exposes the engine's median helper through the public
    /// adapter type to preserve test API.
    public static func _medianForTests(_ values: [Double]) -> Double {
        FanCurveEngine._medianForTests(values)
    }
    #endif

    public func tick(snapshot: Sensors_List?) {
        // Cache the Sensors_List itself for the profile-change observer.
        if let snapshot = snapshot {
            lastSnapshotLock.lock()
            lastSnapshot = snapshot
            lastSnapshotLock.unlock()
        }
        // Bootstrap profiles on the first tick that actually has fan info —
        // adapter responsibility because the engine is decoupled from
        // `ProfileStore` and doesn't know fan count / maxSpeed at init.
        if let snapshot = snapshot {
            let fans = snapshot.sensors.compactMap { $0 as? Fan }
            if !didBootstrap, !fans.isEmpty {
                let maxRpm = Int(fans.map(\.maxSpeed).max() ?? 7000)
                let wasEmpty = store.loadProfiles().isEmpty
                store.bootstrapIfNeeded(fanCount: fans.count, defaultMaxRPM: maxRpm)
                didBootstrap = true
                if wasEmpty {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .fanProfileChanged, object: nil)
                    }
                }
            }
            // Refresh the engine's profile state from the Store every tick.
            // Cheap (one Store read + JSON decode + lookup); keeps the engine
            // in sync without requiring observers to push on every setter.
            engine.setProfiles(store.loadProfiles())
            engine.setActiveProfile(store.activeProfile())
        }
        engine.tick(snapshot: snapshot?.asEngineSnapshot())
    }

    public func shutdown() {
        engine.shutdown()
    }
}

// MARK: - SMCHelperAdapter
//
// Real `FanCurveHelper` implementation bridging to `Kit.SMCHelper`. Kept here
// (not in FanCore) because it depends on `Kit.SMCHelper` and the privileged
// helper's on-disk path — both app-only concerns.

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
