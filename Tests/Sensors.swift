//
//  Sensors.swift
//  Tests
//
//  Created on 08/06/2026.
//

import XCTest
@testable import Sensors
import Kit

final class SensorsTests: XCTestCase {
    // Sensors and Kit both compile in smc.swift, so FanMode is declared in both
    // module namespaces. Bare `FanMode` is ambiguous; qualify via Kit (Sensors
    // is also a class in that module and shadows the module name).
    // The two FanMode declarations are structurally identical — pinning either
    // locks the SMC ABI surface for both.
    private typealias FanMode = Kit.FanMode

    // MARK: - FanMode.isAutomatic

    func testFanMode_isAutomatic_trueForAutomatic() {
        XCTAssertTrue(FanMode.automatic.isAutomatic)
    }

    func testFanMode_isAutomatic_trueForAuto3() {
        XCTAssertTrue(FanMode.auto3.isAutomatic)
    }

    func testFanMode_isAutomatic_falseForForced() {
        XCTAssertFalse(FanMode.forced.isAutomatic)
    }

    // MARK: - FanMode rawValue mapping (lock SMC ABI)

    func testFanMode_rawValues_matchSMC() {
        XCTAssertEqual(FanMode.automatic.rawValue, 0)
        XCTAssertEqual(FanMode.forced.rawValue, 1)
        XCTAssertEqual(FanMode.auto3.rawValue, 3)
    }

    // MARK: - FanMode Codable roundtrip

    func testFanMode_codable_roundtrip() throws {
        for mode in [FanMode.automatic, .forced, .auto3] {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(FanMode.self, from: data)
            XCTAssertEqual(decoded, mode, "round-trip failed for \(mode)")
        }
    }

    // MARK: - FanMode.curve (new)

    func testFanMode_curve_rawValueIs100() {
        XCTAssertEqual(FanMode.curve.rawValue, 100)
    }

    func testFanMode_curve_notAutomatic() {
        XCTAssertFalse(FanMode.curve.isAutomatic)
    }

    func testFanMode_curve_isStatsControlled() {
        XCTAssertTrue(FanMode.curve.isStatsControlled)
    }

    func testFanMode_others_notStatsControlled() {
        XCTAssertFalse(FanMode.automatic.isStatsControlled)
        XCTAssertFalse(FanMode.forced.isStatsControlled)
        XCTAssertFalse(FanMode.auto3.isStatsControlled)
    }

    func testFanMode_curve_codableRoundtrip() throws {
        let data = try JSONEncoder().encode(FanMode.curve)
        let decoded = try JSONDecoder().decode(FanMode.self, from: data)
        XCTAssertEqual(decoded, .curve)
    }

    // MARK: - Fan.percentage

    private func makeFan(value: Double, maxSpeed: Double = 7000) -> Fan {
        Fan(id: 0, key: "F0Ac", name: "Test Fan",
            minSpeed: 1000, maxSpeed: maxSpeed,
            value: value, mode: .automatic)
    }

    func testFan_percentage_zeroWhenValueIsZero() {
        XCTAssertEqual(makeFan(value: 0).percentage, 0)
    }

    func testFan_percentage_zeroWhenMaxSpeedIsZero() {
        XCTAssertEqual(makeFan(value: 3500, maxSpeed: 0).percentage, 0)
    }

    func testFan_percentage_halfwayAtFiftyPercent() {
        XCTAssertEqual(makeFan(value: 3500, maxSpeed: 7000).percentage, 50)
    }

    func testFan_percentage_fullAtMaxSpeed() {
        XCTAssertEqual(makeFan(value: 7000, maxSpeed: 7000).percentage, 100)
    }

    func testFan_percentage_unityValuesYieldZero() {
        // existing impl guards (value != 1 && maxSpeed != 1) — preserve that quirk
        XCTAssertEqual(makeFan(value: 1, maxSpeed: 7000).percentage, 0)
        XCTAssertEqual(makeFan(value: 3500, maxSpeed: 1).percentage, 0)
    }

    // MARK: - Fan.customMode / customSpeed persistence

    // Store.shared keeps an internal cache layered on top of UserDefaults.standard;
    // clearing UserDefaults alone leaves the cache stale, so go through Store.
    private func clearStore(fanID: Int) {
        Store.shared.remove("fan_\(fanID)_speed")
        Store.shared.remove("fan_\(fanID)_mode")
    }

    func testFan_customSpeed_nilByDefault() {
        clearStore(fanID: 99)
        let fan = Fan(id: 99, key: "F0Ac", name: "x",
                      minSpeed: 1000, maxSpeed: 7000, value: 0, mode: .automatic)
        XCTAssertNil(fan.customSpeed)
    }

    func testFan_customSpeed_roundtrip() {
        clearStore(fanID: 99)
        var fan = Fan(id: 99, key: "F0Ac", name: "x",
                      minSpeed: 1000, maxSpeed: 7000, value: 0, mode: .automatic)
        fan.customSpeed = 4321
        XCTAssertEqual(fan.customSpeed, 4321)
        clearStore(fanID: 99)
    }

    func testFan_customSpeed_nilClears() {
        clearStore(fanID: 99)
        var fan = Fan(id: 99, key: "F0Ac", name: "x",
                      minSpeed: 1000, maxSpeed: 7000, value: 0, mode: .automatic)
        fan.customSpeed = 4321
        fan.customSpeed = nil
        XCTAssertNil(fan.customSpeed)
    }

    func testFan_customMode_nilByDefault() {
        clearStore(fanID: 98)
        let fan = Fan(id: 98, key: "F0Ac", name: "x",
                      minSpeed: 1000, maxSpeed: 7000, value: 0, mode: .automatic)
        XCTAssertNil(fan.customMode)
    }

    func testFan_customMode_roundtrip() {
        clearStore(fanID: 98)
        var fan = Fan(id: 98, key: "F0Ac", name: "x",
                      minSpeed: 1000, maxSpeed: 7000, value: 0, mode: .automatic)
        fan.customMode = .forced
        XCTAssertEqual(fan.customMode, .forced)
        clearStore(fanID: 98)
    }

    func testFan_customMode_nilClears() {
        clearStore(fanID: 98)
        var fan = Fan(id: 98, key: "F0Ac", name: "x",
                      minSpeed: 1000, maxSpeed: 7000, value: 0, mode: .automatic)
        fan.customMode = .forced
        fan.customMode = nil
        XCTAssertNil(fan.customMode)
        clearStore(fanID: 98)
    }

    // MARK: - CurvePoint

    func testCurvePoint_codableRoundtrip() throws {
        let pt = CurvePoint(tempC: 60.5, rpm: 3000)
        let data = try JSONEncoder().encode(pt)
        let decoded = try JSONDecoder().decode(CurvePoint.self, from: data)
        XCTAssertEqual(decoded, pt)
    }

    func testCurvePoint_equality() {
        XCTAssertEqual(CurvePoint(tempC: 60, rpm: 3000),
                       CurvePoint(tempC: 60, rpm: 3000))
        XCTAssertNotEqual(CurvePoint(tempC: 60, rpm: 3000),
                          CurvePoint(tempC: 61, rpm: 3000))
        XCTAssertNotEqual(CurvePoint(tempC: 60, rpm: 3000),
                          CurvePoint(tempC: 60, rpm: 3001))
    }

    // MARK: - DriverSensor

    func testDriverSensor_defaultWeightIsOne() {
        let d = DriverSensor(key: "TC0D")
        XCTAssertEqual(d.weight, 1.0)
    }

    func testDriverSensor_codableRoundtrip() throws {
        let d = DriverSensor(key: "TG0D", weight: 0.5)
        let data = try JSONEncoder().encode(d)
        let decoded = try JSONDecoder().decode(DriverSensor.self, from: data)
        XCTAssertEqual(decoded, d)
    }

    // MARK: - FanProfile

    private func makeAggressive() -> FanProfile {
        FanProfile(
            name: "Aggressive",
            drivers: [DriverSensor(key: "TC0D"), DriverSensor(key: "TG0D")],
            points: [
                CurvePoint(tempC: 35, rpm: 1300),
                CurvePoint(tempC: 78, rpm: 7000)
            ])
    }

    func testFanProfile_hasUniqueIDByDefault() {
        let a = makeAggressive()
        let b = makeAggressive()
        XCTAssertNotEqual(a.id, b.id)
    }

    func testFanProfile_defaults() {
        let p = makeAggressive()
        XCTAssertFalse(p.isBuiltIn)
        XCTAssertEqual(p.fanOffsetRPM, 50)
        XCTAssertEqual(p.hysteresisC, 2.0, accuracy: 0.001)
        XCTAssertEqual(p.deltaRpmThreshold, 150)
    }

    func testFanProfile_codableRoundtrip() throws {
        var p = makeAggressive()
        p.isBuiltIn = true
        p.fanOffsetRPM = 75
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(FanProfile.self, from: data)
        XCTAssertEqual(decoded.id, p.id)
        XCTAssertEqual(decoded.name, p.name)
        XCTAssertEqual(decoded.isBuiltIn, true)
        XCTAssertEqual(decoded.fanOffsetRPM, 75)
        XCTAssertEqual(decoded.drivers, p.drivers)
        XCTAssertEqual(decoded.points, p.points)
    }

