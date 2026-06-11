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
    /// Shared with `SMCFanWriter` so SMC reads serialize against the tick
    /// loop's writes — `SMC.shared` is a single connection with no internal
    /// locking. See `SMCFanWriter.accessQueue`.
    private let accessQueue: DispatchQueue
    /// Reports per-fan user takeover into the snapshot so the engine yields a
    /// fan the user grabbed via Manual/Off/Max. Optional so a reader can be
    /// built without one (e.g. tests).
    private let takeover: TakeoverStore?

    public init(smc: SMC = .shared,
                accessQueue: DispatchQueue = DispatchQueue(label: "eu.exelban.Stats.SMC.Helper.smcAccess"),
                takeover: TakeoverStore? = nil) {
        self.smc = smc
        self.accessQueue = accessQueue
        self.takeover = takeover
    }

    /// Build a snapshot of fans + driver-sensor temperatures for the
    /// supplied profile. Returns an empty sensors array when `profile`
    /// is nil (the engine treats this as "relinquish"); fans are always
    /// enumerated so the engine can still clear stale `.forced` modes.
    public func read(profile: FanProfile?) -> EngineSnapshot {
        self.accessQueue.sync {
            let fans = self.readFans()
            let sensors = self.readSensors(driverKeys: profile?.drivers.map { $0.key } ?? [])
            return EngineSnapshot(sensors: sensors, fans: fans)
        }
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

            // User takeover (Manual/Off/Max via the popup → setOverride) is
            // tracked in the daemon's takeover store. Feed it into the snapshot
            // so the engine yields this fan instead of overwriting the user's
            // manual RPM with the curve.
            out.append(FanSnapshot(
                id: i,
                minSpeed: minSpeed,
                maxSpeed: maxSpeed,
                value: value,
                smcMode: smcMode,
                userTookOver: self.takeover?.userTookOver(fan: i) ?? false
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
            // `SMC.getValue` precondition-fails on non-4-char keys (smc.swift
            // line 120). Synthetic driver keys like "Hottest CPU" / "Average
            // GPU" must skip SMC and fall through to the HID block below.
            guard key.count == 4 else { continue }
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
        // SoC die sensors. M1/M2 expose per-cluster "pACC/eACC/GPU/SOC MTR
        // Temp"; M3/M4-era Macs (e.g. Mac17,2) instead name them "PMU tdie*" /
        // "PMU2 tdie*". Collect both so the curve resolves a temperature on
        // either generation rather than relinquishing.
        var dieValues: [Double] = []
        for (k, v) in hid {
            guard v >= 0, v < 300 else { continue }
            if k.hasPrefix("pACC MTR Temp") || k.hasPrefix("eACC MTR Temp") {
                cpuValues.append(v)
            } else if k.hasPrefix("GPU MTR Temp") {
                gpuValues.append(v)
            } else if k.hasPrefix("SOC MTR Temp") {
                socValues.append(v)
            } else if k.contains("tdie") {
                dieValues.append(v)
            }
        }
        // Hardware without the MTR-named clusters: drive the CPU/GPU/SOC
        // aggregates off the SoC die sensors so the default "Hottest CPU" /
        // "Hottest GPU" profile drivers still resolve.
        if cpuValues.isEmpty { cpuValues = dieValues }
        if gpuValues.isEmpty { gpuValues = dieValues }
        if socValues.isEmpty { socValues = dieValues }

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

        // Last-resort safety net: a requested driver still unresolved (an
        // unrecognized naming scheme). Drive it off the hottest plausible
        // on-die thermal sensor so the curve never goes blind and relinquishes.
        // Excludes battery / storage and out-of-range readings.
        if !remaining.isEmpty {
            let dieMax = hid
                .filter { 20 < $0.value && $0.value < 130
                    && !$0.key.lowercased().contains("battery")
                    && !$0.key.contains("NAND")
                    && !$0.key.lowercased().contains("gas gauge") }
                .values.max()
            if let dieMax = dieMax {
                for key in Array(remaining) { emit(key, dieMax) }
            }
        }
        #endif

        return sensors
    }
}
