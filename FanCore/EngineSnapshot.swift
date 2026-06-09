//
//  EngineSnapshot.swift
//  FanCore
//
//  Created on 2026-06-09.
//

import Foundation

/// Bundle of per-tick inputs to `FanCurveEngine.tick`. Decoupled from
/// `Sensors_List` so the daemon (which doesn't link the Sensors framework)
/// can construct the same input from its own SMC reads.
public struct EngineSnapshot {
    public let sensors: [FanCoreSensor]
    public let fans: [FanSnapshot]

    public init(sensors: [FanCoreSensor], fans: [FanSnapshot]) {
        self.sensors = sensors
        self.fans = fans
    }
}
