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

    func testEffectiveTemperature_emptyDrivers_returnsNil() {
        let r = FanCurve.effectiveTemperature(sensors: [], drivers: [])
        XCTAssertNil(r)
    }

    func testEffectiveTemperature_noMatchingSensors_returnsNil() {
        let sensors: [Sensor_p] = [makeTempSensor(key: "TC0D", value: 60)]
        let r = FanCurve.effectiveTemperature(sensors: sensors,
                drivers: [DriverSensor(key: "MISSING")])
        XCTAssertNil(r)
    }

    func testEffectiveTemperature_singleDriver_returnsItsValue() {
        let sensors: [Sensor_p] = [makeTempSensor(key: "TC0D", value: 65.5)]
        let r = FanCurve.effectiveTemperature(sensors: sensors,
                drivers: [DriverSensor(key: "TC0D")])
        XCTAssertEqual(r, 65.5)
    }

    func testEffectiveTemperature_multipleDrivers_returnsMax() {
        let sensors: [Sensor_p] = [
            makeTempSensor(key: "TC0D", value: 60),
            makeTempSensor(key: "TG0D", value: 75),
            makeTempSensor(key: "TCAD", value: 55),
        ]
        let r = FanCurve.effectiveTemperature(sensors: sensors,
                drivers: [DriverSensor(key: "TC0D"),
                          DriverSensor(key: "TG0D"),
                          DriverSensor(key: "TCAD")])
        XCTAssertEqual(r, 75)
    }

    func testEffectiveTemperature_skipsMissingDrivers() {
        let sensors: [Sensor_p] = [
            makeTempSensor(key: "TC0D", value: 60),
        ]
        let r = FanCurve.effectiveTemperature(sensors: sensors,
                drivers: [DriverSensor(key: "TC0D"),
                          DriverSensor(key: "MISSING")])
        XCTAssertEqual(r, 60)
    }

    // MARK: - FanProfile.builtIns

    func testBuiltIns_singleFan_hasFourProfiles() {
        let list = FanProfile.builtIns(fanCount: 1, defaultMaxRPM: 7000)
        XCTAssertEqual(list.count, 4)
        XCTAssertEqual(list.map(\.name), ["Apple Auto", "Quiet", "Balanced", "Aggressive"])
    }

    func testBuiltIns_twoFans_hasSameFourProfiles() {
        let list = FanProfile.builtIns(fanCount: 2, defaultMaxRPM: 7000)
        XCTAssertEqual(list.count, 4)
        XCTAssertEqual(list.map(\.name), ["Apple Auto", "Quiet", "Balanced", "Aggressive"])
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
        XCTAssertEqual(agg.points.count, 6)
        XCTAssertEqual(agg.points[0], CurvePoint(tempC: 35, rpm: 1300))
        XCTAssertEqual(agg.points[1], CurvePoint(tempC: 45, rpm: 2000))
        XCTAssertEqual(agg.points[2], CurvePoint(tempC: 55, rpm: 3000))
        XCTAssertEqual(agg.points[3], CurvePoint(tempC: 65, rpm: 4200))
        XCTAssertEqual(agg.points[4], CurvePoint(tempC: 72, rpm: 5400))
        XCTAssertEqual(agg.points[5], CurvePoint(tempC: 78, rpm: 7000))
    }

    func testBuiltIns_clampsRpmToMaxRPM() {
        let list = FanProfile.builtIns(fanCount: 1, defaultMaxRPM: 4000)
        for p in list {
            for pt in p.points {
                XCTAssertLessThanOrEqual(pt.rpm, 4000, "\(p.name) has point > maxRPM: \(pt)")
            }
        }
    }

    func testBuiltIns_driversAreCpuDiodeAndGpuDiode() {
        let list = FanProfile.builtIns(fanCount: 1, defaultMaxRPM: 7000)
        for p in list where p.name != "Apple Auto" {
            XCTAssertEqual(Set(p.drivers.map(\.key)), ["TC0D", "TG0D"], "\(p.name)")
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

    func testProfileStore_enabled_falseByDefault() {
        clearProfileStore()
        let store = ProfileStore()
        XCTAssertFalse(store.enabled)
        clearProfileStore()
    }

    func testProfileStore_enabled_roundtrip() {
        clearProfileStore()
        let store = ProfileStore()
        store.enabled = true
        XCTAssertTrue(store.enabled)
        store.enabled = false
        XCTAssertFalse(store.enabled)
        clearProfileStore()
    }

    func testProfileStore_activeProfile_resolvesByID() {
        clearProfileStore()
        let store = ProfileStore()
        let list = FanProfile.builtIns(fanCount: 1, defaultMaxRPM: 7000)
        store.saveProfiles(list)
        store.activeProfileID = list[2].id   // "Balanced"
        let active = store.activeProfile()
        XCTAssertEqual(active?.id, list[2].id)
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

    // MARK: - Bootstrap

    func testBootstrap_emptyStore_writesBuiltInsAndPicksAggressive() {
        clearProfileStore()
        let store = ProfileStore()
        store.bootstrapIfNeeded(fanCount: 1, defaultMaxRPM: 7000)
        let loaded = store.loadProfiles()
        XCTAssertEqual(loaded.count, 4)
        XCTAssertEqual(loaded.map(\.name), ["Apple Auto", "Quiet", "Balanced", "Aggressive"])
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
                                   value: Double = 1000) -> Fan {
        Fan(id: id, key: "F\(id)Ac", name: "Fan \(id)",
            minSpeed: min, maxSpeed: max, value: value, mode: .automatic)
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
        // Aggressive profile: at 65°C effective temp → 4200 RPM
        let snap = makeControllerSnapshot(fans: [makeControllerFan(id: 0)],
                                          temps: [("TC0D", 65), ("TG0D", 50)])
        c.tick(snapshot: snap)
        // First apply should set mode to .forced exactly once
        XCTAssertEqual(fake.modeCalls, [.init(id: 0, mode: FanMode.forced.rawValue)])
        // Speed = 4200 (effective temp = max(65, 50) = 65)
        XCTAssertEqual(fake.speedCalls.count, 1)
        XCTAssertEqual(fake.speedCalls[0].id, 0)
        XCTAssertEqual(fake.speedCalls[0].rpm, 4200)
        clearProfileStore()
    }

    func testController_secondTickSameTemp_doesNotResendMode() {
        clearProfileStore()
        let store = ProfileStore()
        store.enabled = true
        store.bootstrapIfNeeded(fanCount: 1, defaultMaxRPM: 7000)
        let fake = FakeFanCurveHelper()
        let c = FanCurveController(helper: fake, store: store)
        let snap = makeControllerSnapshot(fans: [makeControllerFan(id: 0)],
                                          temps: [("TC0D", 65)])
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
        let c = FanCurveController(helper: fake, store: store)
        // temp=55 → rpm=3500, temp=55.5 → rpm=3550 (delta=50 < threshold=200)
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 55)]))
        XCTAssertEqual(fake.speedCalls.count, 1)
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 55.5)]))
        XCTAssertEqual(fake.speedCalls.count, 1, "delta < threshold should suppress")
        clearProfileStore()
    }

    func testController_throttle_appliesPastThreshold() {
        clearProfileStore()
        let store = enabledStoreWithCustomProfile(linearProfile)
        let fake = FakeFanCurveHelper()
        let c = FanCurveController(helper: fake, store: store)
        // temp=55 → 3500, temp=60 → 4000 (delta=500 ≥ threshold)
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 55)]))
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
        let c = FanCurveController(helper: fake, store: store)
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 70)]))
        // tempDrop=6 > hyst=5 → allow
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

    func testController_storeDisabled_relinquishesIfPreviouslyManaged() {
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
        // Disable: tick alone bails early without relinquishing
        store.enabled = false
        fake.reset()
        c.tick(snapshot: makeControllerSnapshot(
            fans: [makeControllerFan(id: 0)], temps: [("TC0D", 60)]))
        XCTAssertEqual(fake.modeCalls.count, 0, "tick should bail when disabled")
        // Explicit shutdown releases the fans:
        c.shutdown()
        XCTAssertEqual(fake.modeCalls,
            [.init(id: 0, mode: FanMode.automatic.rawValue)])
        clearProfileStore()
    }

    func testController_fanControlEnabledChangedToOff_relinquishesImmediately() {
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
        // Disable, then post the notification — observer should relinquish without waiting for a tick.
        store.enabled = false
        let exp = expectation(description: "observer ran")
        NotificationCenter.default.post(name: .fanControlEnabledChanged, object: nil)
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(fake.modeCalls,
            [.init(id: 0, mode: FanMode.automatic.rawValue)],
            "toggling fan control off should release managed fans immediately")
        _ = c // keep alive
        clearProfileStore()
    }

    func testController_fanControlEnabledChangedToOn_doesNothing() {
        clearProfileStore()
        let active = FanProfile(name: "Linear",
            drivers: [DriverSensor(key: "TC0D")],
            points: [CurvePoint(tempC: 30, rpm: 1000), CurvePoint(tempC: 80, rpm: 6000)],
            fanOffsetRPM: 0)
        let store = enabledStoreWithCustomProfile(active)
        store.enabled = false
        let fake = FakeFanCurveHelper()
        let c = FanCurveController(helper: fake, store: store)
        // Flip on, post notification: observer should NOT apply anything (no snapshot yet).
        store.enabled = true
        let exp = expectation(description: "observer ran")
        NotificationCenter.default.post(name: .fanControlEnabledChanged, object: nil)
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(fake.modeCalls.count, 0)
        XCTAssertEqual(fake.speedCalls.count, 0)
        _ = c // keep alive
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
        XCTAssertEqual(store.loadProfiles().count, 4)
        XCTAssertEqual(store.activeProfile()?.name, "Aggressive")
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
}
