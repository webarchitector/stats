//
//  FanCoreClock.swift
//  FanCore
//
//  Created on 2026-06-09.
//

import Foundation

/// Injected clock so time-windowed engine behaviors (sample-window pruning,
/// derivative computation, battery-hot dwell timer) are deterministic in tests.
public protocol FanCoreClock: AnyObject { func now() -> Date }

public final class SystemFanCoreClock: FanCoreClock {
    public init() {}
    public func now() -> Date { Date() }
}

#if DEBUG
public final class FakeFanCoreClock: FanCoreClock {
    public var current: Date
    public init(_ current: Date = Date(timeIntervalSince1970: 1_000_000)) { self.current = current }
    public func now() -> Date { current }
    public func advance(by seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
}
#endif
