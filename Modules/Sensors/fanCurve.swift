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
    /// Stable UUID for the Apple Auto built-in. Code can look up "the firmware
    /// fallback profile" without depending on the (localizable) name.
    public static let appleAutoID = UUID(uuidString: "00000000-0000-0000-0000-000000000A07")!

    /// Generates the canonical built-in profiles for the user's hardware.
    /// `fanCount` is informational (offset applies regardless when fanCount ≥ 2;
    /// stored points are identical for 1- and 2-fan profiles).
    /// `defaultMaxRPM` is used for the top-of-curve points; profile is portable
    /// (per-fan maxSpeed clamping happens at apply time).
    ///
    /// Curve design principle: more points + smaller per-segment ΔRPM = smoother
    /// fan ramp and fewer audible "steps" as temperature drifts. Each profile
    /// has 7-9 points spanning the user's expected workload range.
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

        // Quiet — terpимо к теплу, медленно нарастает; идеально для звонков,
        // ночной работы. Терпит до 84°C прежде чем серьёзно раскручивается.
        let quietPts: [(Double, Int)] = [
            (45, 1200), (55, 1400), (65, 1900), (72, 2500),
            (78, 3300), (84, 4400), (88, 5600), (92, defaultMaxRPM)
        ]

        // Linear — идеальная предсказуемость: +800 RPM на каждые +10°C.
        // Хороший дефолт когда не знаешь профиль "под характер задачи".
        let linearPts: [(Double, Int)] = [
            (30, 1300), (40, 2100), (50, 2900), (60, 3700),
            (70, 4500), (80, 5300), (88, defaultMaxRPM)
        ]

        // Balanced — компромисс. Похож на Apple firmware curve, чуть быстрее
        // реагирует. Для повседневной работы.
        let balancedPts: [(Double, Int)] = [
            (38, 1300), (48, 1600), (56, 2100), (62, 2700),
            (68, 3400), (74, 4200), (80, 5200), (85, 6200),
            (88, defaultMaxRPM)
        ]

        // Aggressive — не даёт SoC дойти до throttle. Цена — слышный кулер
        // под нагрузкой. Для компиляции, LLM, видео-рендера.
        let aggressivePts: [(Double, Int)] = [
            (30, 1300), (38, 1700), (46, 2300), (53, 3000),
            (60, 3800), (66, 4500), (72, 5300), (76, 6100),
            (80, defaultMaxRPM)
        ]

        // Performance — для устойчиво тяжёлых задач (training, encoding).
        // Сразу высокие обороты, max выдают раньше 80°C. Терпеть шум придётся.
        let performancePts: [(Double, Int)] = [
            (28, 1500), (35, 2200), (42, 2900), (50, 3700),
            (58, 4500), (65, 5300), (70, 6000), (75, defaultMaxRPM)
        ]

        return [
            FanProfile(id: appleAutoID, name: "Apple Auto", isBuiltIn: true,
                       drivers: drivers, points: [],
                       fanOffsetRPM: 50),
            FanProfile(name: "Quiet", isBuiltIn: true,
                       drivers: drivers, points: curve(quietPts),
                       fanOffsetRPM: 50),
            FanProfile(name: "Linear", isBuiltIn: true,
                       drivers: drivers, points: curve(linearPts),
                       fanOffsetRPM: 50),
            FanProfile(name: "Balanced", isBuiltIn: true,
                       drivers: drivers, points: curve(balancedPts),
                       fanOffsetRPM: 50),
            FanProfile(name: "Aggressive", isBuiltIn: true,
                       drivers: drivers, points: curve(aggressivePts),
                       fanOffsetRPM: 50),
            FanProfile(name: "Performance", isBuiltIn: true,
                       drivers: drivers, points: curve(performancePts),
                       fanOffsetRPM: 50),
        ]
    }
}
