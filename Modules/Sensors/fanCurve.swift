//
//  fanCurve.swift
//  Sensors
//
//  Created on 08/06/2026.
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
    /// Returns the maximum localValue among sensors whose key matches any driver.
    /// Returns nil if no driver matches any sensor.
    public static func effectiveTemperature(sensors: [Sensor_p],
                                            drivers: [DriverSensor]) -> Double? {
        let keys = Set(drivers.map(\.key))
        let values = sensors
            .filter { keys.contains($0.key) }
            .map(\.localValue)
        return values.max()
    }
}
