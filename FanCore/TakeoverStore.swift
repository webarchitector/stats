//
//  TakeoverStore.swift
//  FanCore
//
//  Created on 2026-06-09.
//

import Foundation

/// Engine-side abstraction over the per-fan "who owns this fan?" state. The
/// app implementation reads/writes `Store.shared.fan_<id>_mode`; the daemon
/// (Phase 3) will own its own representation. Keeps `FanCurveEngine` free of
/// any UserDefaults / Store coupling so it can run inside a privileged root
/// process that doesn't share the user's defaults domain.
public protocol TakeoverStore {
    /// True when an out-of-band actor (UI popup picking Manual/Off/Max, the
    /// SMC CLI, etc.) has taken ownership of `fan` — engine must yield.
    func userTookOver(fan: Int) -> Bool
    /// Record that the engine has assumed control of `fan`. Used so a later
    /// crash-recovery / restart-shutdown pass can find Stats-managed fans
    /// and return them to firmware-automatic mode.
    func setStatsManaged(fan: Int)
    /// Record that the engine has released `fan` back to firmware-automatic.
    func setReleased(fan: Int)
}
