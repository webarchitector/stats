//
//  DaemonRunloop.swift
//  Helper
//
//  Created on 2026-06-09.
//
//  Owns the 1-second DispatchSourceTimer that drives `FanCurveEngine` from
//  the daemon side. Each tick:
//    1. reload profiles from disk (the app may have written new ones since
//       last tick — Phase 5 wires that path),
//    2. reload active profile,
//    3. build an `EngineSnapshot` via `HelperSensorReader`,
//    4. call `engine.tick(snapshot:)`.
//  Stats.app's `FanCurveController` still runs in Phase 3 — both writers
//  compute the same target so last-writer-wins on SMC is acceptable. Phase 5
//  disables the in-app controller when it detects a daemon-aware helper.
//

import Foundation

final class DaemonRunloop {
    private let reader: HelperSensorReader
    private let engine: FanCurveEngine
    private let store: PersistentProfileStore
    private let logger: HelperLogger
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "eu.exelban.Stats.SMC.Helper.tick")

    init(reader: HelperSensorReader, engine: FanCurveEngine, store: PersistentProfileStore, logger: HelperLogger) {
        self.reader = reader
        self.engine = engine
        self.store = store
        self.logger = logger
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
        logger.info("daemon tick loop started")
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let activeProfile = store.loadActive()
        engine.setProfiles(store.loadAll())
        engine.setActiveProfile(activeProfile)
        let snap = reader.read(profile: activeProfile)
        engine.tick(snapshot: snap)
    }

    /// Re-tick immediately on profile change. Phase 4/5 will expose an XPC
    /// method that calls this so the user-visible response is instant.
    func applyProfileChange() {
        queue.async { [weak self] in self?.tick() }
    }
}
