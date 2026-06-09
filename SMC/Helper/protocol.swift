//
//  protocol.swift
//  Helper
//
//  Created by Serhiy Mytrovtsiy on 17/11/2022
//  Using Swift 5.0
//  Running on macOS 13.0
//
//  Copyright © 2022 Serhiy Mytrovtsiy. All rights reserved.
//

import Foundation

@objc public protocol HelperProtocol {
    func version(completion: @escaping (String) -> Void)
    /// Probe so the app (Phase 5+) can distinguish a daemon-aware helper from
    /// the legacy "RPC slave" helper. Returns 1 for legacy builds (this method
    /// will fail with `NSXPCConnection`'s unimplemented-selector error and the
    /// app should treat that as version 1); returns 2 once the helper owns the
    /// tick loop end-to-end. Phase 4 will bump this when the full new protocol
    /// (profile push, takeover, etc.) lands.
    func protocolVersion(completion: @escaping (Int) -> Void)
    func setSMCPath(_ path: String)

    func setFanMode(id: Int, mode: Int, completion: @escaping (String?) -> Void)
    func setFanSpeed(id: Int, value: Int, completion: @escaping (String?) -> Void)
    func resetFanControl(completion: @escaping (String?) -> Void)

    func uninstall()
}
