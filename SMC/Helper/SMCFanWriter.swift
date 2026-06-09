//
//  SMCFanWriter.swift
//  Helper
//
//  Created on 2026-06-09.
//
//  `FanCurveHelper` implementation for the daemon. The app-side
//  `SMCHelperAdapter` round-trips every write through XPC; this writes
//  SMC keys directly because the daemon already runs as root.
//
//  Phase 2: file exists but is not wired into `Helper.run()` yet (no
//  engine instance exists yet to consume it). Phase 3 hooks it up.
//

import Foundation

public final class SMCFanWriter: FanCurveHelper {
    private let smc: SMC
    /// Serializes every SMC access in the daemon. `SMC.shared` is a single
    /// `io_connect_t` with no internal locking, and `setFanSpeed`/`setFanMode`
    /// are non-atomic read-modify-write sequences. The tick loop runs on
    /// `DaemonRunloop.queue` while XPC methods (`setOverride`, `getStatusJSON`,
    /// `setEnabled`→`shutdown`) touch the same connection from their own
    /// delivery queues — without a shared queue those calls interleave and
    /// corrupt the SMC transaction. The SAME queue instance is injected into
    /// `HelperSensorReader` so reads and writes serialize against each other.
    private let accessQueue: DispatchQueue

    public init(smc: SMC = .shared,
                accessQueue: DispatchQueue = DispatchQueue(label: "eu.exelban.Stats.SMC.Helper.smcAccess")) {
        self.smc = smc
        self.accessQueue = accessQueue
    }

    /// We ARE the privileged daemon — there's no "helper" to be active or
    /// not. Always returns `true` so the engine never short-circuits.
    public func isActive() -> Bool { true }

    public func setFanMode(id: Int, mode: Int) {
        guard let resolved = FanMode(rawValue: mode) else {
            NSLog("SMCFanWriter: rejecting unknown fan mode \(mode)")
            return
        }
        // `.curve` is a Stats-internal sentinel — never write it to SMC.
        // The engine maps it to `.forced` before reaching here; this guard
        // matches SMC/main.swift's CLI guard and exists as a safety belt.
        if resolved == .curve {
            NSLog("SMCFanWriter: refusing to forward .curve sentinel to SMC")
            return
        }
        self.accessQueue.sync { self.smc.setFanMode(id, mode: resolved) }
    }

    public func setFanSpeed(id: Int, value: Int) {
        self.accessQueue.sync { self.smc.setFanSpeed(id, speed: value) }
    }
}
