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
