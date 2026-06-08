# Fan Curve Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add automatic temperature-driven fan curve control to the Sensors module of stats (personal fork). One global profile with a master curve, applied symmetrically to all fans with a fan-1 offset for 2-fan machines. Lock existing behavior with tests first; add new behavior strictly TDD.

**Architecture:** Extend `FanMode` with new `.curve` case (raw value 100, not a real SMC mode). Add value types (`CurvePoint`, `DriverSensor`, `FanProfile`) in `Modules/Sensors/values.swift`. Add new `FanCurveController` class that subscribes to existing `SensorsReader` callback (no new timer) and uses `SMCHelper` XPC to write RPM. Add new UI section in `Modules/Sensors/settings.swift`. No new module, no new XPC interface.

**Tech Stack:** Swift 5, Cocoa AppKit, XCTest, existing `SMCHelper` XPC helper, existing `SensorsReader`, existing `Store.shared` (UserDefaults wrapper).

**Recommended setup before starting:** Run `git worktree add ../stats-fan-curve fan-curve` and work there to keep `main` clean. Run `xcodebuild -scheme Stats -configuration Debug build` first to confirm baseline compiles. Verify Tests target builds: `xcodebuild -scheme Stats -destination 'platform=macOS' test -only-testing:Tests/RAM`.

**Spec:** `docs/superpowers/specs/2026-06-08-stats-fan-curve-design.md`.

---

## Phase 0 — Lock existing behavior with tests

We touch `FanMode` enum and `Fan` struct. Before changing them, pin current behavior so we notice if our additions break anything.

Existing test target lives in `Tests/` directory. Files use pattern `import <ModuleName>` to access public/internal types. Test class can shadow module name (existing `Tests/RAM.swift` has `class RAM: XCTestCase` while `import RAM`). For clarity, we use class name `SensorsTests` to avoid the shadow.

### Task 0.1: Add Sensors test file + lock FanMode.isAutomatic

**Files:**
- Create: `Tests/Sensors.swift`
- Reference: `SMC/smc.swift:46-54` (FanMode enum)

- [ ] **Step 1: Write the failing tests**

Create `Tests/Sensors.swift`:

```swift
//
//  Sensors.swift
//  Tests
//
//  Created on 08/06/2026.
//

import XCTest
@testable import SMC
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
}
```

- [ ] **Step 2: Add file to Tests target in Xcode project**

Open `Stats.xcodeproj`, drag `Tests/Sensors.swift` into the `Tests` group in the navigator (or use `xcodebuild`-friendly direct edit — but Xcode UI is most reliable for this).

- [ ] **Step 3: Run tests to verify they fail or pass cleanly**

```bash
xcodebuild -scheme Stats -destination 'platform=macOS,arch=arm64' \
    -only-testing:Tests/SensorsTests test 2>&1 | tail -20
```

Expected: all tests PASS (we're locking current behavior, so they should pass on first run; if any fail, that's a real existing bug to investigate first).

- [ ] **Step 4: Commit**

```bash
git add Tests/Sensors.swift Stats.xcodeproj/project.pbxproj
git commit -m "Add Sensors test file with FanMode invariants"
```

---

### Task 0.2: Lock Fan.percentage math

**Files:**
- Modify: `Tests/Sensors.swift`
- Reference: `Modules/Sensors/values.swift:257-262` (Fan.percentage)

- [ ] **Step 1: Write the failing tests**

Add to `Tests/Sensors.swift` inside `SensorsTests`:

```swift
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
```

- [ ] **Step 2: Run tests**

```bash
xcodebuild -scheme Stats -destination 'platform=macOS,arch=arm64' \
    -only-testing:Tests/SensorsTests test 2>&1 | tail -20
```

Expected: all PASS (locking behavior).

- [ ] **Step 3: Commit**

```bash
git add Tests/Sensors.swift
git commit -m "Lock Fan.percentage behavior with tests"
```

---

### Task 0.3: Lock Fan.customMode / customSpeed Store roundtrip

**Files:**
- Modify: `Tests/Sensors.swift`
- Reference: `Modules/Sensors/values.swift:296-326` (Fan.customSpeed, customMode)

- [ ] **Step 1: Write the failing tests**

Add to `SensorsTests`:

```swift
    // MARK: - Fan.customMode / customSpeed persistence
    
    private func clearStore(fanID: Int) {
        UserDefaults.standard.removeObject(forKey: "fan_\(fanID)_speed")
        UserDefaults.standard.removeObject(forKey: "fan_\(fanID)_mode")
    }
    
    func testFan_customSpeed_nilByDefault() {
        clearStore(fanID: 99)
        var fan = makeFan(value: 0)
        fan = Fan(id: 99, key: "F0Ac", name: "x",
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
```

Note: tests use `id: 99`/`98` to avoid colliding with any real fan IDs that might have stored state from a running stats instance. `Store.shared` writes to the same `UserDefaults` so the suffix IDs must be unused.

- [ ] **Step 2: Run tests**

```bash
xcodebuild -scheme Stats -destination 'platform=macOS,arch=arm64' \
    -only-testing:Tests/SensorsTests test 2>&1 | tail -20
```

Expected: all PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/Sensors.swift
git commit -m "Lock Fan.customSpeed and customMode Store roundtrip"
```

---

## Phase 1 — Add value types (FanMode.curve, CurvePoint, DriverSensor, FanProfile)

### Task 1.1: Add FanMode.curve case

**Files:**
- Modify: `SMC/smc.swift:46-54`
- Modify: `Tests/Sensors.swift`

- [ ] **Step 1: Write the failing tests**

Add to `SensorsTests`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild -scheme Stats -destination 'platform=macOS,arch=arm64' \
    -only-testing:Tests/SensorsTests test 2>&1 | tail -20
```

Expected: FAIL — `'curve' is not a member of 'FanMode'` and `Value of type 'FanMode' has no member 'isStatsControlled'`.

- [ ] **Step 3: Implement**

Edit `SMC/smc.swift:46-54`:

```swift
public enum FanMode: Int, Codable {
    case automatic = 0
    case forced = 1
    case auto3 = 3
    case curve = 100

    public var isAutomatic: Bool {
        self == .automatic || self == .auto3
    }
    
    public var isStatsControlled: Bool {
        self == .curve
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild -scheme Stats -destination 'platform=macOS,arch=arm64' \
    -only-testing:Tests/SensorsTests test 2>&1 | tail -20
```

Expected: PASS, all previous tests still pass.

- [ ] **Step 5: Commit**

```bash
git add SMC/smc.swift Tests/Sensors.swift
git commit -m "Add FanMode.curve case for Stats-level fan control"
```

---

### Task 1.2: Add CurvePoint and DriverSensor

**Files:**
- Modify: `Modules/Sensors/values.swift` (append after existing types, ~line 327)
- Modify: `Tests/Sensors.swift`

- [ ] **Step 1: Write the failing tests**

Add to `SensorsTests`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild -scheme Stats -destination 'platform=macOS,arch=arm64' \
    -only-testing:Tests/SensorsTests test 2>&1 | tail -10
```

Expected: FAIL — types not defined.

- [ ] **Step 3: Implement**

Append to `Modules/Sensors/values.swift` after the `Fan` struct (line ~327):

```swift
// MARK: - Fan Curve

public struct CurvePoint: Codable, Equatable, Hashable {
    public var tempC: Double
    public var rpm: Int
    
    public init(tempC: Double, rpm: Int) {
        self.tempC = tempC
        self.rpm = rpm
    }
}

public struct DriverSensor: Codable, Equatable, Hashable {
    public var key: String
    public var weight: Double
    
