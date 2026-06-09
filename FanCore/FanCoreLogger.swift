//
//  FanCoreLogger.swift
//  FanCore
//
//  Created on 2026-06-09.
//

import Foundation

/// Minimal logging surface. The app wraps `Kit.info`; the daemon will wrap
/// `os_log` (Phase 3). Tests can pass `NoopFanCoreLogger`.
public protocol FanCoreLogger {
    func info(_ message: String)
}

public struct NoopFanCoreLogger: FanCoreLogger {
    public init() {}
    public func info(_ message: String) {}
}
