//
//  fanController.swift
//  Sensors
//
//  Created on 08/06/2026.
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

public final class FanCurveController {
    private let helper: FanCurveHelper
    private let store: ProfileStore
    private var managedFans: Set<Int> = []
    private var lastApplied: [Int: Int] = [:]
    private var lastTempForHyst: [Int: Double] = [:]
    private var isAsleep: Bool = false

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
        // basic apply (no hysteresis / no delta-throttle yet — Task 4.3)
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
