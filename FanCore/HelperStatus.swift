//
//  HelperStatus.swift
//  FanCore
//
//  Created on 2026-06-09.
//
//  Shared wire types between the privileged daemon and the app for the
//  Phase 4 XPC surface.
//
//  `HelperStatus` is encoded by the helper inside `getStatusJSON()` and
//  decoded by `SMCHelper` on the app side. `OverrideKind` is a strongly-typed
//  enum mirror of the `rawMode: Int` parameter accepted by
//  `setOverride(rawMode:fanId:value:)` — the protocol carries an `Int` so the
//  Objective-C XPC bridge stays free of Swift-only types, but the app uses
//  the enum locally and the daemon validates the raw value before acting.
//

import Foundation

/// Override request issued by the app to take a single fan out of curve
/// management (Manual / Off / Max) or to release it back to engine control.
/// Raw values are part of the XPC ABI — once shipped they must stay stable.
public enum OverrideKind: Int, Codable, Equatable {
    /// Release the fan back to the engine — the curve drives it again.
    case curve = 0
    /// User-specified target RPM. The companion `value` carries the RPM.
    case manual = 1
    /// Force RPM to 0. `value` ignored daemon-side.
    case off = 2
    /// Force RPM to the fan's `maxSpeed` (resolved by the daemon from the
    /// current snapshot). `value` ignored daemon-side.
    case max = 3
}

/// Snapshot of the daemon's per-tick state. Returned from `getStatusJSON()`
/// so the app can render fan dashboards / popup state without doing its own
/// SMC reads. Keep this Codable, value-typed, and stable — changes here
/// must be matched on both daemon and app sides simultaneously.
public struct HelperStatus: Codable, Equatable {
    /// Mirrors `HelperProtocol.protocolVersion` so a single XPC round-trip
    /// can verify daemon-aware behavior + read status in one call.
    public let protocolVersion: Int
    /// UUID string of the currently active `FanProfile`, or nil when no
    /// curve is active (Apple Auto / unset).
    public let activeProfileID: String?
    /// False when the user has disabled the engine via `setEnabled(false)` —
    /// the daemon will refuse to drive any fan until re-enabled.
    public let engineEnabled: Bool
    /// Current effective temperature (Celsius) — first temperature sensor
    /// in the last snapshot. nil when no sensors are available.
    public let currentTemp: Double?
    public let fans: [Fan]

    public struct Fan: Codable, Equatable {
        public let id: Int
        public let minSpeed: Double
        public let maxSpeed: Double
        public let currentRPM: Double
        /// Raw `FanMode` value (0 = automatic, 1 = forced, 3 = auto3).
        /// nil when the per-tick SMC mode probe failed.
        public let smcMode: Int?
        /// True when the daemon's `HelperTakeoverStore` marks this fan as
        /// user-owned — the engine yields and the app should show the user's
        /// manual / off / max selection.
        public let userTookOver: Bool
        /// True when the Apple-firmware override failsafe has quarantined
        /// this fan for the session (3 silent reverts of `.forced` →
        /// `.automatic`). Cleared on profile change or daemon restart.
        public let appleOverridden: Bool

        public init(id: Int,
                    minSpeed: Double,
                    maxSpeed: Double,
                    currentRPM: Double,
                    smcMode: Int?,
                    userTookOver: Bool,
                    appleOverridden: Bool) {
            self.id = id
            self.minSpeed = minSpeed
            self.maxSpeed = maxSpeed
            self.currentRPM = currentRPM
            self.smcMode = smcMode
            self.userTookOver = userTookOver
            self.appleOverridden = appleOverridden
        }
    }

    public init(protocolVersion: Int,
                activeProfileID: String?,
                engineEnabled: Bool,
                currentTemp: Double?,
                fans: [Fan]) {
        self.protocolVersion = protocolVersion
        self.activeProfileID = activeProfileID
        self.engineEnabled = engineEnabled
        self.currentTemp = currentTemp
        self.fans = fans
    }
}
