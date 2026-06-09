//
//  HelperSensorReader.swift
//  Helper
//
//  Created on 2026-06-09.
//
//  In-process sensor reader for the privileged daemon. Builds an
//  `EngineSnapshot` (sensors + fan states) that mirrors what the app-side
//  `SensorsReader` feeds to `FanCurveController` — but talks directly to
//  SMC and IOHID instead of going through the Kit/Sensors/Store stack.
//
//  Phase 2: file exists but is not wired into `Helper.run()` yet (the
//  daemon still serves only the legacy XPC methods). Phase 3 starts the
//  tick loop.
//

import Foundation

#if arch(arm64)
import IOKit
#endif

/// Minimal `FanCoreSensor` carrier used by the daemon. The Sensors module
/// has its own richer `Sensor_p` hierarchy; the engine only needs key /
/// name / value / type so we re-introduce just those four fields here.
private struct HelperSensor: FanCoreSensor {
    let key: String
    let name: String
    let value: Double
    let type: FanCoreSensorType
}

public final class HelperSensorReader {
    private let smc: SMC

    public init(smc: SMC = .shared) {
        self.smc = smc
    }

    /// Build a snapshot of fans + driver-sensor temperatures for the
    /// supplied profile. Returns an empty sensors array when `profile`
    /// is nil (the engine treats this as "relinquish"); fans are always
    /// enumerated so the engine can still clear stale `.forced` modes.
    public func read(profile: FanProfile?) -> EngineSnapshot {
        let fans = self.readFans()
        let sensors = self.readSensors(driverKeys: profile?.drivers.map { $0.key } ?? [])
        return EngineSnapshot(sensors: sensors, fans: fans)
    }

    // MARK: - Fans

    private func readFans() -> [FanSnapshot] {
        guard let count = self.smc.getValue("FNum"), count > 0 else { return [] }

        var out: [FanSnapshot] = []
        for i in 0..<Int(count) {
            let minSpeed = self.smc.getValue("F\(i)Mn") ?? 1
            let maxSpeed = self.smc.getValue("F\(i)Mx") ?? 1
            let value = self.smc.getValue("F\(i)Ac") ?? 0

            let smcMode: FanMode?
            if let raw = self.smc.getValue(self.smc.fanModeKey(i)),
               let parsed = FanMode(rawValue: Int(raw)) {
                smcMode = parsed.isAutomatic ? .automatic : parsed
            } else {
                smcMode = nil
            }

            // Phase 2: helper doesn't yet track user takeover. The app
            // signals takeover by setting Fan.customMode = .forced via
            // the popup callback; the daemon will get an explicit XPC
            // setTakeover(id:on:) method in Phase 5. Until then we always
            // report `false`, which is safe — the engine will just keep
            // managing every fan in the profile.
            out.append(FanSnapshot(
                id: i,
                minSpeed: minSpeed,
                maxSpeed: maxSpeed,
                value: value,
                smcMode: smcMode,
                userTookOver: false
            ))
        }
        return out
    }

    // MARK: - Sensors

    private func readSensors(driverKeys: [String]) -> [FanCoreSensor] {
        guard !driverKeys.isEmpty else { return [] }

        // Read every requested key directly from SMC first. Built-in
        // profiles point at synthesized aggregates ("Hottest CPU" /
        // "Hottest GPU") that SMC doesn't know about — those resolve via
        // the HID block below.
        var sensors: [FanCoreSensor] = []
        var remaining = Set(driverKeys)

        for key in driverKeys {
            if let v = self.smc.getValue(key), v > 0, v < 110 {
                sensors.append(HelperSensor(key: key, name: key, value: v, type: .temperature))
                remaining.remove(key)
            }
        }

        guard !remaining.isEmpty else { return sensors }

        #if arch(arm64)
        // HID temperature poll. Page/usage 0xff00/0x0005 selects the
        // thermal sensor list (same constants as SensorsReader.m1Preset).
        let hid = AppleSiliconSensors(0xff00, 0x0005, kIOHIDEventTypeTemperature) as? [String: Double] ?? [:]

        var cpuValues: [Double] = []
        var gpuValues: [Double] = []
        var socValues: [Double] = []
        for (k, v) in hid {
            guard v >= 0, v < 300 else { continue }
            if k.hasPrefix("pACC MTR Temp") || k.hasPrefix("eACC MTR Temp") {
                cpuValues.append(v)
            } else if k.hasPrefix("GPU MTR Temp") {
                gpuValues.append(v)
            } else if k.hasPrefix("SOC MTR Temp") {
                socValues.append(v)
            }
        }

        // Aggregate synthesis — mirrors the "Hottest …" / "Average …"
        // logic in Modules/Sensors/readers.swift.
        func emit(_ key: String, _ value: Double) {
            guard remaining.contains(key) else { return }
            sensors.append(HelperSensor(key: key, name: key, value: value, type: .temperature))
            remaining.remove(key)
        }

        if !cpuValues.isEmpty {
            if let mx = cpuValues.max() { emit("Hottest CPU", mx) }
            emit("Average CPU", cpuValues.reduce(0, +) / Double(cpuValues.count))
        }
        if !gpuValues.isEmpty {
            if let mx = gpuValues.max() { emit("Hottest GPU", mx) }
            emit("Average GPU", gpuValues.reduce(0, +) / Double(gpuValues.count))
        }
        if !socValues.isEmpty {
            if let mx = socValues.max() { emit("Hottest SOC", mx) }
            emit("Average SOC", socValues.reduce(0, +) / Double(socValues.count))
        }

        // Fallback: any leftover requested key that the HID dict reports
        // verbatim (e.g. "gas gauge battery"). Useful for the battery
        // safety floor in `FanCurveEngine`.
        for (k, v) in hid where remaining.contains(k) {
            guard v >= 0, v < 300 else { continue }
            sensors.append(HelperSensor(key: k, name: k, value: v, type: .temperature))
            remaining.remove(k)
        }
        #endif

        return sensors
    }
}
