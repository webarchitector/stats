//
//  fanCurve.swift
//  Sensors
//
//  Created on 08/06/2026.
//

import Foundation
import Kit

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
    /// Uses `.value` (raw SMC reading, always Celsius) — not `.localValue`, which
    /// routes through the user's display unit (Celsius/Fahrenheit) and would break
    /// the controller's comparison against Celsius curve breakpoints.
    /// Returns nil if no driver matches any sensor.
    public static func effectiveTemperature(sensors: [Sensor_p],
                                            drivers: [DriverSensor]) -> Double? {
        let keys = Set(drivers.map(\.key))
        let values = sensors
            .filter { keys.contains($0.key) }
            .map(\.value)
        return values.max()
    }
}

extension FanProfile {
    /// Generates the canonical 4 built-in profiles for the user's hardware.
    /// `fanCount` is informational (offset applies regardless when fanCount ≥ 2;
    /// stored points are identical for 1- and 2-fan profiles).
    /// `defaultMaxRPM` is used for the top-of-curve points; profile is portable
    /// (per-fan maxSpeed clamping happens at apply time).
    public static func builtIns(fanCount: Int, defaultMaxRPM: Int) -> [FanProfile] {
        func curve(_ raw: [(Double, Int)]) -> [CurvePoint] {
            raw.map { CurvePoint(tempC: $0.0, rpm: min($0.1, defaultMaxRPM)) }
        }
        // On Apple Silicon, classical SMC keys like TC0D/TG0D don't exist —
        // temperatures come through IOHIDEvent (see Modules/Sensors/reader.m)
        // with synthesized "Hottest CPU"/"Hottest GPU" aggregates in readers.swift.
        // Picking max-of-hottests gives the snappiest curve response on M-series.
        let drivers: [DriverSensor] = isARM
            ? [DriverSensor(key: "Hottest CPU"), DriverSensor(key: "Hottest GPU")]
            : [DriverSensor(key: "TC0D"), DriverSensor(key: "TG0D")]

        let quietPts:      [(Double, Int)] = [(50, 1200), (62, 1600), (72, 2400),
                                              (80, 3500), (86, 5000), (90, defaultMaxRPM)]
        let balancedPts:   [(Double, Int)] = [(40, 1300), (52, 1800), (62, 2600),
                                              (72, 3800), (80, 5200), (86, defaultMaxRPM)]
        let aggressivePts: [(Double, Int)] = [(35, 1300), (45, 2000), (55, 3000),
                                              (65, 4200), (72, 5400), (78, defaultMaxRPM)]

        return [
            FanProfile(name: "Apple Auto", isBuiltIn: true,
                       drivers: drivers, points: [],
                       fanOffsetRPM: 50),
            FanProfile(name: "Quiet", isBuiltIn: true,
                       drivers: drivers, points: curve(quietPts),
                       fanOffsetRPM: 50),
            FanProfile(name: "Balanced", isBuiltIn: true,
                       drivers: drivers, points: curve(balancedPts),
                       fanOffsetRPM: 50),
            FanProfile(name: "Aggressive", isBuiltIn: true,
                       drivers: drivers, points: curve(aggressivePts),
                       fanOffsetRPM: 50),
        ]
    }
}
