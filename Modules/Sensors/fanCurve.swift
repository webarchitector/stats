//
//  fanCurve.swift
//  Sensors
//
//  Created on 08/06/2026.
//
//  The pure-logic body of this file (`FanCurve.interpolate`,
//  `FanCurve.effectiveTemperature`, `FanProfile.builtIns`, `FanProfile.appleAutoID`)
//  now lives in `FanCore/` so the privileged daemon (Phase 2+) can share it.
//  Only the Sensors-side convenience wrapper for `builtIns` (auto-supplies
//  `isARM` from Kit) remains here.
//

import Foundation
import Kit

extension FanProfile {
    /// Sensors-side convenience: passes the runtime `isARM` flag to the
    /// FanCore implementation so callers (ProfileStore, settings.swift) keep
    /// their existing signature.
    public static func builtIns(fanCount: Int, defaultMaxRPM: Int) -> [FanProfile] {
        builtIns(fanCount: fanCount, defaultMaxRPM: defaultMaxRPM, isARM: Kit.isARM)
    }
}