    public init(key: String, weight: Double = 1.0) {
        self.key = key
        self.weight = weight
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild -scheme Stats -destination 'platform=macOS,arch=arm64' \
    -only-testing:Tests/SensorsTests test 2>&1 | tail -10
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Modules/Sensors/values.swift Tests/Sensors.swift
git commit -m "Add CurvePoint and DriverSensor value types"
```

---

### Task 1.3: Add FanProfile struct

**Files:**
- Modify: `Modules/Sensors/values.swift`
- Modify: `Tests/Sensors.swift`

- [ ] **Step 1: Write the failing tests**

Add to `SensorsTests`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild -scheme Stats -destination 'platform=macOS,arch=arm64' \
    -only-testing:Tests/SensorsTests test 2>&1 | tail -10
```

Expected: FAIL — `FanProfile` not defined.

- [ ] **Step 3: Implement**

Append to `Modules/Sensors/values.swift` after `DriverSensor`:

```swift
public struct FanProfile: Codable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var isBuiltIn: Bool
    public var drivers: [DriverSensor]
    public var points: [CurvePoint]
    public var fanOffsetRPM: Int
    public var hysteresisC: Double
    public var deltaRpmThreshold: Int
    
    public init(id: UUID = UUID(),
                name: String,
                isBuiltIn: Bool = false,
                drivers: [DriverSensor],
                points: [CurvePoint],
                fanOffsetRPM: Int = 50,
                hysteresisC: Double = 2.0,
                deltaRpmThreshold: Int = 150) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.drivers = drivers
        self.points = points
        self.fanOffsetRPM = fanOffsetRPM
        self.hysteresisC = hysteresisC
        self.deltaRpmThreshold = deltaRpmThreshold
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild -scheme Stats -destination 'platform=macOS,arch=arm64' \
    -only-testing:Tests/SensorsTests test 2>&1 | tail -10
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Modules/Sensors/values.swift Tests/Sensors.swift
git commit -m "Add FanProfile value type"
```

---

## Phase 2 — Pure functions (interpolate, effectiveTemperature, built-ins)

### Task 2.1: interpolate(points:tempC:) pure function

**Files:**
- Create: `Modules/Sensors/fanCurve.swift`
- Modify: `Tests/Sensors.swift`

- [ ] **Step 1: Write the failing tests**

Add to `SensorsTests`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild -scheme Stats -destination 'platform=macOS,arch=arm64' \
    -only-testing:Tests/SensorsTests test 2>&1 | tail -10
```

Expected: FAIL — `FanCurve` not defined.

- [ ] **Step 3: Implement**

Create `Modules/Sensors/fanCurve.swift`:

```swift
//
//  fanCurve.swift
//  Sensors
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
```

Add `Modules/Sensors/fanCurve.swift` to the Sensors target in Xcode project.

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild -scheme Stats -destination 'platform=macOS,arch=arm64' \
    -only-testing:Tests/SensorsTests test 2>&1 | tail -10
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Modules/Sensors/fanCurve.swift Tests/Sensors.swift Stats.xcodeproj/project.pbxproj
git commit -m "Add FanCurve.interpolate piecewise-linear function"
```

---

### Task 2.2: effectiveTemperature(snapshot:drivers:)

**Files:**
- Modify: `Modules/Sensors/fanCurve.swift`
- Modify: `Tests/Sensors.swift`

- [ ] **Step 1: Write the failing tests**

Add to `SensorsTests`:

```swift
    // MARK: - effectiveTemperature
    
    private func makeTempSensor(key: String, value: Double) -> Sensor {
        Sensor(key: key, name: key, group: .CPU, type: .temperature,
               platforms: Platform.all, value: value)
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
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — `effectiveTemperature` not defined.

- [ ] **Step 3: Implement**

Append to `Modules/Sensors/fanCurve.swift`:

```swift
extension FanCurve {
    /// Returns the maximum localValue among sensors whose key matches any driver.
    /// Returns nil if no driver matches any sensor.
    public static func effectiveTemperature(sensors: [Sensor_p],
                                            drivers: [DriverSensor]) -> Double? {
        let keys = Set(drivers.map(\.key))
        let values = sensors
            .filter { keys.contains($0.key) }
            .map(\.localValue)
        return values.max()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild -scheme Stats -destination 'platform=macOS,arch=arm64' \
    -only-testing:Tests/SensorsTests test 2>&1 | tail -10
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Modules/Sensors/fanCurve.swift Tests/Sensors.swift
git commit -m "Add FanCurve.effectiveTemperature returning max of driver sensors"
```

---

### Task 2.3: FanProfile.builtIns(fanCount:maxSpeeds:)

**Files:**
- Modify: `Modules/Sensors/values.swift` (or co-locate in fanCurve.swift)
- Modify: `Tests/Sensors.swift`

- [ ] **Step 1: Write the failing tests**

Add to `SensorsTests`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — `FanProfile.builtIns` not defined.

- [ ] **Step 3: Implement**

Append to `Modules/Sensors/fanCurve.swift`:

```swift
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
        let drivers = [DriverSensor(key: "TC0D"), DriverSensor(key: "TG0D")]
        
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
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Modules/Sensors/fanCurve.swift Tests/Sensors.swift
git commit -m "Add FanProfile.builtIns generator for Quiet/Balanced/Aggressive/Auto"
```

---

## Phase 3 — ProfileStore (persistence + first-run bootstrap)

### Task 3.1: ProfileStore profiles get/set

**Files:**
- Create: `Modules/Sensors/profileStore.swift`
- Modify: `Tests/Sensors.swift`

- [ ] **Step 1: Write the failing tests**

Add to `SensorsTests`:

```swift
    // MARK: - ProfileStore
    
    private func clearProfileStore() {
        UserDefaults.standard.removeObject(forKey: "fanctl_profiles")
        UserDefaults.standard.removeObject(forKey: "fanctl_activeProfile")
        UserDefaults.standard.removeObject(forKey: "fanctl_enabled")
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
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — `ProfileStore` not defined.

- [ ] **Step 3: Implement**

Create `Modules/Sensors/profileStore.swift`:

```swift
//
//  profileStore.swift
//  Sensors
//

import Foundation
import Kit

/// Persistence layer for fan curve profiles. Backs onto UserDefaults via `Store.shared`.
public final class ProfileStore {
    public static let shared = ProfileStore()
    
    private let profilesKey = "fanctl_profiles"
    private let activeKey   = "fanctl_activeProfile"
    private let enabledKey  = "fanctl_enabled"
    
    public init() {}
    
    public func loadProfiles() -> [FanProfile] {
        guard let data = Store.shared.data(key: profilesKey) else { return [] }
        return (try? JSONDecoder().decode([FanProfile].self, from: data)) ?? []
    }
    
    public func saveProfiles(_ profiles: [FanProfile]) {
        if let data = try? JSONEncoder().encode(profiles) {
            Store.shared.set(key: profilesKey, value: data)
        }
    }
    
    public var activeProfileID: UUID? {
        get {
            let raw = Store.shared.string(key: activeKey, defaultValue: "")
            return raw.isEmpty ? nil : UUID(uuidString: raw)
        }
        set {
            Store.shared.set(key: activeKey, value: newValue?.uuidString ?? "")
        }
    }
    
    public var enabled: Bool {
        get { Store.shared.bool(key: enabledKey, defaultValue: false) }
        set { Store.shared.set(key: enabledKey, value: newValue) }
    }
    
    public func activeProfile() -> FanProfile? {
        guard let id = activeProfileID else { return nil }
        return loadProfiles().first { $0.id == id }
    }
}
```

Note: `Store.shared.data(key:)` must exist as part of the existing `Store` API in `Kit`. If `Store` only has `string`/`int`/`bool`/`double`, we need to either add a `data` getter/setter, or store as base64-encoded string. Check `Kit/store.swift` (or wherever Store is defined) before implementing. If absent — store the JSON as `String` instead:

Alternative implementation (if `Store.shared.data` is not available):

```swift
public func loadProfiles() -> [FanProfile] {
    let s = Store.shared.string(key: profilesKey, defaultValue: "")
    guard !s.isEmpty, let data = s.data(using: .utf8) else { return [] }
    return (try? JSONDecoder().decode([FanProfile].self, from: data)) ?? []
}

public func saveProfiles(_ profiles: [FanProfile]) {
    if let data = try? JSONEncoder().encode(profiles),
       let s = String(data: data, encoding: .utf8) {
        Store.shared.set(key: profilesKey, value: s)
    }
}
```

Add the file to Sensors target in Xcode.

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild -scheme Stats -destination 'platform=macOS,arch=arm64' \
    -only-testing:Tests/SensorsTests test 2>&1 | tail -10
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Modules/Sensors/profileStore.swift Tests/Sensors.swift Stats.xcodeproj/project.pbxproj
git commit -m "Add ProfileStore for fan-curve profile persistence"
```

---

### Task 3.2: First-run bootstrap

**Files:**
- Modify: `Modules/Sensors/profileStore.swift`
- Modify: `Tests/Sensors.swift`

- [ ] **Step 1: Write the failing tests**

Add to `SensorsTests`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — `bootstrapIfNeeded` not defined.

- [ ] **Step 3: Implement**

Append to `Modules/Sensors/profileStore.swift`:

```swift
extension ProfileStore {
    /// On first launch (no profiles persisted), seed built-ins and activate Aggressive.
    /// No-op if profiles already exist.
    public func bootstrapIfNeeded(fanCount: Int, defaultMaxRPM: Int) {
        let existing = loadProfiles()
        guard existing.isEmpty else { return }
        let builtIns = FanProfile.builtIns(fanCount: fanCount,
                                           defaultMaxRPM: defaultMaxRPM)
        saveProfiles(builtIns)
        if let aggressive = builtIns.first(where: { $0.name == "Aggressive" }) {
            activeProfileID = aggressive.id
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Modules/Sensors/profileStore.swift Tests/Sensors.swift
git commit -m "Add ProfileStore.bootstrapIfNeeded for first-run defaults"
```

---

## Phase 4 — FanCurveController (no UI yet, fully tested with a fake helper)

### Task 4.1: Define FanCurveHelper protocol and FakeFanCurveHelper test spy

**Files:**
- Create: `Modules/Sensors/fanController.swift`
- Modify: `Tests/Sensors.swift`

- [ ] **Step 1: Write the failing tests**

Add to `SensorsTests`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — types not defined.

- [ ] **Step 3: Implement**

Create `Modules/Sensors/fanController.swift`:

```swift
//
//  fanController.swift
//  Sensors
//

import Foundation
import AppKit
import Kit

/// Narrow protocol for what FanCurveController needs from SMCHelper.
/// Lets tests inject a fake.
public protocol FanCurveHelper: AnyObject {
    func isActive() -> Bool
    func setFanMode(id: Int, mode: Int)
    func setFanSpeed(id: Int, value: Int)
}

#if DEBUG
public final class FakeFanCurveHelper: FanCurveHelper {
    public struct ModeCall: Equatable { public let id: Int; public let mode: Int }
    public struct SpeedCall: Equatable { public let id: Int; public let rpm: Int }
    
    public var isActiveValue: Bool = true
    public private(set) var modeCalls: [ModeCall] = []
    public private(set) var speedCalls: [SpeedCall] = []
    
    public init() {}
    public func isActive() -> Bool { isActiveValue }
    public func setFanMode(id: Int, mode: Int) { modeCalls.append(.init(id: id, mode: mode)) }
    public func setFanSpeed(id: Int, value: Int) { speedCalls.append(.init(id: id, rpm: value)) }
    public func reset() { modeCalls.removeAll(); speedCalls.removeAll() }
}
#endif
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Modules/Sensors/fanController.swift Tests/Sensors.swift Stats.xcodeproj/project.pbxproj
git commit -m "Add FanCurveHelper protocol and FakeFanCurveHelper test spy"
```

---

### Task 4.2: FanCurveController.tick — basic apply

**Files:**
- Modify: `Modules/Sensors/fanController.swift`
- Modify: `Tests/Sensors.swift`

- [ ] **Step 1: Write the failing tests**

Add to `SensorsTests`:

```swift
    // MARK: - Controller tick basics
    
    private func makeFan(id: Int, min: Double = 1000, max: Double = 7000,
                         value: Double = 1000) -> Fan {
        Fan(id: id, key: "F\(id)Ac", name: "Fan \(id)",
            minSpeed: min, maxSpeed: max, value: value, mode: .automatic)
    }
    
    private func makeSnapshot(fans: [Fan], temps: [(String, Double)]) -> Sensors_List {
        var list = Sensors_List()
        list.sensors = temps.map { makeTempSensor(key: $0.0, value: $0.1) } + fans.map { $0 as Sensor_p }
        return list
    }
    
    func testController_disabledStore_doesNothing() {
        clearProfileStore()
        let fake = FakeFanCurveHelper()
        let c = FanCurveController(helper: fake, store: ProfileStore())
        let snap = makeSnapshot(fans: [makeFan(id: 0)], temps: [("TC0D", 70)])
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
        let snap = makeSnapshot(fans: [makeFan(id: 0)], temps: [("TC0D", 70)])
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
        // Aggressive profile: at 65°C → 4200 RPM
        let snap = makeSnapshot(fans: [makeFan(id: 0)], temps: [("TC0D", 65), ("TG0D", 50)])
        c.tick(snapshot: snap)
        // First apply should set mode to .forced exactly once
        XCTAssertEqual(fake.modeCalls, [.init(id: 0, mode: FanMode.forced.rawValue)])
        // Speed should be 4200 (effectiveTemp = max(65,50) = 65)
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
        let snap = makeSnapshot(fans: [makeFan(id: 0)], temps: [("TC0D", 65)])
        c.tick(snapshot: snap)
        fake.reset()  // clear, so we observe the second tick's calls
        c.tick(snapshot: snap)
        XCTAssertEqual(fake.modeCalls.count, 0, "mode should not be re-set on every tick")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — `FanCurveController` not defined.

- [ ] **Step 3: Implement**

Append to `Modules/Sensors/fanController.swift`:

```swift
public final class FanCurveController {
    private let helper: FanCurveHelper
    private let store: ProfileStore
    private var managedFans: Set<Int> = []
    private var lastApplied: [Int: Int] = [:]
    private var lastTempForHyst: [Int: Double] = [:]
    private var isAsleep: Bool = false
    private var observers: [NSObjectProtocol] = []
    
    public init(helper: FanCurveHelper, store: ProfileStore) {
        self.helper = helper
        self.store = store
    }
    
    public func tick(snapshot: Sensors_List?) {
        guard !isAsleep,
              store.enabled,
              helper.isActive(),
              let snapshot = snapshot else { return }
        
        guard let profile = store.activeProfile(),
              !profile.points.isEmpty else {
            relinquish()
            return
        }
        
        guard let effTemp = FanCurve.effectiveTemperature(
            sensors: snapshot.sensors, drivers: profile.drivers) else { return }
        
        let fans = snapshot.sensors.compactMap { $0 as? Fan }
        for fan in fans {
            let base = FanCurve.interpolate(points: profile.points, tempC: effTemp)
            let off = (fan.id == 0) ? 0 : profile.fanOffsetRPM
            let target = clamp(base + off, Int(fan.minSpeed), Int(fan.maxSpeed))
            applyIfNeeded(fan: fan, target: target, temp: effTemp,
                          hysteresisC: profile.hysteresisC,
                          deltaThreshold: profile.deltaRpmThreshold)
        }
    }
    
    private func applyIfNeeded(fan: Fan, target: Int, temp: Double,
                               hysteresisC: Double, deltaThreshold: Int) {
        if !managedFans.contains(fan.id) {
            helper.setFanMode(id: fan.id, mode: FanMode.forced.rawValue)
            managedFans.insert(fan.id)
        }
        // basic version: apply on every tick (hysteresis/throttle added in next task)
        helper.setFanSpeed(id: fan.id, value: target)
        lastApplied[fan.id] = target
        lastTempForHyst[fan.id] = temp
    }
    
    private func relinquish() {
        for id in managedFans {
            helper.setFanMode(id: id, mode: FanMode.automatic.rawValue)
        }
        managedFans.removeAll()
        lastApplied.removeAll()
        lastTempForHyst.removeAll()
    }
    
    private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        max(lo, min(hi, v))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS.

Note: the basic-apply version intentionally writes RPM on every tick. Hysteresis and delta-throttle land in the next task. Re-running the "second tick same temp" test should still pass because we assert `modeCalls.count == 0`, not speedCalls.

- [ ] **Step 5: Commit**

```bash
git add Modules/Sensors/fanController.swift Tests/Sensors.swift
git commit -m "Add FanCurveController.tick basic apply path"
```

---

### Task 4.3: Hysteresis + delta-throttle in applyIfNeeded

**Files:**
- Modify: `Modules/Sensors/fanController.swift`
- Modify: `Tests/Sensors.swift`

- [ ] **Step 1: Write the failing tests**

Add to `SensorsTests`:

```swift
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
        // temp=55 → rpm=3500, then temp=55.5 → rpm=3550 (delta=50 < threshold=200)
        let s1 = makeSnapshot(fans: [makeFan(id: 0)], temps: [("TC0D", 55)])
        c.tick(snapshot: s1)
        XCTAssertEqual(fake.speedCalls.count, 1)
        let s2 = makeSnapshot(fans: [makeFan(id: 0)], temps: [("TC0D", 55.5)])
        c.tick(snapshot: s2)
        XCTAssertEqual(fake.speedCalls.count, 1, "delta < threshold should suppress")
        clearProfileStore()
    }
    
    func testController_throttle_appliesPastThreshold() {
        clearProfileStore()
        let store = enabledStoreWithCustomProfile(linearProfile)
        let fake = FakeFanCurveHelper()
        let c = FanCurveController(helper: fake, store: store)
        // temp=55 → 3500, temp=60 → 4000 (delta=500 ≥ threshold)
        c.tick(snapshot: makeSnapshot(fans: [makeFan(id: 0)], temps: [("TC0D", 55)]))
        c.tick(snapshot: makeSnapshot(fans: [makeFan(id: 0)], temps: [("TC0D", 60)]))
        XCTAssertEqual(fake.speedCalls.map(\.rpm), [3500, 4000])
        clearProfileStore()
    }
    
    func testController_hysteresis_blocksLoweringInsideBand() {
        clearProfileStore()
        let store = enabledStoreWithCustomProfile(linearProfile)
        let fake = FakeFanCurveHelper()
        let c = FanCurveController(helper: fake, store: store)
        // Apply at temp=70 → rpm=5000
        c.tick(snapshot: makeSnapshot(fans: [makeFan(id: 0)], temps: [("TC0D", 70)]))
        // Drop temp to 69 (only -1°C, inside hysteresisC=2.0). Target would be 4900,
        // which is also < threshold 200 — but the test verifies hysteresis specifically,
        // so drop temp more aggressively to make the target cross delta but stay inside hyst:
        // temp=66.5 → target=4650, delta=350 (>threshold), but tempDrop=3.5 (>hyst) — wrong direction.
        // Use deltaThreshold-tolerant scenario: drop temp such that delta crosses threshold
        // but tempDrop < hyst. With slope (6000-1000)/(80-30) = 100 rpm per °C:
        // To get delta of 200 we need tempDrop of 2°C — exactly = hyst, not "inside".
        // So set hysteresis higher in this scenario:
        let p = FanProfile(name: "Hyst",
            drivers: [DriverSensor(key: "TC0D")],
            points: [CurvePoint(tempC: 30, rpm: 1000), CurvePoint(tempC: 80, rpm: 6000)],
            fanOffsetRPM: 0, hysteresisC: 5.0, deltaRpmThreshold: 100)
        clearProfileStore()
        let store2 = enabledStoreWithCustomProfile(p)
        let fake2 = FakeFanCurveHelper()
        let c2 = FanCurveController(helper: fake2, store: store2)
        c2.tick(snapshot: makeSnapshot(fans: [makeFan(id: 0)], temps: [("TC0D", 70)]))
        // Drop temp by 3°C: tempDrop=3 < hyst=5 → suppress even though delta=300 ≥ thresh=100
        c2.tick(snapshot: makeSnapshot(fans: [makeFan(id: 0)], temps: [("TC0D", 67)]))
        XCTAssertEqual(fake2.speedCalls.count, 1, "hysteresis should block lowering")
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
        c.tick(snapshot: makeSnapshot(fans: [makeFan(id: 0)], temps: [("TC0D", 70)]))
        // tempDrop=6 > hyst=5 → allow
        c.tick(snapshot: makeSnapshot(fans: [makeFan(id: 0)], temps: [("TC0D", 64)]))
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
        c.tick(snapshot: makeSnapshot(fans: [makeFan(id: 0)], temps: [("TC0D", 50)]))
        // small temp rise = +1°C inside hyst band; but raising is always allowed past threshold
        // delta = +100 which equals threshold (impl decides ≥ or >); use +2°C to be safe
        c.tick(snapshot: makeSnapshot(fans: [makeFan(id: 0)], temps: [("TC0D", 52)]))
        XCTAssertEqual(fake.speedCalls.count, 2)
        clearProfileStore()
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — current impl applies every tick.

- [ ] **Step 3: Implement**

Replace `applyIfNeeded` body in `Modules/Sensors/fanController.swift`:

```swift
private func applyIfNeeded(fan: Fan, target: Int, temp: Double,
                           hysteresisC: Double, deltaThreshold: Int) {
    if !managedFans.contains(fan.id) {
        helper.setFanMode(id: fan.id, mode: FanMode.forced.rawValue)
        managedFans.insert(fan.id)
    }
    let last = lastApplied[fan.id]
    let lastTemp = lastTempForHyst[fan.id] ?? -.greatestFiniteMagnitude
    
    if let last = last {
        let isLowering = target < last
        if isLowering && (lastTemp - temp) < hysteresisC {
            return
        }
        if abs(target - last) < deltaThreshold {
            return
        }
    }
    
    helper.setFanSpeed(id: fan.id, value: target)
    lastApplied[fan.id] = target
    lastTempForHyst[fan.id] = temp
}
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS — all hysteresis and throttle tests pass, plus the basic tick tests still pass.

- [ ] **Step 5: Commit**

```bash
git add Modules/Sensors/fanController.swift Tests/Sensors.swift
git commit -m "Add hysteresis and delta-RPM throttling to fan curve apply"
```

---

### Task 4.4: Per-fan offset

**Files:**
- Modify: `Tests/Sensors.swift` only (impl already in place from 4.2)

- [ ] **Step 1: Write the failing tests**

Add to `SensorsTests`:

```swift
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
        c.tick(snapshot: makeSnapshot(
            fans: [makeFan(id: 0), makeFan(id: 1)],
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
        let fan0 = makeFan(id: 0, max: 7000)
        let fan1 = makeFan(id: 1, max: 5800)
        c.tick(snapshot: makeSnapshot(fans: [fan0, fan1], temps: [("TC0D", 75)]))
        let fan1Rpm = fake.speedCalls.first { $0.id == 1 }?.rpm
        XCTAssertEqual(fan1Rpm, 5800)
        clearProfileStore()
    }
```

- [ ] **Step 2: Run tests to verify they pass**

```bash
xcodebuild -scheme Stats -destination 'platform=macOS,arch=arm64' \
    -only-testing:Tests/SensorsTests test 2>&1 | tail -10
```

Expected: PASS (impl already correct from 4.2).

If they fail — there's a bug in the offset clamp. Fix:

```swift
let off = (fan.id == 0) ? 0 : profile.fanOffsetRPM
let target = clamp(base + off, Int(fan.minSpeed), Int(fan.maxSpeed))
```

ensure both `base + off` and the floor/ceiling values are correct.

- [ ] **Step 3: Commit**

```bash
git add Tests/Sensors.swift
git commit -m "Test fan-1 offset and maxSpeed clamping"
```

---

### Task 4.5: Relinquish on profile-empty / profile-missing / disable

**Files:**
- Modify: `Tests/Sensors.swift` only (impl in 4.2)

- [ ] **Step 1: Write the failing tests**

```swift
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
        c.tick(snapshot: makeSnapshot(fans: [makeFan(id: 0)], temps: [("TC0D", 60)]))
        // Now swap to an empty-points profile (e.g. Apple Auto)
        let auto = FanProfile(name: "Auto",
            drivers: [DriverSensor(key: "TC0D")], points: [], fanOffsetRPM: 0)
        store.saveProfiles([active, auto])
        store.activeProfileID = auto.id
        fake.reset()
        c.tick(snapshot: makeSnapshot(fans: [makeFan(id: 0)], temps: [("TC0D", 60)]))
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
        c.tick(snapshot: makeSnapshot(fans: [makeFan(id: 0)], temps: [("TC0D", 60)]))
        XCTAssertTrue(fake.modeCalls.contains(.init(id: 0, mode: FanMode.forced.rawValue)))
        // Disable the controller
        store.enabled = false
        fake.reset()
        // First tick after disable: controller bails early without relinquishing
        // (relinquish requires going through the "no profile" / empty-points path).
        // To force relinquish on disable, we need an explicit method. Tested next.
        c.tick(snapshot: makeSnapshot(fans: [makeFan(id: 0)], temps: [("TC0D", 60)]))
        XCTAssertEqual(fake.modeCalls.count, 0, "tick should bail when disabled")
        // Explicit shutdown:
        c.shutdown()
        XCTAssertEqual(fake.modeCalls,
            [.init(id: 0, mode: FanMode.automatic.rawValue)])
        clearProfileStore()
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — `shutdown()` doesn't exist yet.

- [ ] **Step 3: Implement**

Add to `FanCurveController` in `Modules/Sensors/fanController.swift`:

```swift
public func shutdown() {
    relinquish()
}
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Modules/Sensors/fanController.swift Tests/Sensors.swift
git commit -m "Test fan curve relinquish on empty profile and shutdown"
```

---

### Task 4.6: Sleep/wake handling

**Files:**
- Modify: `Modules/Sensors/fanController.swift`
- Modify: `Tests/Sensors.swift`

- [ ] **Step 1: Write the failing tests**

```swift
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
        c.tick(snapshot: makeSnapshot(fans: [makeFan(id: 0)], temps: [("TC0D", 60)]))
        fake.reset()
        c.handleWillSleepForTests()
        // Sleep should relinquish managed fans:
        XCTAssertEqual(fake.modeCalls,
            [.init(id: 0, mode: FanMode.automatic.rawValue)])
        fake.reset()
        // Ticks during sleep should do nothing:
        c.tick(snapshot: makeSnapshot(fans: [makeFan(id: 0)], temps: [("TC0D", 75)]))
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
        c.tick(snapshot: makeSnapshot(fans: [makeFan(id: 0)], temps: [("TC0D", 60)]))
        c.handleWillSleepForTests()
        fake.reset()
        c.handleDidWakeForTests()
        c.tick(snapshot: makeSnapshot(fans: [makeFan(id: 0)], temps: [("TC0D", 60)]))
        // After wake, the controller should re-mode-force and re-apply:
        XCTAssertTrue(fake.modeCalls.contains(.init(id: 0, mode: FanMode.forced.rawValue)))
        XCTAssertEqual(fake.speedCalls.count, 1)
        clearProfileStore()
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — `handleWillSleepForTests` not defined.

- [ ] **Step 3: Implement**

Modify `FanCurveController` init and add private + test-only handlers:

```swift
public init(helper: FanCurveHelper, store: ProfileStore) {
    self.helper = helper
    self.store = store
    let nc = NSWorkspace.shared.notificationCenter
    observers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification,
        object: nil, queue: .main) { [weak self] _ in self?.handleWillSleep() })
    observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification,
        object: nil, queue: .main) { [weak self] _ in self?.handleDidWake() })
}

deinit {
    let nc = NSWorkspace.shared.notificationCenter
    for o in observers { nc.removeObserver(o) }
}

private func handleWillSleep() {
    isAsleep = true
    relinquish()
}

private func handleDidWake() {
    isAsleep = false
}

#if DEBUG
public func handleWillSleepForTests() { handleWillSleep() }
public func handleDidWakeForTests() { handleDidWake() }
#endif
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Modules/Sensors/fanController.swift Tests/Sensors.swift
git commit -m "Add sleep/wake handling to fan curve controller"
```

---

### Task 4.7: Profile-change notification resets last-applied state

**Files:**
- Create: `Kit/types.swift` — append two Notification.Name entries
- Modify: `Modules/Sensors/fanController.swift`
- Modify: `Tests/Sensors.swift`

- [ ] **Step 1: Write the failing tests**

```swift
    // MARK: - Controller profile-change reset
    
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
        c.tick(snapshot: makeSnapshot(fans: [makeFan(id: 0)], temps: [("TC0D", 70)]))
        // Without profile-change reset, a 1°C drop would be blocked by hysteresis.
        // Post the notification → state resets → next tick at the same temp re-applies
        // for the (changed) profile if it now produces a different RPM.
        let p2 = FanProfile(id: p1.id,  // same id, so activeProfile() still resolves
            name: "P2",
            drivers: [DriverSensor(key: "TC0D")],
            points: [CurvePoint(tempC: 30, rpm: 2000), CurvePoint(tempC: 80, rpm: 7000)],
            fanOffsetRPM: 0, hysteresisC: 5.0, deltaRpmThreshold: 100)
        store.saveProfiles([p2])
        fake.reset()
        NotificationCenter.default.post(name: .fanProfileChanged, object: nil)
        // Now tick at the SAME temp; new curve gives temp=70 → rpm = 6000.
        // Without reset, delta from old 5000 → 6000 would still pass (1000 > thresh),
        // so we need a tighter test: drop temp by 1°C, which would be blocked by hyst
        // without reset:
        c.tick(snapshot: makeSnapshot(fans: [makeFan(id: 0)], temps: [("TC0D", 69)]))
        XCTAssertEqual(fake.speedCalls.count, 1, "profile change should clear hysteresis state")
        clearProfileStore()
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — `.fanProfileChanged` not defined.

- [ ] **Step 3: Implement**

Append to `Kit/types.swift` next to existing `Notification.Name` extensions (search for `extension Notification.Name` in that file; if there's one already, add inside it):

```swift
extension Notification.Name {
    static let fanProfileChanged = Notification.Name("fanProfileChanged")
    static let fanControlEnabledChanged = Notification.Name("fanControlEnabledChanged")
}
```

If extension already exists, just add the two lines inside it.

Modify `FanCurveController` init to subscribe:

```swift
public init(helper: FanCurveHelper, store: ProfileStore) {
    self.helper = helper
    self.store = store
    let nc = NSWorkspace.shared.notificationCenter
    observers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification,
        object: nil, queue: .main) { [weak self] _ in self?.handleWillSleep() })
    observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification,
        object: nil, queue: .main) { [weak self] _ in self?.handleDidWake() })
    observers.append(NotificationCenter.default.addObserver(
        forName: .fanProfileChanged, object: nil, queue: .main) { [weak self] _ in
        self?.lastApplied.removeAll()
        self?.lastTempForHyst.removeAll()
    })
}

deinit {
    NSWorkspace.shared.notificationCenter.removeObserver(observers[0])
    NSWorkspace.shared.notificationCenter.removeObserver(observers[1])
    NotificationCenter.default.removeObserver(observers[2])
}
```

Note: `NSWorkspace.shared.notificationCenter` and `NotificationCenter.default` are different centers — be careful to remove from the right one. To keep deinit simple, store each observer tagged with its center. Replace `observers: [NSObjectProtocol]` with:

```swift
private var observers: [(NotificationCenter, NSObjectProtocol)] = []

deinit {
    for (center, token) in observers { center.removeObserver(token) }
}
```

Update inits accordingly to append tuples.

- [ ] **Step 4: Run tests to verify they pass**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Kit/types.swift Modules/Sensors/fanController.swift Tests/Sensors.swift
git commit -m "Reset fan curve hysteresis state on profile-change notification"
```

---

## Phase 5 — Wire FanCurveController into the Sensors module

### Task 5.1: Adapter making real SMCHelper conform to FanCurveHelper

**Files:**
- Modify: `Modules/Sensors/fanController.swift`
- Modify: `Tests/Sensors.swift` (smoke test only — real helper isn't reachable from tests)

- [ ] **Step 1: Add the adapter**

Append to `Modules/Sensors/fanController.swift`:

```swift
/// Bridges the existing `Kit.SMCHelper` to the narrow `FanCurveHelper` protocol.
public final class SMCHelperAdapter: FanCurveHelper {
    public static let shared = SMCHelperAdapter()
    public init() {}
    public func isActive() -> Bool { SMCHelper.shared.isActive() }
    public func setFanMode(id: Int, mode: Int) {
        SMCHelper.shared.setFanMode(id, mode: mode)
    }
    public func setFanSpeed(id: Int, value: Int) {
        SMCHelper.shared.setFanSpeed(id, value: value)
    }
}
```

`SMCHelper.shared.setFanSpeed` may not exist with that signature — check `Kit/helpers.swift:1052` and the surrounding methods. Likely signatures:
- `func setFanMode(_ id: Int, mode: Int)`
- `func setFanSpeed(_ id: Int, value: Int)` (or `mode: Int` overload)

Adjust adapter to match. If a real `setFanSpeed` method doesn't exist on `SMCHelper` yet, find where `Modules/Sensors/popup.swift:824` does the speed write (search `setFanSpeed` in popup.swift) and add a thin method on `SMCHelper.shared` if needed.

- [ ] **Step 2: Build to ensure adapter compiles**

```bash
xcodebuild -scheme Stats -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Modules/Sensors/fanController.swift
git commit -m "Add SMCHelperAdapter bridging real helper to FanCurveHelper"
```

---

### Task 5.2: Wire controller into Sensors module lifecycle

**Files:**
- Modify: `Modules/Sensors/main.swift:14-100`
- (No new tests — this is integration glue. Verified by `xcodebuild` and manual smoke.)

- [ ] **Step 1: Modify Sensors.init and willTerminate**

In `Modules/Sensors/main.swift`:

```swift
public class Sensors: Module {
    private var sensorsReader: SensorsReader?
    private let popupView: Popup
    private let settingsView: Settings
    private let portalView: Portal
    private let notificationsView: Notifications
    private var fanController: FanCurveController?    // NEW
    
    private var fanValueState: FanValue {
        FanValue(rawValue: Store.shared.string(key: "\(self.config.name)_fanValue", defaultValue: "percentage")) ?? .percentage
    }
    
    private var selectedSensor: String
    
    public init() {
        self.settingsView = Settings(.sensors)
        self.popupView = Popup()
        self.portalView = Portal(.sensors)
        self.notificationsView = Notifications(.sensors)
        self.selectedSensor = Store.shared.string(key: "\(ModuleType.sensors.stringValue)_sensor", defaultValue: "Average System Total")
        
        super.init(
            moduleType: .sensors,
            popup: self.popupView,
            settings: self.settingsView,
            portal: self.portalView,
            notifications: self.notificationsView
        )
        guard self.available else { return }
        
        // NEW: create fan curve controller and crash-recovery reset
        let store = ProfileStore.shared
        let helper = SMCHelperAdapter.shared
        self.fanController = FanCurveController(helper: helper, store: store)
        // Crash recovery: if we crashed leaving a fan in .forced + .curve mode,
        // bring it back to automatic on startup before anyone reads it.
        Self.resetStaleCurveModes(helper: helper, store: store)
        
        self.sensorsReader = SensorsReader { [weak self] value in
            self?.usageCallback(value)
            self?.fanController?.tick(snapshot: value)   // NEW
        }
        
        // ... existing setup ...
    }
    
    public override func willTerminate() {
        self.fanController?.shutdown()                   // NEW (before existing reset)
        
        guard SMCHelper.shared.isActive(), let reader = self.sensorsReader else { return }
        reader.list.sensors.filter({ $0 is Fan }).forEach { (s: Sensor_p) in
            if let f = s as? Fan, let mode = f.customMode {
                if !mode.isAutomatic && !mode.isStatsControlled {
                    SMCHelper.shared.setFanMode(f.id, mode: FanMode.automatic.rawValue)
                }
            }
        }
    }
    
    /// Crash recovery: any fan whose stored customMode is .curve but where Stats is no
    /// longer enabled/has no active profile gets reset to automatic to avoid stuck forced RPM.
    private static func resetStaleCurveModes(helper: FanCurveHelper, store: ProfileStore) {
        guard helper.isActive() else { return }
        for id in 0...3 {
            let key = "fan_\(id)_mode"
            guard Store.shared.exist(key: key) else { continue }
            let raw = Store.shared.int(key: key, defaultValue: 0)
            if raw == FanMode.curve.rawValue {
                let activeOK = store.enabled && store.activeProfile() != nil
                if !activeOK {
                    helper.setFanMode(id: id, mode: FanMode.automatic.rawValue)
                    Store.shared.set(key: key, value: FanMode.automatic.rawValue)
                }
            }
        }
    }
}
```

Note: `Store.shared.exist(key:)` — check existence: if `Store` API doesn't expose `.exist`, replace with `Store.shared.int(key: key, defaultValue: -1) != -1`. The whole `resetStaleCurveModes` body adapts to actual `Store` API; iterate fan ids 0..3 (more than typical 1-2) for safety.

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme Stats -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: First-run bootstrap call**

In `Sensors.init` after `self.fanController = ...`, detect fan count and call bootstrap:

```swift
// Bootstrap default profiles on first run, once we know how many fans the machine has.
// Wait until reader has populated to get accurate count; do it lazily on first tick:
```

Actually simpler — defer to first tick. In `FanCurveController.tick` before reading active profile:

```swift
public func tick(snapshot: Sensors_List?) {
    guard !isAsleep, store.enabled, helper.isActive(), let snapshot = snapshot else { return }
    
    let fans = snapshot.sensors.compactMap { $0 as? Fan }
    if !didBootstrap, !fans.isEmpty {
        let maxRpm = Int(fans.map(\.maxSpeed).max() ?? 7000)
        store.bootstrapIfNeeded(fanCount: fans.count, defaultMaxRPM: maxRpm)
        didBootstrap = true
    }
    
    // ... rest of tick body
}
```

Add `private var didBootstrap: Bool = false` to the controller's stored properties.

- [ ] **Step 4: Add a test for bootstrap-on-first-tick**

```swift
    func testController_firstTick_bootstrapsProfilesAndPicksAggressive() {
        clearProfileStore()
        let store = ProfileStore()
        store.enabled = true
        let fake = FakeFanCurveHelper()
        let c = FanCurveController(helper: fake, store: store)
        XCTAssertEqual(store.loadProfiles().count, 0, "precondition: empty store")
        c.tick(snapshot: makeSnapshot(fans: [makeFan(id: 0, max: 7000)], temps: [("TC0D", 50)]))
        XCTAssertEqual(store.loadProfiles().count, 4)
        XCTAssertEqual(store.activeProfile()?.name, "Aggressive")
        clearProfileStore()
    }
```

- [ ] **Step 5: Run all tests**

```bash
xcodebuild -scheme Stats -destination 'platform=macOS,arch=arm64' \
    -only-testing:Tests/SensorsTests test 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Modules/Sensors/main.swift Modules/Sensors/fanController.swift Tests/Sensors.swift
git commit -m "Wire FanCurveController into Sensors module with bootstrap & crash recovery"
```

---

## Phase 6 — Settings UI (manual smoke testing; no automated tests for AppKit views)

UI in `Modules/Sensors/settings.swift` follows the existing pattern (`PreferencesSection` + `PreferencesRow`). New section is appended after the existing fan-related rows (around line 72).

### Task 6.1: Master toggle + section scaffolding

**Files:**
- Modify: `Modules/Sensors/settings.swift`

- [ ] **Step 1: Add state and toggle**

In `Modules/Sensors/settings.swift`, after the existing stored properties (around line 32):

```swift
private var fanCtlEnabledState: Bool = false
private var fanCurveContainer: NSStackView?   // holds collapsible curve UI
```

In `init` after `fanValueState` is loaded:

```swift
self.fanCtlEnabledState = ProfileStore.shared.enabled
```

After the existing fan section, add:

```swift
self.addArrangedSubview(PreferencesSection([
    PreferencesRow(localizedString("Fan curves"), component: switchView(
        action: #selector(self.toggleFanCtlEnabled),
        state: self.fanCtlEnabledState
    ))
]))

let curveContainer = NSStackView()
curveContainer.orientation = .vertical
curveContainer.spacing = Constants.Settings.margin
curveContainer.isHidden = !self.fanCtlEnabledState
self.fanCurveContainer = curveContainer
self.addArrangedSubview(curveContainer)
```

And the handler:

```swift
@objc private func toggleFanCtlEnabled(_ sender: NSControl) {
    let state = controlState(sender)
    self.fanCtlEnabledState = state
    ProfileStore.shared.enabled = state
    self.fanCurveContainer?.isHidden = !state
    NotificationCenter.default.post(name: .fanControlEnabledChanged, object: nil)
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme Stats -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Modules/Sensors/settings.swift
git commit -m "Add Fan Curves master toggle to settings"
```

---

### Task 6.2: Profile picker + duplicate/delete buttons

**Files:**
- Modify: `Modules/Sensors/settings.swift`

- [ ] **Step 1: Add profile picker UI**

Add helper to refresh picker:

```swift
private var profilePopup: NSPopUpButton?

private func reloadProfilePicker() {
    let popup = profilePopup ?? NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    popup.removeAllItems()
    let profiles = ProfileStore.shared.loadProfiles()
    for p in profiles {
        popup.addItem(withTitle: p.name)
        popup.lastItem?.representedObject = p.id
    }
    if let activeID = ProfileStore.shared.activeProfileID,
       let idx = profiles.firstIndex(where: { $0.id == activeID }) {
        popup.selectItem(at: idx)
    }
    popup.target = self
    popup.action = #selector(profileChanged(_:))
    self.profilePopup = popup
}

@objc private func profileChanged(_ sender: NSPopUpButton) {
    guard let id = sender.selectedItem?.representedObject as? UUID else { return }
    ProfileStore.shared.activeProfileID = id
    NotificationCenter.default.post(name: .fanProfileChanged, object: nil)
    self.refreshCurveEditor()
}

private func refreshCurveEditor() {
    // Populate driver checklist + points table based on currently-active profile.
    // Implemented incrementally in 6.3 / 6.4.
}
```

In the curveContainer build, add the picker row:

```swift
reloadProfilePicker()
if let popup = self.profilePopup {
    curveContainer.addArrangedSubview(PreferencesRow(
        localizedString("Active profile"), component: popup))
}

let duplicateBtn = NSButton(title: localizedString("Duplicate"), target: self,
    action: #selector(duplicateProfile))
let deleteBtn = NSButton(title: localizedString("Delete"), target: self,
    action: #selector(deleteProfile))
let buttonRow = NSStackView(views: [duplicateBtn, deleteBtn])
buttonRow.spacing = 8
curveContainer.addArrangedSubview(buttonRow)

@objc private func duplicateProfile() {
    var profiles = ProfileStore.shared.loadProfiles()
    guard let activeID = ProfileStore.shared.activeProfileID,
          let original = profiles.first(where: { $0.id == activeID }) else { return }
    var copy = original
    copy.id = UUID()
    copy.name = original.name + " (copy)"
    copy.isBuiltIn = false
    profiles.append(copy)
    ProfileStore.shared.saveProfiles(profiles)
    ProfileStore.shared.activeProfileID = copy.id
    reloadProfilePicker()
    refreshCurveEditor()
    NotificationCenter.default.post(name: .fanProfileChanged, object: nil)
}

@objc private func deleteProfile() {
    var profiles = ProfileStore.shared.loadProfiles()
    guard let activeID = ProfileStore.shared.activeProfileID,
          let idx = profiles.firstIndex(where: { $0.id == activeID }),
          !profiles[idx].isBuiltIn else { return }
    profiles.remove(at: idx)
    ProfileStore.shared.saveProfiles(profiles)
    ProfileStore.shared.activeProfileID = profiles.first?.id
    reloadProfilePicker()
    refreshCurveEditor()
    NotificationCenter.default.post(name: .fanProfileChanged, object: nil)
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme Stats -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Modules/Sensors/settings.swift
git commit -m "Add fan curve profile picker with duplicate/delete actions"
```

---

### Task 6.3: Curve points editor (table)

**Files:**
- Modify: `Modules/Sensors/settings.swift`

- [ ] **Step 1: Add NSTableView for curve points + datasource**

Add a private inner class for the table data source/delegate:

```swift
private final class CurvePointsTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var points: [CurvePoint] = []
    var onEdit: ([CurvePoint]) -> Void = { _ in }
    
    func numberOfRows(in tableView: NSTableView) -> Int { points.count }
    
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?,
                   row: Int) -> Any? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        let pt = points[row]
        switch id {
        case "temp": return pt.tempC
        case "rpm":  return pt.rpm
        default:     return nil
        }
    }
    
    func tableView(_ tableView: NSTableView, setObjectValue object: Any?,
                   for tableColumn: NSTableColumn?, row: Int) {
        guard let id = tableColumn?.identifier.rawValue else { return }
        switch id {
        case "temp":
            if let s = object as? String, let v = Double(s) { points[row].tempC = v }
            else if let v = object as? Double { points[row].tempC = v }
        case "rpm":
            if let s = object as? String, let v = Int(s) { points[row].rpm = v }
            else if let v = object as? Int { points[row].rpm = v }
        default: break
        }
        points.sort { $0.tempC < $1.tempC }
        onEdit(points)
    }
}
```

Add to Settings stored properties:

```swift
private var pointsTable: NSTableView?
private let pointsDataSource = CurvePointsTable()
```

Build the table inside the curveContainer:

```swift
let table = NSTableView()
let tempCol = NSTableColumn(identifier: .init("temp"))
tempCol.title = localizedString("Temp °C")
tempCol.width = 80
let rpmCol = NSTableColumn(identifier: .init("rpm"))
rpmCol.title = localizedString("RPM")
rpmCol.width = 80
table.addTableColumn(tempCol); table.addTableColumn(rpmCol)
table.dataSource = pointsDataSource
table.delegate = pointsDataSource
pointsDataSource.onEdit = { [weak self] _ in
    self?.persistCurveEdits()
}
let scroll = NSScrollView()
scroll.documentView = table
scroll.hasVerticalScroller = true
scroll.translatesAutoresizingMaskIntoConstraints = false
scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
self.pointsTable = table
curveContainer.addArrangedSubview(scroll)

let addBtn = NSButton(title: "+", target: self, action: #selector(addPoint))
let removeBtn = NSButton(title: "−", target: self, action: #selector(removePoint))
curveContainer.addArrangedSubview(NSStackView(views: [addBtn, removeBtn]))

@objc private func addPoint() {
    var pts = self.pointsDataSource.points
    let lastTemp = pts.last?.tempC ?? 50
    pts.append(CurvePoint(tempC: lastTemp + 5, rpm: 3000))
    pts.sort { $0.tempC < $1.tempC }
    self.pointsDataSource.points = pts
    self.pointsTable?.reloadData()
    self.persistCurveEdits()
}

@objc private func removePoint() {
    guard let row = self.pointsTable?.selectedRow, row >= 0,
          self.pointsDataSource.points.count > 2 else { return }
    self.pointsDataSource.points.remove(at: row)
    self.pointsTable?.reloadData()
    self.persistCurveEdits()
}

private func persistCurveEdits() {
    var profiles = ProfileStore.shared.loadProfiles()
    guard let activeID = ProfileStore.shared.activeProfileID,
          let idx = profiles.firstIndex(where: { $0.id == activeID }) else { return }
    if profiles[idx].isBuiltIn {
        // Editing a built-in: duplicate first.
        var copy = profiles[idx]
        copy.id = UUID()
        copy.isBuiltIn = false
        copy.name = profiles[idx].name + " (custom)"
        profiles.append(copy)
        ProfileStore.shared.activeProfileID = copy.id
        profiles[profiles.count - 1].points = self.pointsDataSource.points
    } else {
        profiles[idx].points = self.pointsDataSource.points
    }
    ProfileStore.shared.saveProfiles(profiles)
    NotificationCenter.default.post(name: .fanProfileChanged, object: nil)
    self.reloadProfilePicker()
}
```

Update `refreshCurveEditor`:

```swift
private func refreshCurveEditor() {
    let pts = ProfileStore.shared.activeProfile()?.points ?? []
    self.pointsDataSource.points = pts
    self.pointsTable?.reloadData()
}
```

Call `refreshCurveEditor()` at the end of `init` (after the table is built).

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme Stats -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Modules/Sensors/settings.swift
git commit -m "Add curve points editor table with add/remove and edit-on-built-in dup"
```

---

### Task 6.4: Driver sensors checklist

**Files:**
- Modify: `Modules/Sensors/settings.swift`

- [ ] **Step 1: Build sensor checklist**

Add stored:

```swift
private var driversTable: NSTableView?
private final class DriversTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var allSensors: [(key: String, name: String)] = []
    var selected: Set<String> = []
    var onToggle: (Set<String>) -> Void = { _ in }
    
    func numberOfRows(in t: NSTableView) -> Int { allSensors.count }
    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let s = allSensors[row]
        let cb = NSButton(checkboxWithTitle: "\(s.name) (\(s.key))",
            target: self, action: #selector(toggle(_:)))
        cb.tag = row
        cb.state = selected.contains(s.key) ? .on : .off
        return cb
    }
    
    @objc private func toggle(_ sender: NSButton) {
        let key = allSensors[sender.tag].key
        if sender.state == .on { selected.insert(key) } else { selected.remove(key) }
        onToggle(selected)
    }
}
private let driversDataSource = DriversTable()
```

Add a method:

```swift
private func refreshDriversChecklist() {
    let profile = ProfileStore.shared.activeProfile()
    let selected = Set(profile?.drivers.map(\.key) ?? [])
    self.driversDataSource.selected = selected
    // Build allSensors from current reader's temp sensors:
    let allTemps: [(String, String)] = self.list
        .filter { $0.type == .temperature }
        .map { ($0.key, $0.name) }
    self.driversDataSource.allSensors = allTemps
    self.driversTable?.reloadData()
}
```

In curveContainer build:

```swift
let driversTable = NSTableView()
let driverCol = NSTableColumn(identifier: .init("driver"))
driverCol.title = localizedString("Driver sensors (max of)")
driversTable.addTableColumn(driverCol)
driversTable.dataSource = self.driversDataSource
driversTable.delegate = self.driversDataSource
self.driversDataSource.onToggle = { [weak self] sel in
    self?.persistDriverEdits(Array(sel))
}
let driverScroll = NSScrollView()
driverScroll.documentView = driversTable
driverScroll.hasVerticalScroller = true
driverScroll.translatesAutoresizingMaskIntoConstraints = false
driverScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
self.driversTable = driversTable
curveContainer.addArrangedSubview(driverScroll)

private func persistDriverEdits(_ keys: [String]) {
    var profiles = ProfileStore.shared.loadProfiles()
    guard let activeID = ProfileStore.shared.activeProfileID,
          let idx = profiles.firstIndex(where: { $0.id == activeID }) else { return }
    if profiles[idx].isBuiltIn {
        var copy = profiles[idx]
        copy.id = UUID()
        copy.isBuiltIn = false
        copy.name = profiles[idx].name + " (custom)"
        copy.drivers = keys.map { DriverSensor(key: $0) }
        profiles.append(copy)
        ProfileStore.shared.activeProfileID = copy.id
    } else {
        profiles[idx].drivers = keys.map { DriverSensor(key: $0) }
    }
    ProfileStore.shared.saveProfiles(profiles)
    NotificationCenter.default.post(name: .fanProfileChanged, object: nil)
    self.reloadProfilePicker()
}
```

Add `refreshDriversChecklist()` to `refreshCurveEditor()`:

```swift
private func refreshCurveEditor() {
    let pts = ProfileStore.shared.activeProfile()?.points ?? []
    self.pointsDataSource.points = pts
    self.pointsTable?.reloadData()
    refreshDriversChecklist()
}
```

Also update on `setList(_ list:)` (existing method on Settings that gets called when sensor list changes):

```swift
public func setList(_ list: [Sensor_p]?) {
    // existing impl ...
    self.list = list ?? []
    self.refreshDriversChecklist()
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme Stats -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Modules/Sensors/settings.swift
git commit -m "Add driver sensors checklist to fan curve settings"
```

---

### Task 6.5: Fan offset field + advanced disclosure

**Files:**
- Modify: `Modules/Sensors/settings.swift`

- [ ] **Step 1: Add offset + advanced fields**

Add stored:

```swift
private var offsetField: NSTextField?
private var hysteresisField: NSTextField?
private var thresholdField: NSTextField?
```

In curveContainer build (after the table):

```swift
// Show only if machine has ≥2 fans — measured via SMCHelper at setup time.
let fanCount = self.list.compactMap { $0 as? Fan }.count
if fanCount >= 2 {
    let offset = NSTextField()
    offset.target = self
    offset.action = #selector(commitOffset(_:))
    offset.stringValue = String(ProfileStore.shared.activeProfile()?.fanOffsetRPM ?? 50)
    self.offsetField = offset
    curveContainer.addArrangedSubview(PreferencesRow(
        localizedString("Fan 1 offset (RPM)"), component: offset))
}

// Advanced
let advancedBox = NSBox()
advancedBox.title = localizedString("Advanced")
let advStack = NSStackView()
advStack.orientation = .vertical
advStack.spacing = 4

let hyst = NSTextField()
hyst.target = self; hyst.action = #selector(commitHysteresis(_:))
hyst.stringValue = String(ProfileStore.shared.activeProfile()?.hysteresisC ?? 2.0)
self.hysteresisField = hyst
advStack.addArrangedSubview(PreferencesRow(localizedString("Hysteresis (°C)"), component: hyst))

let thresh = NSTextField()
thresh.target = self; thresh.action = #selector(commitThreshold(_:))
thresh.stringValue = String(ProfileStore.shared.activeProfile()?.deltaRpmThreshold ?? 150)
self.thresholdField = thresh
advStack.addArrangedSubview(PreferencesRow(localizedString("RPM apply threshold"), component: thresh))

advancedBox.contentView = advStack
curveContainer.addArrangedSubview(advancedBox)

@objc private func commitOffset(_ sender: NSTextField) {
    let v = max(0, min(1000, Int(sender.stringValue) ?? 50))
    sender.stringValue = String(v)
    self.editActiveProfile { $0.fanOffsetRPM = v }
}
@objc private func commitHysteresis(_ sender: NSTextField) {
    let v = max(0.5, min(10, Double(sender.stringValue) ?? 2.0))
    sender.stringValue = String(v)
    self.editActiveProfile { $0.hysteresisC = v }
}
@objc private func commitThreshold(_ sender: NSTextField) {
    let v = max(50, min(500, Int(sender.stringValue) ?? 150))
    sender.stringValue = String(v)
    self.editActiveProfile { $0.deltaRpmThreshold = v }
}

private func editActiveProfile(_ mutate: (inout FanProfile) -> Void) {
    var profiles = ProfileStore.shared.loadProfiles()
    guard let activeID = ProfileStore.shared.activeProfileID,
          let idx = profiles.firstIndex(where: { $0.id == activeID }) else { return }
    if profiles[idx].isBuiltIn {
        var copy = profiles[idx]
        copy.id = UUID()
        copy.isBuiltIn = false
        copy.name = profiles[idx].name + " (custom)"
        mutate(&copy)
        profiles.append(copy)
        ProfileStore.shared.activeProfileID = copy.id
    } else {
        mutate(&profiles[idx])
    }
    ProfileStore.shared.saveProfiles(profiles)
    NotificationCenter.default.post(name: .fanProfileChanged, object: nil)
    self.reloadProfilePicker()
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme Stats -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Modules/Sensors/settings.swift
git commit -m "Add fan 1 offset and advanced (hysteresis/threshold) fields"
```

---

### Task 6.6: Mini curve graph

**Files:**
- Create: `Modules/Sensors/curveGraph.swift`
- Modify: `Modules/Sensors/settings.swift`

- [ ] **Step 1: Implement CurveGraphView**

Create `Modules/Sensors/curveGraph.swift`:

```swift
//
//  curveGraph.swift
//  Sensors
//

import AppKit

public final class CurveGraphView: NSView {
    public var points: [CurvePoint] = [] { didSet { needsDisplay = true } }
    public var maxRPM: Int = 7000 { didSet { needsDisplay = true } }
    public var tempRange: ClosedRange<Double> = 20...100 { didSet { needsDisplay = true } }
    
    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds.insetBy(dx: 8, dy: 8)
        
        ctx.setFillColor(NSColor.controlBackgroundColor.cgColor)
        ctx.fill(rect)
        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(rect)
        
        guard points.count >= 2 else { return }
        
        let tempLo = tempRange.lowerBound, tempHi = tempRange.upperBound
        let tempSpan = tempHi - tempLo
        let yScale = rect.height / CGFloat(maxRPM)
        
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(2)
        ctx.beginPath()
        for (i, pt) in points.enumerated() {
            let x = rect.minX + CGFloat((pt.tempC - tempLo) / tempSpan) * rect.width
            let y = rect.minY + CGFloat(pt.rpm) * yScale
            if i == 0 { ctx.move(to: CGPoint(x: x, y: y)) }
            else      { ctx.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.strokePath()
        
        // Dots at points
        ctx.setFillColor(NSColor.systemBlue.cgColor)
        for pt in points {
            let x = rect.minX + CGFloat((pt.tempC - tempLo) / tempSpan) * rect.width
            let y = rect.minY + CGFloat(pt.rpm) * yScale
            ctx.fillEllipse(in: CGRect(x: x-3, y: y-3, width: 6, height: 6))
        }
    }
}
```

Add to Sensors target in Xcode project.

In `settings.swift`, add graph below points table:

```swift
private var graphView: CurveGraphView?

// in curveContainer build after pointsTable scroll:
let graph = CurveGraphView()
graph.translatesAutoresizingMaskIntoConstraints = false
graph.heightAnchor.constraint(equalToConstant: 100).isActive = true
self.graphView = graph
curveContainer.addArrangedSubview(graph)

// In refreshCurveEditor():
self.graphView?.points = pts
let maxRpm = Int(self.list.compactMap({ $0 as? Fan }).map(\.maxSpeed).max() ?? 7000)
self.graphView?.maxRPM = maxRpm
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme Stats -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Modules/Sensors/curveGraph.swift Modules/Sensors/settings.swift Stats.xcodeproj/project.pbxproj
git commit -m "Add mini curve graph preview to fan curve settings"
```

---

## Phase 7 — Build, sign, install

### Task 7.1: Add `local` Makefile target

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: Append target**

Add to `Makefile`:

```makefile
# --- LOCAL DEV BUILD (no notarization, ad-hoc sign, install to /Applications) ---
.PHONY: local
local: clean
	xcodebuild \
		-scheme $(APP) \
		-configuration Release \
		-derivedDataPath $(BUILD_PATH)/DerivedData \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGN_STYLE=Manual \
		DEVELOPMENT_TEAM="" \
		ONLY_ACTIVE_ARCH=YES \
		build
	codesign --force --deep --sign - \
		"$(BUILD_PATH)/DerivedData/Build/Products/Release/$(APP).app"
	@if [ -d "/Applications/$(APP).app" ]; then \
		osascript -e 'tell application "$(APP)" to quit' 2>/dev/null || true; \
		sleep 1; \
		rm -rf "/Applications/$(APP).app"; \
	fi
	cp -R "$(BUILD_PATH)/DerivedData/Build/Products/Release/$(APP).app" /Applications/
	xattr -cr "/Applications/$(APP).app"
	@echo "Stats installed to /Applications. Launch from Spotlight."
```

- [ ] **Step 2: Test the target builds (don't install yet)**

```bash
cd /Users/ank/dev/stats && make local 2>&1 | tail -30
```

Expected: build succeeds, app appears in `/Applications/Stats.app`. May prompt for admin password for the SMC helper install on first launch.

- [ ] **Step 3: Verify signature**

```bash
codesign -dv /Applications/Stats.app 2>&1 | head -10
```

Expected output includes `Signature=adhoc`.

- [ ] **Step 4: Commit**

```bash
git add Makefile
git commit -m "Add make local target for ad-hoc sign + install"
```

---

### Task 7.2: Manual integration smoke test

This is a checklist, not code. Run each item, mark complete only after observation.

- [ ] **A. Launch Stats from /Applications**

Spotlight → Stats. Menubar shows existing widgets. Settings opens.

- [ ] **B. Enable Fan Curves**

Sensors settings → toggle "Fan curves" ON. UI expands. Profile dropdown shows Apple Auto / Quiet / Balanced / Aggressive, with Aggressive selected.

- [ ] **C. Verify SMC helper is active**

```bash
sudo launchctl list | grep -i stats
```

Should show `eu.exelban.Stats.SMC.Helper`. If not, click "Install helper" prompt that should appear in settings.

- [ ] **D. Stress test — verify ramp-up**

```bash
yes > /dev/null &
yes > /dev/null &
yes > /dev/null &
yes > /dev/null &
```

After 10-20 seconds:

```bash
smc -k F0Ac -r 2>/dev/null || ~/dev/stats/smc/smc -k F0Ac -r
```

Expected: RPM should be ramping above idle (>2000 RPM) and within ~2s following our curve.

Kill the load: `killall yes`.

- [ ] **E. Profile switch latency**

Switch profile to Quiet. Within ~5 seconds RPM should drop. Re-stress test, then switch to Aggressive: RPM should climb faster.

- [ ] **F. Master toggle release**

Toggle "Fan curves" OFF. Within ~2s `smc -k F0Md -r` should show 0 (automatic).

- [ ] **G. Sleep / wake**

Sleep the Mac (Apple menu → Sleep, or close lid). Wait 10s. Wake. Fan curve should resume (re-stress test, observe RPM under our control).

- [ ] **H. Crash recovery**

Re-enable curves and create some load. Then:

```bash
killall -9 Stats
```

Open Stats again. Without our curves enabled (i.e. master toggle OFF before crash): on launch, fan mode should reset to automatic. With curves enabled: should resume.

- [ ] **I. 1-fan only on M5**

`smc -k F0Ac -r` works; `smc -k F1Ac -r` should return error or nothing. UI offset field should be hidden (we hide it when fanCount < 2).

- [ ] **J. Activity Monitor sanity**

Open Activity Monitor → search Stats. Average CPU should sit ≤0.5% over a minute. RAM ≤150 MB total Stats.app.

- [ ] **K. Commit smoke notes (optional)**

If anything misbehaved during this checklist, file as a bug and fix before proceeding.

---

## Phase 8 — Docs and fork housekeeping

### Task 8.1: Add fork CLAUDE.md

**Files:**
- Create: `CLAUDE.md`

- [ ] **Step 1: Write CLAUDE.md**

Create `CLAUDE.md` at fork root:

```markdown
# CLAUDE.md

## Before Starting

Personal fork of `exelban/stats` extended with **Fan Curve Control** (see `docs/superpowers/specs/2026-06-08-stats-fan-curve-design.md`). Before non-trivial changes to fan-related code, re-read that spec.

Key modified files relative to upstream:
- `SMC/smc.swift` — added `FanMode.curve = 100` case
- `Modules/Sensors/values.swift` — added `CurvePoint`, `DriverSensor`, `FanProfile`
- `Modules/Sensors/fanCurve.swift` — interpolate, effectiveTemperature, builtIns (NEW)
- `Modules/Sensors/profileStore.swift` — persistence (NEW)
- `Modules/Sensors/fanController.swift` — FanCurveController + FanCurveHelper protocol (NEW)
- `Modules/Sensors/curveGraph.swift` — mini graph view (NEW)
- `Modules/Sensors/settings.swift` — Fan Curves section
- `Modules/Sensors/main.swift` — wires controller into lifecycle
- `Kit/types.swift` — `.fanProfileChanged` and `.fanControlEnabledChanged`
- `Tests/Sensors.swift` — unit tests (NEW)
- `Makefile` — `make local` target (NEW)

## Codebase Index

MCP `codebase-memory` has this repo indexed as project `Users-ank-dev-stats`. Use `mcp__codebase-memory__search_code`, `get_architecture`, `trace_path` before exploring files manually.

## Build & Verify

```bash
xcodebuild -scheme Stats -configuration Debug build              # compile only
xcodebuild -scheme Stats -destination 'platform=macOS,arch=arm64' \
    -only-testing:Tests/SensorsTests test                         # run new tests
make local                                                        # build, ad-hoc sign, install to /Applications
```

## Release Builds

For personal use, only `make local`. Upstream's `make build` (archive → notarize → sign with `AC_PASSWORD` keychain profile → dmg) needs an Apple Developer account and is not configured here.

`make local` does:
- Release build with `CODE_SIGN_IDENTITY=-` (ad-hoc).
- `codesign --force --deep --sign -` on the bundle (signs nested SMC helper and LaunchAtLogin).
- Quits running Stats, removes old `/Applications/Stats.app`, copies new one.
- `xattr -cr` to strip quarantine flag.

## Post-Task

After completing a feature or fix:

1. `xcodebuild -scheme Stats build` — must succeed.
2. `xcodebuild -scheme Stats -destination 'platform=macOS,arch=arm64' -only-testing:Tests/SensorsTests test` — full Sensors test suite passes.
3. `make local` — produces signed app in /Applications.
4. Bump `CFBundleVersion` in `Stats/Supporting Files/Info.plist` (use `make next-version`).
5. `git commit` (see commit rules below).
6. `mcp__codebase-memory__index_repository(repo_path="/Users/ank/dev/stats", mode="full")` — reindex so future sessions see the new files.
7. Short status line to user: version bumped X→Y, commit SHA, reindex done.

Don't push to upstream remote — this is a personal fork; commits stay local until explicitly pushed.

## Commit & Code-Attribution Rules

- **No `Co-Authored-By: Claude` trailers.** Same as global `~/CLAUDE.md`. Commit messages contain only what the developer wrote.
- **No "Generated with Claude" footers** in commit bodies.
- **No AI-attribution comments in code.** Files have human authorship only.
- Commit messages: English, imperative, no `feat:`/`fix:` prefixes (matches upstream style).
- One logical change = one commit.

When creating a NEW Swift file in this fork, write your own name and current date in the file-header comment block. Don't keep "Created by Serhiy Mytrovtsiy" on a file you authored. For files you **modify** (not create), leave the original header.

## Structure Conventions

- All new fan-curve code lives in `Modules/Sensors/` next to existing fan-related logic.
- New `Notification.Name` entries go in `Kit/types.swift` next to existing ones.
- New `Store.shared` keys use the `fanctl_` prefix to be greppable (`fanctl_enabled`, `fanctl_profiles`, `fanctl_activeProfile`).
- All XPC calls go through `SMCHelper.shared` (or the `FanCurveHelper` protocol's `SMCHelperAdapter` shim). Don't construct `NSXPCConnection` directly.
- Tests in `Tests/Sensors.swift` (class `SensorsTests: XCTestCase`).

## Intentional Decisions — Do NOT "Fix" These

- `FanMode.curve = 100` is **not** a real SMC mode. SMC only understands 0/1/3. When `customMode == .curve`, the controller sets the actual SMC mode to `.forced` and writes RPM periodically; the `.curve` value is a Stats-level marker stored in `Store.shared`.
- `FanCurveHelper` protocol exists for testability. The real implementation `SMCHelperAdapter` is a thin shim over `SMCHelper.shared`; don't combine them.
- Profile model uses a **master curve + per-fan offset**, not N independent curves per fan. This was a deliberate UX simplification — see brainstorming history.
- Built-in profiles are protected from deletion. Editing a built-in auto-creates a `(custom)` copy.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "Add fork CLAUDE.md with build/test/commit rules"
```

---

### Task 8.2: Final reindex

- [ ] **Step 1: Run reindex**

```bash
codebase-memory-mcp cli index_repository \
    '{"repo_path":"/Users/ank/dev/stats","mode":"full"}' 2>&1 | tail -3
```

Expected: tail shows `"status":"indexed","nodes":N,"edges":M`. Node count should be visibly higher than initial 4919 (we added ~7 new source files and tests).

- [ ] **Step 2: Spot-check the index**

```bash
codebase-memory-mcp cli search_code \
    '{"project":"Users-ank-dev-stats","pattern":"FanCurveController","limit":3}' \
    2>&1 | tail -1 | head -c 400
```

Expected: matches in `Modules/Sensors/fanController.swift` and `Tests/Sensors.swift`.

- [ ] **Step 3: No commit needed**

The index is external state in `~/.local/share/codebase-memory/` (or wherever the tool persists). Repo's `.mcp.json` was committed earlier (Phase 0 setup), if not — add it now:

```bash
git status .mcp.json
# If untracked:
git add .mcp.json
git commit -m "Configure codebase-memory MCP for this repo"
```

---

## Self-review checklist (for the engineer after finishing)

- [ ] All Phase 0 tests still pass — no regression on existing behavior.
- [ ] Tests have **no `XCTSkip`** or `// TODO` markers.
- [ ] `xcodebuild -scheme Stats build` — clean, no warnings new since baseline.
- [ ] `make local` succeeds end-to-end, app launches from /Applications.
- [ ] Manual checklist (7.2) — every item ticked.
- [ ] `git log --oneline` shows ~25 commits, each one logical and self-contained.
- [ ] No `Co-Authored-By` lines in any commit (`git log --all --pretty="%B" | grep -i co-authored-by` returns nothing).
- [ ] No AI-attribution comments in any new file (`grep -ri "claude\|anthropic" Modules/Sensors/ Tests/Sensors.swift` returns nothing).
- [ ] Codebase memory reindex done; spot-check finds new symbols.

---

## File map summary

| File | Status | Lines (approx) |
|---|---|---|
| `SMC/smc.swift` | modify | +5 |
| `Modules/Sensors/values.swift` | modify | +60 |
| `Modules/Sensors/fanCurve.swift` | new | ~80 |
| `Modules/Sensors/profileStore.swift` | new | ~80 |
| `Modules/Sensors/fanController.swift` | new | ~200 |
| `Modules/Sensors/curveGraph.swift` | new | ~60 |
| `Modules/Sensors/settings.swift` | modify | +300 |
| `Modules/Sensors/main.swift` | modify | +50 |
| `Kit/types.swift` | modify | +2 |
| `Tests/Sensors.swift` | new | ~600 |
| `Makefile` | modify | +20 |
| `CLAUDE.md` | new | ~80 |
| `docs/superpowers/specs/2026-06-08-stats-fan-curve-design.md` | new (already committed) | — |
| `.mcp.json` | new (already committed) | 7 |

Total: ~1500 lines (incl. tests). No XPC helper changes, no new Xcode target.
