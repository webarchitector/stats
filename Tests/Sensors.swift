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
}
