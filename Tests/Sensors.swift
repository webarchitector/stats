//
//  Sensors.swift
//  Tests
//
//  Created on 08/06/2026.
//

import XCTest
@testable import Sensors

final class SensorsTests: XCTestCase {
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
}
