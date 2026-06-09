//
//  Sensor.swift
//  FanCore
//
//  Created on 2026-06-09.
//

import Foundation

/// Engine-facing sensor kind. Intentionally narrower than `Kit.SensorType` —
/// the engine only differentiates "temperature" (curve driver) from "fan"
/// (output) from "other" (ignored). Formatting / locale / units are app- and
/// daemon-specific concerns kept out of FanCore.
public enum FanCoreSensorType {
    case temperature
    case fan
    case other
}

/// Engine-facing sensor protocol. Stripped of NSObject, formatting, store
/// access, and unit conversion. The Sensors module bridges its richer
/// `Sensor_p` instances through a thin wrapper (see `values.swift`).
public protocol FanCoreSensor {
    /// Unique key (SMC key string, or synthesized name like "Hottest CPU"
    /// for IOHIDEvent-sourced aggregates).
    var key: String { get }
    var name: String { get }
    /// Raw value — for temperatures this is ALWAYS Celsius, regardless of
    /// the user's display preference. `FanCurve.effectiveTemperature`
    /// compares against Celsius curve breakpoints, so the locale conversion
    /// must not happen here.
    var value: Double { get }
    var type: FanCoreSensorType { get }
}