    func testFanProfile_arrayCodableRoundtrip() throws {
        let list = [makeAggressive(), makeAggressive()]
        let data = try JSONEncoder().encode(list)
        let decoded = try JSONDecoder().decode([FanProfile].self, from: data)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].id, list[0].id)
        XCTAssertEqual(decoded[1].id, list[1].id)
    }

    // MARK: - interpolate

    private let curveA: [CurvePoint] = [
        CurvePoint(tempC: 40, rpm: 1000),
        CurvePoint(tempC: 60, rpm: 3000),
        CurvePoint(tempC: 80, rpm: 6000),
    ]

    func testInterpolate_emptyPoints_returnsZero() {
        XCTAssertEqual(FanCurve.interpolate(points: [], tempC: 50), 0)
    }

    func testInterpolate_belowFirst_returnsFirstRpm() {
        XCTAssertEqual(FanCurve.interpolate(points: curveA, tempC: 20), 1000)
        XCTAssertEqual(FanCurve.interpolate(points: curveA, tempC: 40), 1000)
    }

    func testInterpolate_aboveLast_returnsLastRpm() {
        XCTAssertEqual(FanCurve.interpolate(points: curveA, tempC: 100), 6000)
        XCTAssertEqual(FanCurve.interpolate(points: curveA, tempC: 80), 6000)
    }

    func testInterpolate_midpointBetweenTwoPoints() {
        // halfway between (40,1000) and (60,3000) at temp=50 → rpm=2000
        XCTAssertEqual(FanCurve.interpolate(points: curveA, tempC: 50), 2000)
        // halfway between (60,3000) and (80,6000) at temp=70 → rpm=4500
        XCTAssertEqual(FanCurve.interpolate(points: curveA, tempC: 70), 4500)
    }

    func testInterpolate_singlePoint_returnsThatRpm() {
        let p = [CurvePoint(tempC: 50, rpm: 2500)]
        XCTAssertEqual(FanCurve.interpolate(points: p, tempC: 20), 2500)
        XCTAssertEqual(FanCurve.interpolate(points: p, tempC: 50), 2500)
        XCTAssertEqual(FanCurve.interpolate(points: p, tempC: 80), 2500)
    }

    func testInterpolate_intermediateRoundsToInt() {
        // Between (40,1000) and (60,3001) at temp=50 — midpoint rpm = 2000.5
        let pts = [CurvePoint(tempC: 40, rpm: 1000), CurvePoint(tempC: 60, rpm: 3001)]
        // accept either 2000 or 2001 (rounding mode is impl-defined but value is bounded)
        let r = FanCurve.interpolate(points: pts, tempC: 50)
        XCTAssertTrue(r == 2000 || r == 2001, "got \(r)")
    }

    // MARK: - effectiveTemperature

    // `effectiveTemperature` reads `Sensor.value` directly — the raw SMC
    // reading, always in Celsius — so tests don't need to touch the
    // user's display-unit preference.

    private func makeTempSensor(key: String, value: Double) -> Sensor {
        Sensor(key: key, name: key, value: value,
               group: .CPU, type: .temperature, platforms: Platform.all)
    }

    /// Bridge `[Sensor_p]` → `[FanCoreSensor]` for tests. `FanCurve.effectiveTemperature`
    /// now lives in FanCore and takes the engine-facing sensor protocol;
    /// `Sensor_p` projects to it via `asFanCoreSensor()`.
    private func core(_ sensors: [Sensor_p]) -> [FanCoreSensor] {
        sensors.map { $0.asFanCoreSensor() }
    }

    func testEffectiveTemperature_emptyDrivers_returnsNil() {
        let r = FanCurve.effectiveTemperature(sensors: [FanCoreSensor](), drivers: [])
        XCTAssertNil(r)
    }

    func testEffectiveTemperature_noMatchingSensors_returnsNil() {
        let sensors: [Sensor_p] = [makeTempSensor(key: "TC0D", value: 60)]
        let r = FanCurve.effectiveTemperature(sensors: core(sensors),
                drivers: [DriverSensor(key: "MISSING")])
        XCTAssertNil(r)
    }

    func testEffectiveTemperature_singleDriver_returnsItsValue() {
        let sensors: [Sensor_p] = [makeTempSensor(key: "TC0D", value: 65.5)]
        let r = FanCurve.effectiveTemperature(sensors: core(sensors),
                drivers: [DriverSensor(key: "TC0D")])
        XCTAssertEqual(r, 65.5)
    }

    func testEffectiveTemperature_multipleDrivers_returnsMax() {
        let sensors: [Sensor_p] = [
            makeTempSensor(key: "TC0D", value: 60),
            makeTempSensor(key: "TG0D", value: 75),
            makeTempSensor(key: "TCAD", value: 55),
        ]
        let r = FanCurve.effectiveTemperature(sensors: core(sensors),
                drivers: [DriverSensor(key: "TC0D"),
                          DriverSensor(key: "TG0D"),
                          DriverSensor(key: "TCAD")])
        XCTAssertEqual(r, 75)
    }

    func testEffectiveTemperature_skipsMissingDrivers() {
        let sensors: [Sensor_p] = [
            makeTempSensor(key: "TC0D", value: 60),
        ]
        let r = FanCurve.effectiveTemperature(sensors: core(sensors),
                drivers: [DriverSensor(key: "TC0D"),
                          DriverSensor(key: "MISSING")])
        XCTAssertEqual(r, 60)
    }

    // MARK: - FanProfile.builtIns

    private static let builtInOrder: [String] = [
        "Apple Auto", "Quiet", "Linear", "Balanced", "Aggressive", "Performance"
    ]

    func testBuiltIns_singleFan_hasSixProfiles() {
        let list = FanProfile.builtIns(fanCount: 1, defaultMaxRPM: 7000)
        XCTAssertEqual(list.count, 6)
        XCTAssertEqual(list.map(\.name), Self.builtInOrder)
    }

    func testBuiltIns_twoFans_hasSameSixProfiles() {
        let list = FanProfile.builtIns(fanCount: 2, defaultMaxRPM: 7000)
        XCTAssertEqual(list.count, 6)
        XCTAssertEqual(list.map(\.name), Self.builtInOrder)
    }

    func testBuiltIns_allMarkedBuiltIn() {
        let list = FanProfile.builtIns(fanCount: 1, defaultMaxRPM: 7000)
        for p in list { XCTAssertTrue(p.isBuiltIn, "\(p.name) not marked built-in") }
    }

    func testBuiltIns_appleAutoHasNoPoints() {
        let list = FanProfile.builtIns(fanCount: 1, defaultMaxRPM: 7000)
        let auto = list.first { $0.name == "Apple Auto" }!
        XCTAssertTrue(auto.points.isEmpty)
    }

    func testBuiltIns_aggressiveLastPointReachesMax() {
        let list = FanProfile.builtIns(fanCount: 1, defaultMaxRPM: 7000)
        let agg = list.first { $0.name == "Aggressive" }!
        XCTAssertEqual(agg.points.last?.rpm, 7000)
    }

    func testBuiltIns_aggressiveHasExpectedShape() {
        let list = FanProfile.builtIns(fanCount: 1, defaultMaxRPM: 7000)
        let agg = list.first { $0.name == "Aggressive" }!
        XCTAssertEqual(agg.points.count, 9)
        XCTAssertEqual(agg.points[0], CurvePoint(tempC: 30, rpm: 1300))
        XCTAssertEqual(agg.points[1], CurvePoint(tempC: 38, rpm: 1700))
        XCTAssertEqual(agg.points[2], CurvePoint(tempC: 46, rpm: 2300))
        XCTAssertEqual(agg.points[3], CurvePoint(tempC: 53, rpm: 3000))
        XCTAssertEqual(agg.points[4], CurvePoint(tempC: 60, rpm: 3800))
        XCTAssertEqual(agg.points[5], CurvePoint(tempC: 66, rpm: 4500))
        XCTAssertEqual(agg.points[6], CurvePoint(tempC: 72, rpm: 5300))
        XCTAssertEqual(agg.points[7], CurvePoint(tempC: 76, rpm: 6100))
        XCTAssertEqual(agg.points[8], CurvePoint(tempC: 80, rpm: 7000))
    }

    func testBuiltIns_allCurveProfilesAreMonotonic() {
        // Smoother curves require monotonically rising RPM with rising temp.
        let list = FanProfile.builtIns(fanCount: 1, defaultMaxRPM: 7000)
        for p in list where !p.points.isEmpty {
            let pts = p.points
            for i in 1..<pts.count {
                XCTAssertGreaterThan(pts[i].tempC, pts[i-1].tempC,
                    "\(p.name): temps must rise strictly (\(pts[i-1]) → \(pts[i]))")
                XCTAssertGreaterThanOrEqual(pts[i].rpm, pts[i-1].rpm,
                    "\(p.name): RPM must not decrease (\(pts[i-1]) → \(pts[i]))")
            }
        }
    }

    func testBuiltIns_allCurveProfilesEndAtMaxRPM() {
        let list = FanProfile.builtIns(fanCount: 1, defaultMaxRPM: 7000)
        for p in list where !p.points.isEmpty {
            XCTAssertEqual(p.points.last?.rpm, 7000,
                "\(p.name) last point should clamp to maxRPM")
        }
    }

    func testBuiltIns_linearHasPredictableSlope() {
        // Linear profile: ~800 RPM per 10°C for predictable response.
        let list = FanProfile.builtIns(fanCount: 1, defaultMaxRPM: 7000)
        let lin = list.first { $0.name == "Linear" }!
        XCTAssertEqual(lin.points.count, 7)
        // Spot-check a couple segments are evenly spaced.
        for i in 1..<(lin.points.count - 1) {
            let prev = lin.points[i-1]
            let cur = lin.points[i]
            let tempDelta = cur.tempC - prev.tempC
            let rpmDelta = Double(cur.rpm - prev.rpm)
            // Most segments are 10°C / 800 RPM; allow ±100 RPM for the end segments.
            let ratio = rpmDelta / tempDelta
            XCTAssertGreaterThan(ratio, 60, "Linear segment \(prev) → \(cur) too flat")
            XCTAssertLessThan(ratio, 120, "Linear segment \(prev) → \(cur) too steep")
        }
    }

    func testBuiltIns_performanceRampsEarliest() {
        // Performance profile reaches half-max RPM at a lower temp than Aggressive.
        let list = FanProfile.builtIns(fanCount: 1, defaultMaxRPM: 7000)
        let perf = list.first { $0.name == "Performance" }!
        let agg = list.first { $0.name == "Aggressive" }!
        // At 50°C: Performance should be at or above Aggressive's RPM.
        let perf50 = FanCurve.interpolate(points: perf.points, tempC: 50)
        let agg50 = FanCurve.interpolate(points: agg.points, tempC: 50)
        XCTAssertGreaterThanOrEqual(perf50, agg50,
            "Performance should ramp earlier than Aggressive at 50°C")
    }

    func testBuiltIns_clampsRpmToMaxRPM() {
        let list = FanProfile.builtIns(fanCount: 1, defaultMaxRPM: 4000)
        for p in list {
            for pt in p.points {
                XCTAssertLessThanOrEqual(pt.rpm, 4000, "\(p.name) has point > maxRPM: \(pt)")
            }
        }
    }

    func testBuiltIns_driversMatchPlatform() {
        // Apple Silicon uses synthesized "Hottest CPU"/"Hottest GPU" sensors
        // (Modules/Sensors/readers.swift); Intel exposes classical TC0D/TG0D SMC keys.
        let expected: Set<String> = isARM
            ? ["Hottest CPU", "Hottest GPU"]
            : ["TC0D", "TG0D"]
        let list = FanProfile.builtIns(fanCount: 1, defaultMaxRPM: 7000)
        for p in list where p.name != "Apple Auto" {
            XCTAssertEqual(Set(p.drivers.map(\.key)), expected, "\(p.name)")
        }
    }

    func testBuiltIns_offsetIs50() {
        let list = FanProfile.builtIns(fanCount: 2, defaultMaxRPM: 7000)
        for p in list { XCTAssertEqual(p.fanOffsetRPM, 50) }
    }

    // MARK: - ProfileStore

    private func clearProfileStore() {
        Store.shared.remove("fanctl_profiles")
        Store.shared.remove("fanctl_activeProfile")
        Store.shared.remove("fanctl_enabled")
        // Daemon-mode flag is set by AppDelegate after probing the helper.
        // Tests run in a unit-test process where no helper exists, so leave
        // this off — any saveProfiles/activeProfileID write under daemon
        // mode would block on a non-existent XPC connection.
        Store.shared.remove("fanctl_daemonMode")
        // Per-fan state leaks across tests since Store.shared is a singleton.
        // Controller writes fan_<id>_mode = .curve(100); user paths write
        // .forced(1). Tests rely on a clean slate.
        for id in 0...3 {
            Store.shared.remove("fan_\(id)_mode")
            Store.shared.remove("fan_\(id)_speed")
        }
    }

    func testProfileStore_loadEmpty_returnsEmptyArray() {
        clearProfileStore()
        let store = ProfileStore()
        XCTAssertTrue(store.loadProfiles().isEmpty)
        clearProfileStore()
    }

    func testProfileStore_saveAndLoad_roundtrip() {
        clearProfileStore()
        let store = ProfileStore()
        let saved = FanProfile.builtIns(fanCount: 1, defaultMaxRPM: 7000)
        store.saveProfiles(saved)
        let loaded = store.loadProfiles()
        XCTAssertEqual(loaded.map(\.id), saved.map(\.id))
        XCTAssertEqual(loaded.map(\.name), saved.map(\.name))
        clearProfileStore()
    }

    func testProfileStore_activeProfileID_nilByDefault() {
        clearProfileStore()
        let store = ProfileStore()
        XCTAssertNil(store.activeProfileID)
        clearProfileStore()
    }

    func testProfileStore_activeProfileID_roundtrip() {
        clearProfileStore()
        let store = ProfileStore()
        let uuid = UUID()
        store.activeProfileID = uuid
        XCTAssertEqual(store.activeProfileID, uuid)
        store.activeProfileID = nil
        XCTAssertNil(store.activeProfileID)
        clearProfileStore()
    }

    // `enabled` is always true now (master toggle removed). Apple Auto profile
    // serves as the "off" semantic. The previous enabled-roundtrip tests were
    // dropped because the property is no-op.

    func testProfileStore_enabled_alwaysTrue() {
        clearProfileStore()
        let store = ProfileStore()
        XCTAssertTrue(store.enabled)
        store.enabled = false
        XCTAssertTrue(store.enabled, "enabled setter is intentionally a no-op")
        clearProfileStore()
    }

    func testProfileStore_activeProfile_resolvesByID() {
        clearProfileStore()
        let store = ProfileStore()
        let list = FanProfile.builtIns(fanCount: 1, defaultMaxRPM: 7000)
        store.saveProfiles(list)
        // Index 3 = "Balanced" (order: Apple Auto, Quiet, Linear, Balanced, Aggressive, Performance)
        store.activeProfileID = list[3].id
        let active = store.activeProfile()
        XCTAssertEqual(active?.id, list[3].id)
        XCTAssertEqual(active?.name, "Balanced")
        clearProfileStore()
    }

    func testProfileStore_activeProfile_returnsNilWhenIDMissing() {
        clearProfileStore()
        let store = ProfileStore()
        store.saveProfiles(FanProfile.builtIns(fanCount: 1, defaultMaxRPM: 7000))
        store.activeProfileID = UUID()  // doesn't match any saved profile
        XCTAssertNil(store.activeProfile())
        clearProfileStore()
    }

    // MARK: - Daemon-mode XPC mirroring
    //
    // Smoke test that ProfileStore writes do not trip a crash when daemon
    // mode is off (the default in tests). We don't mock `SMCHelper.shared`
    // here — that would require a protocol-shaped seam — so a positive
    // assertion that "no XPC call was made" isn't possible at unit level.
    // The negative path is what matters in CI: with daemon mode OFF the
    // code must NOT attempt to talk to a (non-existent) helper. If the
    // gate ever regresses, this test would lock up waiting for an XPC
    // round-trip that never returns.

    func testProfileStore_doesNotPushToDaemon_whenDaemonModeOff() {
        clearProfileStore()
        Store.shared.set(key: "fanctl_daemonMode", value: false)
        let store = ProfileStore()
        store.bootstrapIfNeeded(fanCount: 1, defaultMaxRPM: 7000)
        // If daemon mode were on, the line above would block on an XPC
        // call to a helper that doesn't exist in the unit-test process —
        // bootstrap calls saveProfiles + sets activeProfileID. Reaching
        // this assertion proves the gate is in place.
        XCTAssertGreaterThan(store.loadProfiles().count, 0)
        clearProfileStore()
        Store.shared.remove("fanctl_daemonMode")
    }

    func testProfileStore_bootstrapDaemonIfNeeded_noOpWhenDaemonModeOff() {
        // Doc-test: with daemon mode OFF, `bootstrapDaemonIfNeeded` must
        // gate before any XPC traffic. We can't unit-test the daemon-ON
        // path here — `SMCHelper.shared.getStatusJSON` would attempt a real
        // XPC connection and hang the test process. The negative path is
        // what protects CI: if the gate ever regresses, this test locks up.
        clearProfileStore()
        Store.shared.set(key: "fanctl_daemonMode", value: false)
        let store = ProfileStore()
        store.bootstrapIfNeeded(fanCount: 1, defaultMaxRPM: 7000)
        let before = store.loadProfiles().count
        store.bootstrapDaemonIfNeeded()
        XCTAssertEqual(store.loadProfiles().count, before, "local profiles untouched")
        XCTAssertGreaterThan(before, 0, "bootstrap seeded built-ins")
        clearProfileStore()
        Store.shared.remove("fanctl_daemonMode")
    }

    // MARK: - Bootstrap

    func testBootstrap_emptyStore_writesBuiltInsAndPicksAggressive() {
        clearProfileStore()
        let store = ProfileStore()
        store.bootstrapIfNeeded(fanCount: 1, defaultMaxRPM: 7000)
        let loaded = store.loadProfiles()
        XCTAssertEqual(loaded.count, 6)
        XCTAssertEqual(loaded.map(\.name), Self.builtInOrder)
        let active = store.activeProfile()
        XCTAssertEqual(active?.name, "Aggressive")
        clearProfileStore()
    }

    func testBootstrap_existingStore_leavesItAlone() {
        clearProfileStore()
        let store = ProfileStore()
        let custom = FanProfile(name: "Custom", drivers: [DriverSensor(key: "TC0D")],
                                points: [CurvePoint(tempC: 50, rpm: 2000)])
        store.saveProfiles([custom])
        store.activeProfileID = custom.id
        store.bootstrapIfNeeded(fanCount: 1, defaultMaxRPM: 7000)
        let loaded = store.loadProfiles()
        XCTAssertEqual(loaded.count, 1, "should not have replaced existing profiles")
        XCTAssertEqual(loaded.first?.name, "Custom")
        XCTAssertEqual(store.activeProfile()?.name, "Custom")
        clearProfileStore()
    }

    // MARK: - duplicateProfile

    func testProfileStore_duplicateAppleAuto_seedsExamplePoints() {
        clearProfileStore()
        let store = ProfileStore.shared
        store.bootstrapIfNeeded(fanCount: 1, defaultMaxRPM: 7000)
        let appleAuto = store.loadProfiles().first(where: { $0.id == FanProfile.appleAutoID })!
        XCTAssertTrue(appleAuto.points.isEmpty, "precondition: Apple Auto has no points")
        let copy = store.duplicateProfile(appleAuto)
        XCTAssertFalse(copy.points.isEmpty, "duplicate of Apple Auto should not be empty")
        XCTAssertFalse(copy.drivers.isEmpty, "duplicate of Apple Auto should have default drivers")
        XCTAssertFalse(copy.isBuiltIn, "duplicate should be editable")
        XCTAssertNotEqual(copy.id, appleAuto.id, "duplicate must get a fresh ID")
        XCTAssertEqual(store.activeProfileID, copy.id, "duplicate should become active")
        clearProfileStore()
    }

    func testProfileStore_duplicateNonEmpty_copiesPointsAsIs() {
        clearProfileStore()
        let store = ProfileStore.shared
        store.bootstrapIfNeeded(fanCount: 1, defaultMaxRPM: 7000)
        let balanced = store.loadProfiles().first(where: { $0.name == "Balanced" })!
        let copy = store.duplicateProfile(balanced)
        XCTAssertEqual(copy.points, balanced.points, "non-empty source should copy points verbatim")
        XCTAssertEqual(copy.drivers, balanced.drivers)
        XCTAssertEqual(copy.name, "Balanced (copy)")
        XCTAssertFalse(copy.isBuiltIn)
        clearProfileStore()
    }

    // MARK: - createCustomProfile (in-Settings "+ New profile")

    func testProfileStore_createCustomProfile_seedsFromBalancedAndActivates() {
        clearProfileStore()
        let store = ProfileStore.shared
        store.bootstrapIfNeeded(fanCount: 1, defaultMaxRPM: 7000)
        let balanced = store.loadProfiles().first(where: { $0.name == "Balanced" })!

        let fresh = store.createCustomProfile(fanCount: 1, defaultMaxRPM: 7000)

        XCTAssertEqual(fresh.name, "Custom 1", "first invocation should be Custom 1")
        XCTAssertFalse(fresh.isBuiltIn, "new profile must be editable")
        XCTAssertEqual(fresh.points, balanced.points, "seeded from Balanced curve")
        XCTAssertEqual(fresh.drivers, balanced.drivers, "seeded from Balanced drivers")
        XCTAssertEqual(store.activeProfileID, fresh.id, "fresh profile should become active")
        XCTAssertTrue(store.loadProfiles().contains(where: { $0.id == fresh.id }), "must be persisted")
        clearProfileStore()
    }

    func testProfileStore_createCustomProfile_pickFreshNameWhenCollision() {
        clearProfileStore()
        let store = ProfileStore.shared
        store.bootstrapIfNeeded(fanCount: 1, defaultMaxRPM: 7000)

        let first = store.createCustomProfile(fanCount: 1, defaultMaxRPM: 7000)
        let second = store.createCustomProfile(fanCount: 1, defaultMaxRPM: 7000)
        let third = store.createCustomProfile(fanCount: 1, defaultMaxRPM: 7000)

        XCTAssertEqual(first.name, "Custom 1")
        XCTAssertEqual(second.name, "Custom 2")
        XCTAssertEqual(third.name, "Custom 3")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(second.id, third.id)
        clearProfileStore()
    }

    // MARK: - resetToDefault

    func testProfileStore_resetToDefault_restoresBuiltInValues() {
        clearProfileStore()
        let store = ProfileStore.shared
        store.bootstrapIfNeeded(fanCount: 1, defaultMaxRPM: 7000)
        let balancedID = store.loadProfiles().first(where: { $0.name == "Balanced" })!.id

        // User edits Balanced — overwrite its points with garbage.
        var all = store.loadProfiles()
        if let idx = all.firstIndex(where: { $0.id == balancedID }) {
            all[idx] = FanProfile(
                id: all[idx].id, name: all[idx].name, isBuiltIn: all[idx].isBuiltIn,
                drivers: [], points: [CurvePoint(tempC: 0, rpm: 999)],
                fanOffsetRPM: 0, hysteresisC: 0, deltaRpmThreshold: 0
            )
            store.saveProfiles(all)
        }
        XCTAssertEqual(store.loadProfiles().first(where: { $0.id == balancedID })?.points.count, 1,
                       "precondition: corrupted Balanced has 1 garbage point")

        let ok = store.resetToDefault(balancedID, fanCount: 1, defaultMaxRPM: 7000)
        XCTAssertTrue(ok, "reset must succeed for a built-in id")
        let restored = store.loadProfiles().first(where: { $0.id == balancedID })!
        XCTAssertGreaterThan(restored.points.count, 1,
                             "Balanced default has multiple curve points")
        XCTAssertFalse(restored.drivers.isEmpty,
                       "Balanced default has driver sensors")
        XCTAssertEqual(restored.fanOffsetRPM, 50, "factory offset restored")
        XCTAssertEqual(restored.id, balancedID, "id must be preserved")
        clearProfileStore()
    }

    func testProfileStore_resetToDefault_returnsFalseForCustom() {
        clearProfileStore()
        let store = ProfileStore.shared
        store.bootstrapIfNeeded(fanCount: 1, defaultMaxRPM: 7000)
        let custom = store.createCustomProfile(fanCount: 1, defaultMaxRPM: 7000)
        let ok = store.resetToDefault(custom.id, fanCount: 1, defaultMaxRPM: 7000)
        XCTAssertFalse(ok, "custom profile has no built-in default to reset to")
        clearProfileStore()
    }

    // MARK: - FakeFanCurveHelper baseline

    func testFakeHelper_recordsSetFanModeCalls() {
        let fake = FakeFanCurveHelper()
        fake.setFanMode(id: 0, mode: FanMode.forced.rawValue)
        XCTAssertEqual(fake.modeCalls, [.init(id: 0, mode: 1)])
    }

    func testFakeHelper_recordsSetFanSpeedCalls() {
        let fake = FakeFanCurveHelper()
        fake.setFanSpeed(id: 0, value: 4000)
        XCTAssertEqual(fake.speedCalls, [.init(id: 0, rpm: 4000)])
    }

    func testFakeHelper_isActiveControllable() {
        let fake = FakeFanCurveHelper()
        XCTAssertTrue(fake.isActive())
        fake.isActiveValue = false
        XCTAssertFalse(fake.isActive())
    }

    // MARK: - Controller tick basics

    private func makeControllerFan(id: Int, min: Double = 1000, max: Double = 7000,
                                   value: Double = 1000,
                                   smcMode: FanMode? = nil) -> Fan {
        var f = Fan(id: id, key: "F\(id)Ac", name: "Fan \(id)",
            minSpeed: min, maxSpeed: max, value: value, mode: .automatic)
        // Fan.smcMode is the Sensors-target copy of FanMode (smc.swift is
        // compiled into both Kit and Sensors targets — two distinct enum
        // types at the Swift type level despite identical declarations).
        // The class typealias pins bare `FanMode` to Kit.FanMode, so bridge
        // here via rawValue, which is stable across both copies (locked by
        // testFanMode_rawValues_matchSMC).
        f.smcMode = smcMode.flatMap { type(of: f.mode).init(rawValue: $0.rawValue) }
        return f
    }

    private func makeControllerSnapshot(fans: [Fan], temps: [(String, Double)]) -> Sensors_List {
        let list = Sensors_List()
        list.sensors = temps.map { makeTempSensor(key: $0.0, value: $0.1) }
                          + fans.map { $0 as Sensor_p }
        return list
    }

    func testController_disabledStore_doesNothing() {
        clearProfileStore()
        let fake = FakeFanCurveHelper()
        let c = FanCurveController(helper: fake, store: ProfileStore())
        let snap = makeControllerSnapshot(fans: [makeControllerFan(id: 0)],
                                          temps: [("TC0D", 70)])
        c.tick(snapshot: snap)
        XCTAssertEqual(fake.modeCalls.count, 0)
        XCTAssertEqual(fake.speedCalls.count, 0)
        clearProfileStore()
    }

    func testController_helperInactive_doesNothing() {
        clearProfileStore()
        let store = ProfileStore()
        store.enabled = true
        store.bootstrapIfNeeded(fanCount: 1, defaultMaxRPM: 7000)
        let fake = FakeFanCurveHelper(); fake.isActiveValue = false
        let c = FanCurveController(helper: fake, store: store)
        let snap = makeControllerSnapshot(fans: [makeControllerFan(id: 0)],
                                          temps: [("TC0D", 70)])
        c.tick(snapshot: snap)
        XCTAssertEqual(fake.modeCalls.count, 0)
        XCTAssertEqual(fake.speedCalls.count, 0)
        clearProfileStore()
    }

    func testController_enabledWithProfile_setsForcedAndApplies() {
        clearProfileStore()
        let store = ProfileStore()
        store.enabled = true
        store.bootstrapIfNeeded(fanCount: 1, defaultMaxRPM: 7000)
        let fake = FakeFanCurveHelper()
        let c = FanCurveController(helper: fake, store: store)
        // Aggressive profile drivers are platform-dependent — use whatever the
        // bootstrap actually wrote so the snapshot's temp keys match.
        let driverKeys = store.activeProfile()!.drivers.map(\.key)
        let temps = driverKeys.enumerated().map { (i, key) in
            (key, i == 0 ? 65.0 : 50.0)
        }
        let snap = makeControllerSnapshot(fans: [makeControllerFan(id: 0)], temps: temps)
        c.tick(snapshot: snap)
        // First apply sets mode to .forced exactly once.
        XCTAssertEqual(fake.modeCalls, [.init(id: 0, mode: FanMode.forced.rawValue)])
        // Effective temp = max(65, 50) = 65°C. Aggressive curve between
        // (60, 3800) and (66, 4500) → interpolate to 4383.
        XCTAssertEqual(fake.speedCalls.count, 1)
        XCTAssertEqual(fake.speedCalls[0].id, 0)
        XCTAssertEqual(fake.speedCalls[0].rpm, 4383)
        clearProfileStore()
    }

    func testController_secondTickSameTemp_doesNotResendMode() {
        clearProfileStore()
        let store = ProfileStore()
        store.enabled = true
        store.bootstrapIfNeeded(fanCount: 1, defaultMaxRPM: 7000)
        let fake = FakeFanCurveHelper()
        let c = FanCurveController(helper: fake, store: store)
        let driverKeys = store.activeProfile()!.drivers.map(\.key)
        let snap = makeControllerSnapshot(fans: [makeControllerFan(id: 0)],
                                          temps: driverKeys.map { ($0, 65.0) })
        c.tick(snapshot: snap)
        fake.reset()
        c.tick(snapshot: snap)
        XCTAssertEqual(fake.modeCalls.count, 0, "mode should not be re-set on every tick")
    }

    // MARK: - Controller hysteresis & throttle

    private func enabledStoreWithCustomProfile(_ profile: FanProfile) -> ProfileStore {
        let store = ProfileStore()
        store.enabled = true
        store.saveProfiles([profile])
        store.activeProfileID = profile.id
        return store
    }

    private let linearProfile = FanProfile(
        name: "Linear",
        drivers: [DriverSensor(key: "TC0D")],
        points: [CurvePoint(tempC: 30, rpm: 1000),
                 CurvePoint(tempC: 80, rpm: 6000)],
        fanOffsetRPM: 0, hysteresisC: 2.0, deltaRpmThreshold: 200)

    func testController_throttle_skipsApplyWhenDeltaUnderThreshold() {
        clearProfileStore()
        let store = enabledStoreWithCustomProfile(linearProfile)
        let fake = FakeFanCurveHelper()
        // Advance >5s between ticks so the new smoothing window prunes the
        // prior sample — keeps this test focused on throttle behavior, not
        // smoothing or derivative artifacts of two near-simultaneous samples.
        let clock = FakeFanControllerClock()
        let c = FanCurveController(helper: fake, store: store, clock: clock)
        // temp=55 → rpm=3500, temp=55.5 → rpm=3550 (delta=50 < threshold=200)
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 55)]))
        XCTAssertEqual(fake.speedCalls.count, 1)
        clock.advance(by: 6)
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 55.5)]))
        XCTAssertEqual(fake.speedCalls.count, 1, "delta < threshold should suppress")
        clearProfileStore()
    }

    func testController_throttle_appliesPastThreshold() {
        clearProfileStore()
        let store = enabledStoreWithCustomProfile(linearProfile)
        let fake = FakeFanCurveHelper()
        let clock = FakeFanControllerClock()
        let c = FanCurveController(helper: fake, store: store, clock: clock)
        // temp=55 → 3500, temp=60 → 4000 (delta=500 ≥ threshold)
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 55)]))
        clock.advance(by: 6)  // prune prior sample so smoothing/derivative don't skew
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 60)]))
        XCTAssertEqual(fake.speedCalls.map(\.rpm), [3500, 4000])
        clearProfileStore()
    }

    func testController_hysteresis_blocksLoweringInsideBand() {
        clearProfileStore()
        let p = FanProfile(name: "Hyst",
            drivers: [DriverSensor(key: "TC0D")],
            points: [CurvePoint(tempC: 30, rpm: 1000), CurvePoint(tempC: 80, rpm: 6000)],
            fanOffsetRPM: 0, hysteresisC: 5.0, deltaRpmThreshold: 100)
        let store = enabledStoreWithCustomProfile(p)
        let fake = FakeFanCurveHelper()
        let c = FanCurveController(helper: fake, store: store)
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 70)]))
        // tempDrop=3 < hyst=5 → suppress even though delta=300 ≥ thresh=100
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 67)]))
        XCTAssertEqual(fake.speedCalls.count, 1, "hysteresis should block lowering")
        clearProfileStore()
    }

    func testController_hysteresis_allowsLoweringPastBand() {
        clearProfileStore()
        let p = FanProfile(name: "Hyst",
            drivers: [DriverSensor(key: "TC0D")],
            points: [CurvePoint(tempC: 30, rpm: 1000), CurvePoint(tempC: 80, rpm: 6000)],
            fanOffsetRPM: 0, hysteresisC: 5.0, deltaRpmThreshold: 100)
        let store = enabledStoreWithCustomProfile(p)
        let fake = FakeFanCurveHelper()
        let clock = FakeFanControllerClock()
        let c = FanCurveController(helper: fake, store: store, clock: clock)
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 70)]))
        // tempDrop=6 > hyst=5 → allow. Advance past smoothing window so prior
        // sample is pruned and the assertion is exclusively about hysteresis.
        clock.advance(by: 6)
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 64)]))
        XCTAssertEqual(fake.speedCalls.count, 2)
        clearProfileStore()
    }

    func testController_hysteresis_doesNotBlockRaising() {
        clearProfileStore()
        let p = FanProfile(name: "Hyst",
            drivers: [DriverSensor(key: "TC0D")],
            points: [CurvePoint(tempC: 30, rpm: 1000), CurvePoint(tempC: 80, rpm: 6000)],
            fanOffsetRPM: 0, hysteresisC: 5.0, deltaRpmThreshold: 100)
        let store = enabledStoreWithCustomProfile(p)
        let fake = FakeFanCurveHelper()
        let c = FanCurveController(helper: fake, store: store)
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 50)]))
        // small temp rise +2°C inside hyst band; raising always allowed past threshold
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 52)]))
        XCTAssertEqual(fake.speedCalls.count, 2)
        clearProfileStore()
    }

    // MARK: - Controller per-fan offset

    func testController_twoFans_appliesOffsetToFan1() {
        clearProfileStore()
        let p = FanProfile(name: "Off",
            drivers: [DriverSensor(key: "TC0D")],
            points: [CurvePoint(tempC: 30, rpm: 1000), CurvePoint(tempC: 80, rpm: 6000)],
            fanOffsetRPM: 100, hysteresisC: 0.1, deltaRpmThreshold: 1)
        let store = enabledStoreWithCustomProfile(p)
        let fake = FakeFanCurveHelper()
        let c = FanCurveController(helper: fake, store: store)
        // temp=55 → base=3500. Fan 0 → 3500, Fan 1 → 3600.
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0), makeControllerFan(id: 1)],
            temps: [("TC0D", 55)]))
        let fan0Rpm = fake.speedCalls.first { $0.id == 0 }?.rpm
        let fan1Rpm = fake.speedCalls.first { $0.id == 1 }?.rpm
        XCTAssertEqual(fan0Rpm, 3500)
        XCTAssertEqual(fan1Rpm, 3600)
        clearProfileStore()
    }

    func testController_offsetClampedToMaxSpeed() {
        clearProfileStore()
        let p = FanProfile(name: "Off",
            drivers: [DriverSensor(key: "TC0D")],
            points: [CurvePoint(tempC: 30, rpm: 1000), CurvePoint(tempC: 80, rpm: 6000)],
            fanOffsetRPM: 500, hysteresisC: 0.1, deltaRpmThreshold: 1)
        let store = enabledStoreWithCustomProfile(p)
        let fake = FakeFanCurveHelper()
        let c = FanCurveController(helper: fake, store: store)
        // Fan 1 maxSpeed = 5800; base at 75 = 5500; +500 offset = 6000 → clamped to 5800
        let fan0 = makeControllerFan(id: 0, max: 7000)
        let fan1 = makeControllerFan(id: 1, max: 5800)
        c.tick(snapshot: makeControllerSnapshot(
            fans: [fan0, fan1], temps: [("TC0D", 75)]))
        let fan1Rpm = fake.speedCalls.first { $0.id == 1 }?.rpm
        XCTAssertEqual(fan1Rpm, 5800)
        clearProfileStore()
    }

    // MARK: - Controller relinquish

    func testController_emptyPointsProfile_relinquishesManagedFans() {
        clearProfileStore()
        let active = FanProfile(name: "Linear",
            drivers: [DriverSensor(key: "TC0D")],
            points: [CurvePoint(tempC: 30, rpm: 1000), CurvePoint(tempC: 80, rpm: 6000)],
            fanOffsetRPM: 0)
        let store = enabledStoreWithCustomProfile(active)
        let fake = FakeFanCurveHelper()
        let c = FanCurveController(helper: fake, store: store)
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 60)]))
        // Now swap to an empty-points profile (Apple Auto)
        let auto = FanProfile(name: "Auto",
            drivers: [DriverSensor(key: "TC0D")], points: [], fanOffsetRPM: 0)
        store.saveProfiles([active, auto])
        store.activeProfileID = auto.id
        fake.reset()
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 60)]))
        XCTAssertEqual(fake.modeCalls,
            [.init(id: 0, mode: FanMode.automatic.rawValue)])
        XCTAssertEqual(fake.speedCalls.count, 0)
        clearProfileStore()
    }

    func testController_shutdownReleasesManagedFans() {
        clearProfileStore()
        let active = FanProfile(name: "Linear",
            drivers: [DriverSensor(key: "TC0D")],
            points: [CurvePoint(tempC: 30, rpm: 1000), CurvePoint(tempC: 80, rpm: 6000)],
            fanOffsetRPM: 0)
        let store = enabledStoreWithCustomProfile(active)
        let fake = FakeFanCurveHelper()
        let c = FanCurveController(helper: fake, store: store)
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 60)]))
        XCTAssertTrue(fake.modeCalls.contains(.init(id: 0, mode: FanMode.forced.rawValue)))
        fake.reset()
        // Explicit shutdown (e.g., Sensors.willTerminate) releases the fans.
        c.shutdown()
        XCTAssertEqual(fake.modeCalls,
            [.init(id: 0, mode: FanMode.automatic.rawValue)])
        clearProfileStore()
    }

    // MARK: - Controller sleep/wake

    func testController_sleep_relinquishesAndBlocksTicks() {
        clearProfileStore()
        let active = FanProfile(name: "Linear",
            drivers: [DriverSensor(key: "TC0D")],
            points: [CurvePoint(tempC: 30, rpm: 1000), CurvePoint(tempC: 80, rpm: 6000)],
            fanOffsetRPM: 0)
        let store = enabledStoreWithCustomProfile(active)
        let fake = FakeFanCurveHelper()
        let c = FanCurveController(helper: fake, store: store)
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 60)]))
        fake.reset()
        c.handleWillSleepForTests()
        XCTAssertEqual(fake.modeCalls,
            [.init(id: 0, mode: FanMode.automatic.rawValue)])
        fake.reset()
        // Ticks during sleep are no-ops
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 75)]))
        XCTAssertEqual(fake.modeCalls.count, 0)
        XCTAssertEqual(fake.speedCalls.count, 0)
        clearProfileStore()
    }

    func testController_wake_resumesOnNextTick() {
        clearProfileStore()
        let active = FanProfile(name: "Linear",
            drivers: [DriverSensor(key: "TC0D")],
            points: [CurvePoint(tempC: 30, rpm: 1000), CurvePoint(tempC: 80, rpm: 6000)],
            fanOffsetRPM: 0)
        let store = enabledStoreWithCustomProfile(active)
        let fake = FakeFanCurveHelper()
        let c = FanCurveController(helper: fake, store: store)
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 60)]))
        c.handleWillSleepForTests()
        fake.reset()
        c.handleDidWakeForTests()
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 60)]))
        XCTAssertTrue(fake.modeCalls.contains(.init(id: 0, mode: FanMode.forced.rawValue)))
        XCTAssertEqual(fake.speedCalls.count, 1)
        clearProfileStore()
    }

    // MARK: - Controller profile-change reset

    // MARK: - Controller bootstrap on first tick

    func testController_firstTick_bootstrapsProfilesAndPicksAggressive() {
        clearProfileStore()
        let store = ProfileStore()
        store.enabled = true
        let fake = FakeFanCurveHelper()
        let c = FanCurveController(helper: fake, store: store)
        XCTAssertEqual(store.loadProfiles().count, 0, "precondition: empty store")
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0, max: 7000)],
            temps: [("TC0D", 50)]))
        XCTAssertEqual(store.loadProfiles().count, 6)
        XCTAssertEqual(store.activeProfile()?.name, "Aggressive")
        clearProfileStore()
    }

    // MARK: - Crash recovery (Sensors.resetStaleCurveModes)

    func testResetStale_helperInactive_doesNothing() {
        clearProfileStore()
        Store.shared.set(key: "fan_0_mode", value: FanMode.curve.rawValue)
        let fake = FakeFanCurveHelper()
        fake.isActiveValue = false
        Sensors.resetStaleCurveModes(helper: fake, store: ProfileStore())
        XCTAssertEqual(fake.modeCalls.count, 0, "no helper → no SMC writes")
        // Stored fan_0_mode is left as-is for next launch to retry.
        XCTAssertEqual(Store.shared.int(key: "fan_0_mode", defaultValue: -1),
                       FanMode.curve.rawValue)
        clearProfileStore()
    }

    func testResetStale_noActiveProfile_resetsCurveFan() {
        clearProfileStore()
        Store.shared.set(key: "fan_0_mode", value: FanMode.curve.rawValue)
        Store.shared.set(key: "fan_1_mode", value: FanMode.curve.rawValue)
        let fake = FakeFanCurveHelper()
        // No active profile → all .curve fans should be reset.
        Sensors.resetStaleCurveModes(helper: fake, store: ProfileStore())
        // Iteration order is 0..3 deterministic.
        XCTAssertEqual(fake.modeCalls, [
            .init(id: 0, mode: FanMode.automatic.rawValue),
            .init(id: 1, mode: FanMode.automatic.rawValue),
        ])
        XCTAssertEqual(Store.shared.int(key: "fan_0_mode", defaultValue: -1),
                       FanMode.automatic.rawValue)
        XCTAssertEqual(Store.shared.int(key: "fan_1_mode", defaultValue: -1),
                       FanMode.automatic.rawValue)
        clearProfileStore()
    }

    func testResetStale_withActiveProfile_leavesCurveFanAlone() {
        clearProfileStore()
        // Populate active profile.
        let store = ProfileStore()
        let p = FanProfile(name: "P", drivers: [DriverSensor(key: "TC0D")],
            points: [CurvePoint(tempC: 30, rpm: 1000), CurvePoint(tempC: 80, rpm: 6000)])
        store.saveProfiles([p])
        store.activeProfileID = p.id
        Store.shared.set(key: "fan_0_mode", value: FanMode.curve.rawValue)
        let fake = FakeFanCurveHelper()
        Sensors.resetStaleCurveModes(helper: fake, store: store)
        // Stats is still managing this fan via active profile — don't touch it.
        XCTAssertEqual(fake.modeCalls.count, 0,
                       "active profile present → controller will re-take fan, no reset needed")
        XCTAssertEqual(Store.shared.int(key: "fan_0_mode", defaultValue: -1),
                       FanMode.curve.rawValue)
        clearProfileStore()
    }

    func testResetStale_nonCurveMode_isIgnored() {
        clearProfileStore()
        // User-forced fan (Manual/Off/Max) — leave alone.
        Store.shared.set(key: "fan_0_mode", value: FanMode.forced.rawValue)
        let fake = FakeFanCurveHelper()
        Sensors.resetStaleCurveModes(helper: fake, store: ProfileStore())
        XCTAssertEqual(fake.modeCalls.count, 0, "only .curve mode is crash-recovered")
        XCTAssertEqual(Store.shared.int(key: "fan_0_mode", defaultValue: -1),
                       FanMode.forced.rawValue)
        clearProfileStore()
    }

    // MARK: - Audit fixes (managed-fans cleanup, user takeover, helper drop)

    func testController_userTakeoverViaCustomMode_yieldsFan() {
        clearProfileStore()
        let p = FanProfile(name: "P",
            drivers: [DriverSensor(key: "TC0D")],
            points: [CurvePoint(tempC: 30, rpm: 1000), CurvePoint(tempC: 80, rpm: 6000)],
            fanOffsetRPM: 0)
        let store = enabledStoreWithCustomProfile(p)
        let fake = FakeFanCurveHelper()
        let c = FanCurveController(helper: fake, store: store)
        // First tick: controller manages fan 0.
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 60)]))
        XCTAssertTrue(fake.modeCalls.contains(.init(id: 0, mode: FanMode.forced.rawValue)))
        XCTAssertEqual(fake.speedCalls.count, 1)
        // User picks Manual/Off/Max → callback writes customMode = .forced.
        var fan = makeControllerFan(id: 0)
        fan.customMode = .forced
        fake.reset()
        c.tick(snapshot: makeControllerSnapshot(fans: [fan], temps: [("TC0D", 60)]))
        // Controller yields: no SMC writes for user-managed fan.
        XCTAssertEqual(fake.modeCalls.count, 0, "user takeover should suppress controller writes")
        XCTAssertEqual(fake.speedCalls.count, 0)
        fan.customMode = nil
        clearProfileStore()
    }

    func testController_helperGoesAway_clearsManagedState() {
        clearProfileStore()
        let p = FanProfile(name: "P",
            drivers: [DriverSensor(key: "TC0D")],
            points: [CurvePoint(tempC: 30, rpm: 1000), CurvePoint(tempC: 80, rpm: 6000)],
            fanOffsetRPM: 0)
        let store = enabledStoreWithCustomProfile(p)
        let fake = FakeFanCurveHelper()
        let c = FanCurveController(helper: fake, store: store)
        // Manage fan 0.
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 60)]))
        XCTAssertTrue(fake.modeCalls.contains(.init(id: 0, mode: FanMode.forced.rawValue)))
        // Helper disappears mid-session.
        fake.isActiveValue = false
        fake.reset()
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 60)]))
        XCTAssertEqual(fake.modeCalls.count, 0, "no helper → no SMC writes")
        // Helper comes back. Without the clear-on-isActive-false fix the
        // controller would think fan is already managed and skip setFanMode.
        fake.isActiveValue = true
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 60)]))
        XCTAssertTrue(fake.modeCalls.contains(.init(id: 0, mode: FanMode.forced.rawValue)),
            "helper-back should re-assert forced mode")
        clearProfileStore()
    }

    func testController_profileChangedNotification_clearsManagedFans() {
        clearProfileStore()
        let p = FanProfile(name: "P",
            drivers: [DriverSensor(key: "TC0D")],
            points: [CurvePoint(tempC: 30, rpm: 1000), CurvePoint(tempC: 80, rpm: 6000)],
            fanOffsetRPM: 0)
        let store = enabledStoreWithCustomProfile(p)
        let fake = FakeFanCurveHelper()
        let c = FanCurveController(helper: fake, store: store)
        // Manage fan 0.
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 60)]))
        XCTAssertTrue(fake.modeCalls.contains(.init(id: 0, mode: FanMode.forced.rawValue)))
        // Profile change notification — observer should drop managedFans.
        fake.reset()
        let exp = expectation(description: "observer drained")
        NotificationCenter.default.post(name: .fanProfileChanged, object: nil)
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        // Next tick re-asserts setFanMode because managedFans was cleared.
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 60)]))
        XCTAssertTrue(fake.modeCalls.contains(.init(id: 0, mode: FanMode.forced.rawValue)),
            "fanProfileChanged should clear managedFans so next tick re-asserts forced mode")
        _ = c
        clearProfileStore()
    }

    func testController_profileChangedNotification_resetsLastApplied() {
        clearProfileStore()
        let p1 = FanProfile(name: "P1",
            drivers: [DriverSensor(key: "TC0D")],
            points: [CurvePoint(tempC: 30, rpm: 1000), CurvePoint(tempC: 80, rpm: 6000)],
            fanOffsetRPM: 0, hysteresisC: 5.0, deltaRpmThreshold: 100)
        let store = enabledStoreWithCustomProfile(p1)
        let fake = FakeFanCurveHelper()
        let c = FanCurveController(helper: fake, store: store)
        // Apply at temp=70 → rpm=5000
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 70)]))
        // Swap to a new profile with same id (different points). Without reset,
        // small drops would be blocked by hysteresis (5.0°C band).
        let p2 = FanProfile(id: p1.id,
            name: "P2",
            drivers: [DriverSensor(key: "TC0D")],
            points: [CurvePoint(tempC: 30, rpm: 2000), CurvePoint(tempC: 80, rpm: 7000)],
            fanOffsetRPM: 0, hysteresisC: 5.0, deltaRpmThreshold: 100)
        store.saveProfiles([p2])
        fake.reset()
        NotificationCenter.default.post(name: .fanProfileChanged, object: nil)
        // Tick at temp=69 (1°C drop). Without reset, hysteresis (5.0) would block.
        // With reset, hyst state cleared → applies the new profile's curve.
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 69)]))
        XCTAssertEqual(fake.speedCalls.count, 1, "profile change should clear hysteresis state")
        clearProfileStore()
    }

    // MARK: - Smart fan features (smoothing, derivative, battery)

    /// Linear profile used by smoothing/derivative tests: each 1°C ≙ 100 RPM,
    /// no offset/hysteresis/throttle so the curve target is the only signal.
    private var smartLinearProfile: FanProfile {
        FanProfile(name: "SmartLinear",
            drivers: [DriverSensor(key: "TC0D")],
            points: [CurvePoint(tempC: 30, rpm: 1000), CurvePoint(tempC: 80, rpm: 6000)],
            fanOffsetRPM: 0, hysteresisC: 0.0, deltaRpmThreshold: 1)
    }

    /// Tick `controller` at a synthetic time and CPU temp. Returns the last
    /// `setFanSpeed` call recorded by `fake`, or nil if nothing was applied
    /// (throttled / hyst-blocked / fan unmanaged).
    @discardableResult
    private func tickAt(_ controller: FanCurveController, clock: FakeFanControllerClock,
                        fake: FakeFanCurveHelper, advance: TimeInterval,
                        fans: [Fan], temps: [(String, Double)]) -> FakeFanCurveHelper.SpeedCall? {
        clock.advance(by: advance)
        let before = fake.speedCalls.count
        controller.tick(snapshot: makeControllerSnapshot(fans: fans, temps: temps))
        return fake.speedCalls.count > before ? fake.speedCalls.last : nil
    }

    // --- median helper (exposed via _medianForTests) ---

    func testMedian_emptyReturnsZero() {
        XCTAssertEqual(FanCurveController._medianForTests([]), 0)
    }

    func testMedian_singleReturnsItself() {
        XCTAssertEqual(FanCurveController._medianForTests([42.5]), 42.5)
    }

    func testMedian_threeSorted() {
        XCTAssertEqual(FanCurveController._medianForTests([1, 2, 3]), 2)
    }

    func testMedian_threeUnsorted() {
        XCTAssertEqual(FanCurveController._medianForTests([3, 1, 2]), 2)
    }

    func testMedian_evenCountAveragesMiddle() {
        XCTAssertEqual(FanCurveController._medianForTests([1, 2, 3, 4]), 2.5)
        XCTAssertEqual(FanCurveController._medianForTests([10, 20]), 15)
    }

    // --- smoothing ---

    func testSmoothing_singleSampleMatchesRaw() {
        clearProfileStore()
        let store = enabledStoreWithCustomProfile(smartLinearProfile)
        let fake = FakeFanCurveHelper()
        let clock = FakeFanControllerClock()
        let c = FanCurveController(helper: fake, store: store, clock: clock)
        let fan = makeControllerFan(id: 0)
        // One sample at 60°C → curve = 1000 + 30*100 = 4000. Single sample,
        // no prior data → derivative = 0, no battery → target = 4000.
        tickAt(c, clock: clock, fake: fake, advance: 0,
               fans: [fan], temps: [("TC0D", 60)])
        XCTAssertEqual(fake.speedCalls.last?.rpm, 4000)
        clearProfileStore()
    }

    func testSmoothing_threeSamplesUseMedian() {
        clearProfileStore()
        let store = enabledStoreWithCustomProfile(smartLinearProfile)
        let fake = FakeFanCurveHelper()
        let clock = FakeFanControllerClock()
        let c = FanCurveController(helper: fake, store: store, clock: clock)
        let fan = makeControllerFan(id: 0)
        // Samples 50, 100, 60 — median = 60. Curve(60) = 4000.
        // first/last (50→60) over 2s = 5 C/s → derivative bonus +500.
        // Expected target = 4000 + 500 = 4500. The point is: NOT 6000 (which
        // is what the noisy 100°C spike would produce without smoothing).
        tickAt(c, clock: clock, fake: fake, advance: 0,
               fans: [fan], temps: [("TC0D", 50)])
        tickAt(c, clock: clock, fake: fake, advance: 1,
               fans: [fan], temps: [("TC0D", 100)])
        tickAt(c, clock: clock, fake: fake, advance: 1,
               fans: [fan], temps: [("TC0D", 60)])
        XCTAssertEqual(fake.speedCalls.last?.rpm, 4500,
                       "median(50,100,60)=60 → curve=4000 + derivative bonus 500")
        clearProfileStore()
    }

    func testSmoothing_oldSamplesPruned() {
        clearProfileStore()
        let store = enabledStoreWithCustomProfile(smartLinearProfile)
        let fake = FakeFanCurveHelper()
        let clock = FakeFanControllerClock()
        let c = FanCurveController(helper: fake, store: store, clock: clock)
        let fan = makeControllerFan(id: 0)
        // Three samples at 50°C
        tickAt(c, clock: clock, fake: fake, advance: 0,
               fans: [fan], temps: [("TC0D", 50)])
        tickAt(c, clock: clock, fake: fake, advance: 1,
               fans: [fan], temps: [("TC0D", 50)])
        tickAt(c, clock: clock, fake: fake, advance: 1,
               fans: [fan], temps: [("TC0D", 50)])
        // Jump past 5s window — old samples should be pruned out
        tickAt(c, clock: clock, fake: fake, advance: 10,
               fans: [fan], temps: [("TC0D", 70)])
        // Only new sample remains in window → median = 70 → curve = 5000.
        // derivative = 0 (single sample after prune), battery = 0.
        XCTAssertEqual(fake.speedCalls.last?.rpm, 5000,
                       "pruned old samples → median(70)=70 → curve=5000")
        clearProfileStore()
    }

    func testSmoothing_resetOnProfileChange() {
        clearProfileStore()
        let store = enabledStoreWithCustomProfile(smartLinearProfile)
        let fake = FakeFanCurveHelper()
        let clock = FakeFanControllerClock()
        let c = FanCurveController(helper: fake, store: store, clock: clock)
        let fan = makeControllerFan(id: 0)
        // Stack two samples (would median to 75 → 5500 with +500 derivative
        // bonus on the next 60°C tick if state weren't reset).
        tickAt(c, clock: clock, fake: fake, advance: 0,
               fans: [fan], temps: [("TC0D", 50)])
        tickAt(c, clock: clock, fake: fake, advance: 1,
               fans: [fan], temps: [("TC0D", 100)])
        // Profile-change observer wipes tempSamples + batteryHotSince, then
        // synchronously re-ticks with the cached snapshot (temp=100) — that
        // re-tick adds one fresh sample [(100)]. Advance the clock past the
        // sample window (5s) so that sample is pruned before our final tick,
        // isolating "samples must be reset" from immediate-apply behavior.
        NotificationCenter.default.post(name: .fanProfileChanged, object: nil)
        // Let main-queue async observer block drain
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        fake.reset()
        // Advance > sample window (5s) to prune the observer's re-tick sample.
        // Then next tick is effectively first-of-session: 60°C → curve = 4000,
        // derivative = 0 (only one sample), no bonus. If pre-notification
        // samples (50, 100) had leaked through, median would be wrong.
        tickAt(c, clock: clock, fake: fake, advance: 6,
               fans: [fan], temps: [("TC0D", 60)])
        XCTAssertEqual(fake.speedCalls.last?.rpm, 4000,
                       "samples must be reset on profile change")
        clearProfileStore()
    }

    // --- derivative pre-ramp ---

    func testDerivative_belowThreshold_noBonus() {
        clearProfileStore()
        let store = enabledStoreWithCustomProfile(smartLinearProfile)
        let fake = FakeFanCurveHelper()
        let clock = FakeFanControllerClock()
        let c = FanCurveController(helper: fake, store: store, clock: clock)
        let fan = makeControllerFan(id: 0)
        // 50 → 51 over 2s = 0.5°C/s, below 2°C/s threshold.
        // Median of (50, 51) = 50.5 → curve = 1000 + 20.5*100 = 3050.
        tickAt(c, clock: clock, fake: fake, advance: 0,
               fans: [fan], temps: [("TC0D", 50)])
        tickAt(c, clock: clock, fake: fake, advance: 2,
               fans: [fan], temps: [("TC0D", 51)])
        XCTAssertEqual(fake.speedCalls.last?.rpm, 3050,
                       "0.5°C/s < 2°C/s threshold → no derivative bonus")
        clearProfileStore()
    }

    func testDerivative_atOrAboveThreshold_addsBonus() {
        clearProfileStore()
        let store = enabledStoreWithCustomProfile(smartLinearProfile)
        let fake = FakeFanCurveHelper()
        let clock = FakeFanControllerClock()
        let c = FanCurveController(helper: fake, store: store, clock: clock)
        let fan = makeControllerFan(id: 0)
        // 50 → 60 over 2s = 5°C/s, above threshold → +500 RPM bonus.
        // Median(50,60) = 55 → curve = 1000 + 25*100 = 3500. +500 = 4000.
        tickAt(c, clock: clock, fake: fake, advance: 0,
               fans: [fan], temps: [("TC0D", 50)])
        tickAt(c, clock: clock, fake: fake, advance: 2,
               fans: [fan], temps: [("TC0D", 60)])
        XCTAssertEqual(fake.speedCalls.last?.rpm, 4000,
                       "5°C/s ≥ 2°C/s → curve(55)=3500 + bonus 500 = 4000")
        clearProfileStore()
    }

    func testDerivative_clampedByMaxSpeed() {
        clearProfileStore()
        let store = enabledStoreWithCustomProfile(smartLinearProfile)
        let fake = FakeFanCurveHelper()
        let clock = FakeFanControllerClock()
        let c = FanCurveController(helper: fake, store: store, clock: clock)
        // maxSpeed = 5800. After ticks at 70 then 80:
        //   median(70,80)=75 → curve = 1000+45*100 = 5500
        //   derivative = (80-70)/2 = 5°C/s → bonus +500 → raw 6000
        //   clamp to fan.maxSpeed = 5800.
        let fan = makeControllerFan(id: 0, max: 5800)
        tickAt(c, clock: clock, fake: fake, advance: 0,
               fans: [fan], temps: [("TC0D", 70)])
        tickAt(c, clock: clock, fake: fake, advance: 2,
               fans: [fan], temps: [("TC0D", 80)])
        XCTAssertEqual(fake.speedCalls.last?.rpm, 5800,
                       "derivative bonus must be clamped to fan.maxSpeed")
        clearProfileStore()
    }

    // --- battery temp safety floor ---

    private func makeBattSensor(value: Double) -> Sensor {
        Sensor(key: "TB1T", name: "Battery 1", value: value,
               group: .sensor, type: .temperature, platforms: Platform.all)
    }

    private func makeBattSnapshot(fans: [Fan], cpu: Double, batt: Double) -> Sensors_List {
        let list = Sensors_List()
        list.sensors = [
            makeTempSensor(key: "TC0D", value: cpu),
            makeBattSensor(value: batt)
        ] + fans.map { $0 as Sensor_p }
        return list
    }

    func testBatterySafety_belowThreshold_noFloor() {
        clearProfileStore()
        let store = enabledStoreWithCustomProfile(smartLinearProfile)
        let fake = FakeFanCurveHelper()
        let clock = FakeFanControllerClock()
        let c = FanCurveController(helper: fake, store: store, clock: clock)
        let fan = makeControllerFan(id: 0)
        // CPU at 50 → curve = 3000. Battery at 35°C → no floor.
        c.tick(snapshot: makeBattSnapshot(fans: [fan], cpu: 50, batt: 35))
        XCTAssertEqual(fake.speedCalls.last?.rpm, 3000)
        clearProfileStore()
    }

    func testBatterySafety_aboveThresholdShortDuration_noFloor() {
        clearProfileStore()
        let store = enabledStoreWithCustomProfile(smartLinearProfile)
        let fake = FakeFanCurveHelper()
        let clock = FakeFanControllerClock()
        let c = FanCurveController(helper: fake, store: store, clock: clock)
        let fan = makeControllerFan(id: 0)
        // Battery hot for only 10s — well under 30s dwell threshold.
        c.tick(snapshot: makeBattSnapshot(fans: [fan], cpu: 50, batt: 41))
        clock.advance(by: 10)
        c.tick(snapshot: makeBattSnapshot(fans: [fan], cpu: 50, batt: 41))
        // Median(50, 50) = 50 → curve = 3000. No floor yet.
        XCTAssertEqual(fake.speedCalls.last?.rpm, 3000,
                       "battery hot < dwell delay → no floor applied")
        clearProfileStore()
    }

    func testBatterySafety_sustainedHot_appliesFloor() {
        clearProfileStore()
        let store = enabledStoreWithCustomProfile(smartLinearProfile)
        let fake = FakeFanCurveHelper()
        let clock = FakeFanControllerClock()
        let c = FanCurveController(helper: fake, store: store, clock: clock)
        let fan = makeControllerFan(id: 0)
        // First tick records batteryHotSince but doesn't apply floor.
        c.tick(snapshot: makeBattSnapshot(fans: [fan], cpu: 50, batt: 41))
        // Wait past 30s dwell, tick again — floor should now apply.
        clock.advance(by: 35)
        c.tick(snapshot: makeBattSnapshot(fans: [fan], cpu: 50, batt: 41))
        // Curve(50)=3000, battery floor=2500 → max(3000, 2500) = 3000.
        // Make sure floor doesn't lower a hotter curve target.
        XCTAssertEqual(fake.speedCalls.last?.rpm, 3000,
                       "floor must not lower a higher curve target")
        // Now drop CPU to a temp whose curve target is below the floor.
        // CPU at 35 → curve = 1000 + 5*100 = 500 clamped to fan.minSpeed=1000.
        clock.advance(by: 5)
        c.tick(snapshot: makeBattSnapshot(fans: [fan], cpu: 35, batt: 41))
        // Smoothed temp drifts, but battery still hot ≥30s → floor 2500 wins.
        XCTAssertGreaterThanOrEqual(fake.speedCalls.last?.rpm ?? 0, 2500,
                       "sustained battery heat must lift target to ≥2500 RPM")
        clearProfileStore()
    }

    func testBatterySafety_dropsResetCounter() {
        clearProfileStore()
        let store = enabledStoreWithCustomProfile(smartLinearProfile)
        let fake = FakeFanCurveHelper()
        let clock = FakeFanControllerClock()
        let c = FanCurveController(helper: fake, store: store, clock: clock)
        let fan = makeControllerFan(id: 0)
        // Get into the "floor active" state.
        c.tick(snapshot: makeBattSnapshot(fans: [fan], cpu: 35, batt: 41))
        clock.advance(by: 35)
        c.tick(snapshot: makeBattSnapshot(fans: [fan], cpu: 35, batt: 41))
        XCTAssertGreaterThanOrEqual(fake.speedCalls.last?.rpm ?? 0, 2500,
                       "precondition: floor active after sustained heat")
        // Battery drops below threshold → counter clears.
        clock.advance(by: 5)
        c.tick(snapshot: makeBattSnapshot(fans: [fan], cpu: 35, batt: 30))
        // Battery rises again — must wait another 30s before floor re-applies.
        clock.advance(by: 5)
        c.tick(snapshot: makeBattSnapshot(fans: [fan], cpu: 35, batt: 41))
        clock.advance(by: 10)
        c.tick(snapshot: makeBattSnapshot(fans: [fan], cpu: 35, batt: 41))
        // 10s after re-entering hot state < 30s dwell → no floor.
        // CPU at 35 → curve = 1000 + 5*100 = 1500 (above fan.minSpeed=1000).
        XCTAssertLessThan(fake.speedCalls.last?.rpm ?? 9999, 2500,
                       "drop below threshold must restart the dwell timer")
        clearProfileStore()
    }

    // MARK: - Apple firmware override failsafe

    /// Drive the controller through the override sequence: tick 1 writes
    /// `.forced` for the fan; ticks 2..1+threshold report `.automatic` in
    /// `smcMode` so the streak hits the threshold; subsequent ticks must
    /// produce zero SMC writes for that fan id.
    func testController_appleOverrideDetected_skipsFurtherWrites() {
        clearProfileStore()
        let store = enabledStoreWithCustomProfile(smartLinearProfile)
        let fake = FakeFanCurveHelper()
        let c = FanCurveController(helper: fake, store: store)
        // Tick 1: SMC honors our forced write — smcMode reflects .forced (or
        // unknown; either way no mismatch).
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0, smcMode: .forced)],
            temps: [("TC0D", 60)]))
        XCTAssertEqual(fake.modeCalls.count, 1, "first tick must issue setFanMode(.forced)")
        XCTAssertGreaterThanOrEqual(fake.speedCalls.count, 1, "first tick must issue setFanSpeed")
        // Ticks 2, 3, 4: SMC reports back .automatic each time — firmware is
        // overriding us. After tick 4 the streak threshold (3) is hit and the
        // fan id is moved into appleOverridden.
        for _ in 0..<3 {
            c.tick(snapshot: makeControllerSnapshot(
                fans: [makeControllerFan(id: 0, smcMode: .automatic)],
                temps: [("TC0D", 60)]))
        }
        // Tick 5+: applyIfNeeded must short-circuit on appleOverridden — no
        // setFanMode AND no setFanSpeed calls for fan 0.
        let modesBefore = fake.modeCalls.count
        let speedsBefore = fake.speedCalls.count
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0, smcMode: .automatic)],
            temps: [("TC0D", 65)]))
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0, smcMode: .automatic)],
            temps: [("TC0D", 70)]))
        XCTAssertEqual(fake.modeCalls.count, modesBefore,
            "after override is detected, no further setFanMode for fan 0")
        XCTAssertEqual(fake.speedCalls.count, speedsBefore,
            "after override is detected, no further setFanSpeed for fan 0")
        clearProfileStore()
    }

    /// Once override is triggered, a user picker action (`.fanProfileChanged`)
    /// must wipe the quarantine so the controller resumes writing — including
    /// re-issuing the initial `setFanMode(.forced)`.
    func testController_appleOverride_clearedOnProfileChange() {
        clearProfileStore()
        let store = enabledStoreWithCustomProfile(smartLinearProfile)
        let fake = FakeFanCurveHelper()
        let c = FanCurveController(helper: fake, store: store)
        // Drive into the override-detected state.
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0, smcMode: .forced)],
            temps: [("TC0D", 60)]))
        for _ in 0..<3 {
            c.tick(snapshot: makeControllerSnapshot(
                fans: [makeControllerFan(id: 0, smcMode: .automatic)],
                temps: [("TC0D", 60)]))
        }
        // Confirm we're quarantined: a subsequent tick must produce no calls.
        let modesAfterDetect = fake.modeCalls.count
        let speedsAfterDetect = fake.speedCalls.count
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0, smcMode: .automatic)],
            temps: [("TC0D", 65)]))
        XCTAssertEqual(fake.modeCalls.count, modesAfterDetect, "precondition: quarantined")
        XCTAssertEqual(fake.speedCalls.count, speedsAfterDetect, "precondition: quarantined")
        // User picks a profile — observer (queue: .main) drains async.
        fake.reset()
        let exp = expectation(description: "observer drained")
        NotificationCenter.default.post(name: .fanProfileChanged, object: nil)
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        // Next tick (SMC now honors us again) must re-issue setFanMode(.forced)
        // because both managedFans AND appleOverridden were cleared.
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0, smcMode: .forced)],
            temps: [("TC0D", 60)]))
        XCTAssertTrue(fake.modeCalls.contains(.init(id: 0, mode: Kit.FanMode.forced.rawValue)),
            "fanProfileChanged must clear appleOverridden so controller resumes")
        XCTAssertGreaterThanOrEqual(fake.speedCalls.count, 1,
            "controller must resume writing speed after quarantine cleared")
        _ = c
        clearProfileStore()
    }

    /// A single mismatched tick (one .automatic read after a .forced write)
    /// must NOT trigger the failsafe — only sustained mismatches do.
    func testController_singleMismatch_doesNotTrigger() {
        clearProfileStore()
        let store = enabledStoreWithCustomProfile(smartLinearProfile)
        let fake = FakeFanCurveHelper()
        let c = FanCurveController(helper: fake, store: store)
        // Tick 1: forced write succeeds.
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0, smcMode: .forced)],
            temps: [("TC0D", 60)]))
        // Tick 2: spurious automatic read (streak → 1).
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0, smcMode: .automatic)],
            temps: [("TC0D", 65)]))
        // Tick 3: SMC honors us again (streak resets to 0).
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0, smcMode: .forced)],
            temps: [("TC0D", 70)]))
        // Tick 4: at a clearly different temp, controller must still be
        // writing — no false-positive quarantine.
        fake.reset()
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0, smcMode: .forced)],
            temps: [("TC0D", 75)]))
        XCTAssertGreaterThanOrEqual(fake.speedCalls.count, 1,
            "single mismatch must not quarantine the fan")
        clearProfileStore()
    }

    /// The quarantine is in-memory only — a fresh `FanCurveController`
    /// instance (simulating app restart) must write again under the same
    /// override-trigger conditions.
    func testController_overrideRestart_freshSession() {
        clearProfileStore()
        let store = enabledStoreWithCustomProfile(smartLinearProfile)
        let fake1 = FakeFanCurveHelper()
        let c1 = FanCurveController(helper: fake1, store: store)
        // Trigger override in session 1.
        c1.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0, smcMode: .forced)],
            temps: [("TC0D", 60)]))
        for _ in 0..<3 {
            c1.tick(snapshot: makeControllerSnapshot(
                fans: [makeControllerFan(id: 0, smcMode: .automatic)],
                temps: [("TC0D", 60)]))
        }
        let modesBefore1 = fake1.modeCalls.count
        let speedsBefore1 = fake1.speedCalls.count
        c1.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0, smcMode: .automatic)],
            temps: [("TC0D", 70)]))
        XCTAssertEqual(fake1.modeCalls.count, modesBefore1, "session 1 must quarantine")
        XCTAssertEqual(fake1.speedCalls.count, speedsBefore1, "session 1 must quarantine")
        // Fresh controller instance (simulating restart) — no in-memory state.
        let fake2 = FakeFanCurveHelper()
        let c2 = FanCurveController(helper: fake2, store: store)
        c2.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0, smcMode: .automatic)],
            temps: [("TC0D", 60)]))
        XCTAssertTrue(fake2.modeCalls.contains(.init(id: 0, mode: Kit.FanMode.forced.rawValue)),
            "fresh controller must not inherit quarantine from previous instance")
        XCTAssertGreaterThanOrEqual(fake2.speedCalls.count, 1,
            "fresh controller must write speed under same conditions")
        _ = c1
        clearProfileStore()
    }

    // MARK: - Immediate profile-change application

    /// Picker → non-Apple profile must hit SMC synchronously inside the
    /// notification observer (no waiting up to ~1s for the next reader tick).
    /// Setup starts on Apple Auto so the first tick produces no SMC writes;
    /// after resetting the fake we swap to a non-Apple profile and post the
    /// notification — `.forced` mode + a speed write must appear without
    /// calling `tick()` again.
    func testController_profileChange_appliesImmediately_withoutWaitingForTick() {
        clearProfileStore()
        let store = ProfileStore()
        let apple = FanProfile(id: FanProfile.appleAutoID, name: "Apple Auto",
            drivers: [DriverSensor(key: "TC0D")], points: [],
            fanOffsetRPM: 0, hysteresisC: 0, deltaRpmThreshold: 1)
        let custom = FanProfile(name: "Custom",
            drivers: [DriverSensor(key: "TC0D")],
            points: [CurvePoint(tempC: 30, rpm: 1000), CurvePoint(tempC: 80, rpm: 6000)],
            fanOffsetRPM: 0, hysteresisC: 0, deltaRpmThreshold: 1)
        store.saveProfiles([apple, custom])
        store.activeProfileID = apple.id
        let fake = FakeFanCurveHelper()
        let c = FanCurveController(helper: fake, store: store)
        // First tick caches lastSnapshot. Apple Auto has empty points →
        // controller relinquishes (managedFans was empty, so no SMC writes).
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 60)]))
        fake.reset()
        // User picks the custom profile in the popup. Active profile is the
        // non-empty one; observer must re-tick synchronously.
        store.activeProfileID = custom.id
        NotificationCenter.default.post(name: .fanProfileChanged, object: nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        // SMC writes must be visible BEFORE the next explicit tick() call.
        XCTAssertTrue(fake.modeCalls.contains(.init(id: 0, mode: FanMode.forced.rawValue)),
            "profile change to non-Apple must immediately re-assert .forced on SMC")
        XCTAssertFalse(fake.speedCalls.isEmpty,
            "profile change to non-Apple must immediately write the new curve's RPM (got: \(fake.speedCalls))")
        XCTAssertEqual(fake.speedCalls.first?.id, 0)
        XCTAssertEqual(fake.speedCalls.first?.rpm, 4000,
            "first immediate write at temp=60 on linear curve (30,1000)-(80,6000) must be 4000")
        _ = c
        clearProfileStore()
    }

    /// Picker → Apple Auto must relinquish the previously-managed fan
    /// synchronously — `.automatic` write to SMC inside the observer, no
    /// reliance on the next tick. Regression guard for the latent bug where
    /// `managedFans.removeAll()` ran BEFORE `relinquishLocked`, leaving fans
    /// stuck in `.forced` mode forever.
    func testController_switchToAppleAuto_immediatelyRelinquishes() {
        clearProfileStore()
        let store = ProfileStore()
        let apple = FanProfile(id: FanProfile.appleAutoID, name: "Apple Auto",
            drivers: [DriverSensor(key: "TC0D")], points: [],
            fanOffsetRPM: 0, hysteresisC: 0, deltaRpmThreshold: 1)
        let custom = FanProfile(name: "Custom",
            drivers: [DriverSensor(key: "TC0D")],
            points: [CurvePoint(tempC: 30, rpm: 1000), CurvePoint(tempC: 80, rpm: 6000)],
            fanOffsetRPM: 0, hysteresisC: 0, deltaRpmThreshold: 1)
        store.saveProfiles([apple, custom])
        store.activeProfileID = custom.id
        let fake = FakeFanCurveHelper()
        let c = FanCurveController(helper: fake, store: store)
        // First tick takes management of fan 0 (writes .forced + speed).
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 60)]))
        XCTAssertTrue(fake.modeCalls.contains(.init(id: 0, mode: FanMode.forced.rawValue)),
            "precondition: controller took management of fan 0")
        fake.reset()
        // User switches to Apple Auto. Observer must call relinquishLocked
        // synchronously and write .automatic to SMC for fan 0 — BEFORE any
        // subsequent tick(). The pre-existing bug cleared managedFans first,
        // so relinquishLocked iterated nothing.
        store.activeProfileID = apple.id
        NotificationCenter.default.post(name: .fanProfileChanged, object: nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertTrue(fake.modeCalls.contains(.init(id: 0, mode: FanMode.automatic.rawValue)),
            "switching to Apple Auto must immediately relinquish fan 0 to .automatic")
        _ = c
        clearProfileStore()
    }

    // MARK: - OverrideKind (Phase 4 XPC wire type)

    func testOverrideKind_rawValues() {
        // Pinned: these raw values cross the XPC boundary; changing them
        // breaks the daemon ABI.
        XCTAssertEqual(OverrideKind.curve.rawValue, 0)
        XCTAssertEqual(OverrideKind.manual.rawValue, 1)
        XCTAssertEqual(OverrideKind.off.rawValue, 2)
        XCTAssertEqual(OverrideKind.max.rawValue, 3)
    }

    func testOverrideKind_codableRoundtrip() throws {
        for kind in [OverrideKind.curve, .manual, .off, .max] {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(OverrideKind.self, from: data)
            XCTAssertEqual(decoded, kind)
        }
    }

    // MARK: - HelperStatus (Phase 4 XPC wire type)

    func testHelperStatus_codableRoundtrip() throws {
        let status = HelperStatus(
            protocolVersion: 2,
            activeProfileID: "AAAA-BBBB-CCCC-DDDD",
            engineEnabled: true,
            currentTemp: 42.5,
            fans: [
                HelperStatus.Fan(id: 0, minSpeed: 1000, maxSpeed: 7000,
                                 currentRPM: 2500, smcMode: FanMode.forced.rawValue,
                                 userTookOver: false, appleOverridden: false),
                HelperStatus.Fan(id: 1, minSpeed: 1200, maxSpeed: 6800,
                                 currentRPM: 1800, smcMode: FanMode.automatic.rawValue,
                                 userTookOver: true, appleOverridden: false)
            ]
        )
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(HelperStatus.self, from: data)
        XCTAssertEqual(decoded, status)
        XCTAssertEqual(decoded.fans.count, 2)
        XCTAssertEqual(decoded.fans[1].userTookOver, true)
    }

    func testHelperStatus_nullableFieldsRoundtrip() throws {
        // nil activeProfileID + nil currentTemp + empty fans + nil per-fan
        // smcMode must all survive a JSON round-trip — the daemon emits this
        // shape when no profile is active and SMC probes fail.
        let status = HelperStatus(
            protocolVersion: 2,
            activeProfileID: nil,
            engineEnabled: false,
            currentTemp: nil,
            fans: [
                HelperStatus.Fan(id: 0, minSpeed: 1000, maxSpeed: 7000,
                                 currentRPM: 0, smcMode: nil,
                                 userTookOver: false, appleOverridden: true)
            ]
        )
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(HelperStatus.self, from: data)
        XCTAssertEqual(decoded, status)
        XCTAssertNil(decoded.activeProfileID)
        XCTAssertNil(decoded.currentTemp)
        XCTAssertNil(decoded.fans[0].smcMode)
        XCTAssertTrue(decoded.fans[0].appleOverridden)
    }
}
