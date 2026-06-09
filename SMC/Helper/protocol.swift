//
//  protocol.swift
//  Helper
//
//  Created by Serhiy Mytrovtsiy on 17/11/2022
//  Using Swift 5.0
//  Running on macOS 13.0
//
//  Copyright © 2022 Serhiy Mytrovtsiy. All rights reserved.
//

import Foundation

@objc public protocol HelperProtocol {
    func version(completion: @escaping (String) -> Void)
    /// Probe so the app (Phase 5+) can distinguish a daemon-aware helper from
    /// the legacy "RPC slave" helper. Returns 1 for legacy builds (this method
    /// will fail with `NSXPCConnection`'s unimplemented-selector error and the
    /// app should treat that as version 1); returns 2 once the helper owns the
    /// tick loop end-to-end. Phase 4 expands the surface (profile push,
    /// takeover, status read, enable toggle) but stays at version 2 — the
    /// added methods are additive and unimplemented-selector is enough for the
    /// app to fall back to the legacy code path per-method.
    func protocolVersion(completion: @escaping (Int) -> Void)
    func setSMCPath(_ path: String)

    func setFanMode(id: Int, mode: Int, completion: @escaping (String?) -> Void)
    func setFanSpeed(id: Int, value: Int, completion: @escaping (String?) -> Void)
    func resetFanControl(completion: @escaping (String?) -> Void)

    func uninstall()

    // MARK: - Phase 4: daemon-aware surface
    // The app pushes the active profile + full profile list as JSON-encoded
    // `FanProfile` / `[FanProfile]`. The daemon decodes and forwards to its
    // PersistentProfileStore, then re-ticks the engine immediately.
    func setActiveProfileJSON(_ data: Data, completion: @escaping (String?) -> Void)
    func saveProfilesJSON(_ data: Data, completion: @escaping (String?) -> Void)

    /// Override a single fan. `rawMode` matches `OverrideKind` raw values:
    /// 0 = curve (release fan back to engine), 1 = manual (value = target RPM),
    /// 2 = off (value ignored, RPM = 0), 3 = max (value ignored, RPM = fan.maxSpeed).
    func setOverride(rawMode: Int, fanId: Int, value: Int, completion: @escaping (String?) -> Void)

    /// Returns a JSON-encoded `HelperStatus` snapshot — per-fan target/current
    /// RPM, smcMode, appleOverridden, plus current effective temp and engine
    /// enabled state. Returns nil on encode failure.
    func getStatusJSON(completion: @escaping (Data?) -> Void)

    /// Enable / disable the engine entirely. Disabling triggers
    /// `engine.shutdown()` so managed fans relinquish back to `.automatic`.
    func setEnabled(_ enabled: Bool, completion: @escaping (String?) -> Void)
}
