//
//  HelperLogger.swift
//  Helper
//
//  Created on 2026-06-09.
//
//  Wraps `os_log` for `FanCurveEngine`. The app-side counterpart uses
//  `Kit.info`; the daemon doesn't link Kit, so we go straight to the
//  unified-logging API. Subsystem matches the helper's bundle id so
//  `log show --predicate 'subsystem == "eu.exelban.Stats.SMC.Helper"'`
//  surfaces engine output during debugging.
//

import Foundation
import os.log

final class HelperLogger: FanCoreLogger {
    private let log = OSLog(subsystem: "eu.exelban.Stats.SMC.Helper", category: "engine")
    func info(_ message: String) {
        os_log("%{public}@", log: log, type: .info, message)
    }
}
