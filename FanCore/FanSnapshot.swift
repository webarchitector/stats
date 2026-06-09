//
//  FanSnapshot.swift
//  FanCore
//
//  Created on 2026-06-09.
//

import Foundation

/// Per-fan view passed to the engine each tick. Only the fields the engine
/// actually needs are exposed — `Sensors.Fan` carries widget/UI state and
/// store-backed accessors that are irrelevant to the curve loop.
///
/// - `userTookOver`: true when the user has picked Manual/Off/Max in the popup
///   (or any other UI path that owns the fan); the engine yields by skipping
///   the fan and dropping it from its managed set. The app maps this from
///   `Fan.customMode == .forced`; the daemon will map this from its own store
///   in Phase 3.
/// - `smcMode`: per-tick refresh of the fan's actual SMC mode. Used by the
///   Apple-firmware override failsafe to detect silent reverts of our
///   `.forced` write back to `.automatic`. `nil` when the probe failed.
public struct FanSnapshot {
    public let id: Int
    public let minSpeed: Double
    public let maxSpeed: Double
    public let value: Double
    public let smcMode: FanMode?
    public let userTookOver: Bool

    public init(id: Int,
                minSpeed: Double,
                maxSpeed: Double,
                value: Double,
                smcMode: FanMode?,
                userTookOver: Bool) {
        self.id = id
        self.minSpeed = minSpeed
        self.maxSpeed = maxSpeed
        self.value = value
        self.smcMode = smcMode
        self.userTookOver = userTookOver
    }
}
