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
