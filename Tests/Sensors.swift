//
//  Sensors.swift
//  Tests
//
//  Created on 08/06/2026.
//

import XCTest
import Sensors

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
}
