//
//  FanCurve.swift
//  FanCore
//
//  Created on 2026-06-09.
//

import Foundation

public enum FanCurve {
    /// Piecewise-linear interpolation across `points`.
    /// - For temperatures at/below the first point, returns the first RPM.
    /// - For temperatures at/above the last point, returns the last RPM.
    /// - Returns 0 for empty input.
    public static func interpolate(points: [CurvePoint], tempC: Double) -> Int {
        guard let first = points.first, let last = points.last else { return 0 }
        if tempC <= first.tempC { return first.rpm }
        if tempC >= last.tempC  { return last.rpm }
        for i in 1..<points.count {
            let a = points[i-1], b = points[i]
            if tempC <= b.tempC {
                let t = (tempC - a.tempC) / (b.tempC - a.tempC)
                let r = (1.0 - t) * Double(a.rpm) + t * Double(b.rpm)
                return Int(r.rounded())
            }
        }
        return last.rpm
    }
}

extension FanCurve {
    /// Returns the maximum raw Celsius value among sensors whose key matches any driver.
    /// Uses `.value` (raw SMC reading, always Celsius) — not any locale-converted
    /// representation, which would break the controller's comparison against
    /// Celsius curve breakpoints.
    /// Returns nil if no driver matches any sensor.
    public static func effectiveTemperature(sensors: [FanCoreSensor],
                                            drivers: [DriverSensor]) -> Double? {
        let keys = Set(drivers.map(\.key))
        let values = sensors
            .filter { keys.contains($0.key) }
            .map(\.value)
        return values.max()
    }
}
