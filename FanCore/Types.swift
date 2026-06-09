//
//  Types.swift
//  FanCore
//
//  Created on 2026-06-09.
//
//  Pure-Swift value types shared between the Sensors module (in-app) and the
//  privileged root daemon. Source-compiled into both targets — there is no
//  separate framework. See SMC/smc.swift for the same multi-target pattern.
//
//  FanMode is intentionally NOT declared here. The Sensors target already
//  compiles `SMC/smc.swift` (which declares `FanMode`); adding another
//  same-module declaration would conflict. The daemon will get its own
//  `FanMode` declaration in Phase 2 when SMC/Helper sources move into the
//  Helper target's Sources phase. FanCurveEngine / FanSnapshot reference
//  `FanMode` by unqualified name and Swift resolves it to whichever sibling
//  declaration is in scope per-target.
//

import Foundation

/// A single (temperature, RPM) breakpoint on a fan curve.
public struct CurvePoint: Codable, Equatable, Hashable {
    public var tempC: Double
    public var rpm: Int

    public init(tempC: Double, rpm: Int) {
        self.tempC = tempC
        self.rpm = rpm
    }
}

/// A sensor (by SMC key) that contributes to the curve's effective temperature.
/// `weight` is currently informational — `FanCurve.effectiveTemperature`
/// returns the max of matched sensor values.
public struct DriverSensor: Codable, Equatable, Hashable {
    public var key: String
    public var weight: Double

    public init(key: String, weight: Double = 1.0) {
        self.key = key
        self.weight = weight
    }
}

/// A complete fan-curve profile: drivers + curve points + per-fan offset and
/// smoothing parameters. Codable for `ProfileStore` persistence via UserDefaults.
public struct FanProfile: Codable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var isBuiltIn: Bool
    public var drivers: [DriverSensor]
    public var points: [CurvePoint]
    public var fanOffsetRPM: Int
    public var hysteresisC: Double
    public var deltaRpmThreshold: Int

    public init(id: UUID = UUID(),
                name: String,
                isBuiltIn: Bool = false,
                drivers: [DriverSensor],
                points: [CurvePoint],
                fanOffsetRPM: Int = 50,
                hysteresisC: Double = 2.0,
                deltaRpmThreshold: Int = 150) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.drivers = drivers
        self.points = points
        self.fanOffsetRPM = fanOffsetRPM
        self.hysteresisC = hysteresisC
        self.deltaRpmThreshold = deltaRpmThreshold
    }
}
