//
//  main.swift
//  Helper
//
//  Created by Serhiy Mytrovtsiy on 17/11/2022
//  Using Swift 5.0
//  Running on macOS 13.0
//
//  Copyright © 2022 Serhiy Mytrovtsiy. All rights reserved.
//

import Foundation

let helper = Helper()
helper.run()

class Helper: NSObject, NSXPCListenerDelegate, HelperProtocol {
    private let listener: NSXPCListener
    private let smcQueue = DispatchQueue(label: "eu.exelban.Stats.SMC.Helper.smcQueue")

    private var connections = [NSXPCConnection]()

    private var smc: String? = nil

    // Phase 3: helper owns the engine. These are held in strong references for
    // the lifetime of the daemon process so the DispatchSourceTimer inside
    // `runloop` keeps firing. launchd's KeepAlive flag restarts us on crash.
    private var profileStore: PersistentProfileStore?
    private var takeoverStore: HelperTakeoverStore?
    private var helperLogger: HelperLogger?
    private var fanWriter: SMCFanWriter?
    private var sensorReader: HelperSensorReader?
    private var engine: FanCurveEngine?
    private var runloop: DaemonRunloop?

    override init() {
        self.listener = NSXPCListener(machServiceName: "eu.exelban.Stats.SMC.Helper")
        super.init()
        self.listener.delegate = self
    }

    public func run() {
        let args = CommandLine.arguments.dropFirst()
        if !args.isEmpty && args.first == "uninstall" {
            NSLog("detected uninstall command")
            if let val = args.last, let pid: pid_t = Int32(val) {
                while kill(pid, 0) == 0 {
                    usleep(50000)
                }
            }
            self.uninstallHelper()
            exit(0)
        }

        self.listener.resume()
        self.bootEngine()
        // No `shouldQuit` flag — the daemon stays alive after Stats.app
        // disconnects so the curve keeps running. launchd KeepAlive will
        // restart us on crash; explicit termination only via `uninstall`.
        RunLoop.current.run()
    }

    private func bootEngine() {
        let store = PersistentProfileStore()
        let takeover = HelperTakeoverStore()
        let logger = HelperLogger()
        let writer = SMCFanWriter()
        let reader = HelperSensorReader()
        let clock = SystemFanCoreClock()
        let engine = FanCurveEngine(helper: writer, takeover: takeover, clock: clock, logger: logger)
        let runloop = DaemonRunloop(reader: reader, engine: engine, store: store, logger: logger)

        self.profileStore = store
        self.takeoverStore = takeover
        self.helperLogger = logger
        self.fanWriter = writer
        self.sensorReader = reader
        self.engine = engine
        self.runloop = runloop

        runloop.start()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        do {
            let isValid = try CodesignCheck.codeSigningMatches(pid: newConnection.processIdentifier)
            if !isValid {
                NSLog("invalid connection, dropping")
                return false
            }
        } catch {
            NSLog("error checking code signing: \(error)")
            return false
        }

        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = self
        newConnection.invalidationHandler = { [weak self] in
            guard let self = self else { return }
            if let connectionIndex = self.connections.firstIndex(of: newConnection) {
                self.connections.remove(at: connectionIndex)
            }
            // Do NOT quit when the last connection drops — the daemon
            // outlives Stats.app so the curve keeps applying. launchd
            // re-spawns on crash; explicit teardown is uninstall-only.
        }

        self.connections.append(newConnection)
        newConnection.resume()

        return true
    }
    
    private func uninstallHelper() {
        let process = Process()
        process.launchPath = "/bin/launchctl"
        process.qualityOfService = QualityOfService.userInitiated
        process.arguments = ["unload", "/Library/LaunchDaemons/eu.exelban.Stats.SMC.Helper.plist"]
        process.launch()
        process.waitUntilExit()
        
        if process.terminationStatus != .zero {
            NSLog("termination code: \(process.terminationStatus)")
        }
        NSLog("unloaded from launchctl")
        
        do {
            try FileManager.default.removeItem(at: URL(fileURLWithPath: "/Library/LaunchDaemons/eu.exelban.Stats.SMC.Helper.plist"))
        } catch let err {
            NSLog("plist deletion: \(err)")
        }
        NSLog("property list deleted")
        
        do {
            try FileManager.default.removeItem(at: URL(fileURLWithPath: "/Library/PrivilegedHelperTools/eu.exelban.Stats.SMC.Helper"))
        } catch let err {
            NSLog("helper deletion: \(err)")
        }
        NSLog("smc helper deleted")
    }
}

extension Helper {
    func version(completion: (String) -> Void) {
        completion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
    }
    func protocolVersion(completion: (Int) -> Void) {
        // Bumped to 2 in Phase 3: daemon owns engine + tick loop. Phase 4 adds
        // the full new XPC surface (profile push, takeover sync, etc.) and
        // will bump again.
        completion(2)
    }
    func setSMCPath(_ path: String) {
        self.smc = path
    }
    
    func setFanMode(id: Int, mode: Int, completion: (String?) -> Void) {
        smcQueue.sync {
            guard let smc = self.smc else {
                completion("missing smc tool")
                return
            }
            let result = syncShell("\(smc) fan \(id) -m \(mode)")
            
            if let error = result.error, !error.isEmpty {
                NSLog("error set fan mode: \(error)")
                completion(nil)
                return
            }
            
            completion(result.output)
        }
    }
    
    func setFanSpeed(id: Int, value: Int, completion: (String?) -> Void) {
        smcQueue.sync {
            guard let smc = self.smc else {
                completion("missing smc tool")
                return
            }
            
            let result = syncShell("\(smc) fan \(id) -v \(value)")
            
            if let error = result.error, !error.isEmpty {
                NSLog("error set fan speed: \(error)")
                completion(nil)
                return
            }
            
            completion(result.output)
        }
    }
    
    func resetFanControl(completion: (String?) -> Void) {
        smcQueue.sync {
            guard let smc = self.smc else {
                completion("missing smc tool")
                return
            }
            let result = syncShell("\(smc) reset")
            if let error = result.error, !error.isEmpty {
                NSLog("error reset fan control: \(error)")
                completion(nil)
                return
            }
            completion(result.output)
        }
    }
    
    public func syncShell(_ args: String) -> (output: String?, error: String?) {
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", args]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        
        defer {
            outputPipe.fileHandleForReading.closeFile()
            errorPipe.fileHandleForReading.closeFile()
        }
        
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        
        do {
            try task.run()
        } catch let err {
            return (nil, "syncShell: \(err.localizedDescription)")
        }
        
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8)
        let error = String(data: errorData, encoding: .utf8)
        
        return (output, error)
    }
    
    func uninstall() {
        let process = Process()
        process.launchPath = "/Library/PrivilegedHelperTools/eu.exelban.Stats.SMC.Helper"
        process.qualityOfService = QualityOfService.userInitiated
        process.arguments = ["uninstall", String(getpid())]
        process.launch()
        exit(0)
    }
}

// https://github.com/duanefields/VirtualKVM/blob/master/VirtualKVM/CodesignCheck.swift
let kSecCSDefaultFlags = 0

enum CodesignCheckError: Error {
    case message(String)
}

struct CodesignCheck {
    public static func codeSigningMatches(pid: pid_t) throws -> Bool {
        return try self.codeSigningCertificatesForSelf() == self.codeSigningCertificates(forPID: pid)
    }
    
    private static func codeSigningCertificatesForSelf() throws -> [SecCertificate] {
        guard let secStaticCode = try secStaticCodeSelf() else { return [] }
        return try codeSigningCertificates(forStaticCode: secStaticCode)
    }
    
    private static func codeSigningCertificates(forPID pid: pid_t) throws -> [SecCertificate] {
        guard let secStaticCode = try secStaticCode(forPID: pid) else { return [] }
        return try codeSigningCertificates(forStaticCode: secStaticCode)
    }
    
    private static func executeSecFunction(_ secFunction: () -> (OSStatus) ) throws {
        let osStatus = secFunction()
        guard osStatus == errSecSuccess else {
            throw CodesignCheckError.message(String(describing: SecCopyErrorMessageString(osStatus, nil)))
        }
    }
    
    private static func secStaticCodeSelf() throws -> SecStaticCode? {
        var secCodeSelf: SecCode?
        try executeSecFunction { SecCodeCopySelf(SecCSFlags(rawValue: 0), &secCodeSelf) }
        guard let secCode = secCodeSelf else {
            throw CodesignCheckError.message("SecCode returned empty from SecCodeCopySelf")
        }
        return try secStaticCode(forSecCode: secCode)
    }
    
    private static func secStaticCode(forPID pid: pid_t) throws -> SecStaticCode? {
        var secCodePID: SecCode?
        try executeSecFunction { SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &secCodePID) }
        guard let secCode = secCodePID else {
            throw CodesignCheckError.message("SecCode returned empty from SecCodeCopyGuestWithAttributes")
        }
        return try secStaticCode(forSecCode: secCode)
    }
    
    private static func secStaticCode(forSecCode secCode: SecCode) throws -> SecStaticCode? {
        var secStaticCodeCopy: SecStaticCode?
        try executeSecFunction { SecCodeCopyStaticCode(secCode, [], &secStaticCodeCopy) }
        guard let secStaticCode = secStaticCodeCopy else {
            throw CodesignCheckError.message("SecStaticCode returned empty from SecCodeCopyStaticCode")
        }
        return secStaticCode
    }
    
    private static func isValid(secStaticCode: SecStaticCode) throws {
        try executeSecFunction { SecStaticCodeCheckValidity(secStaticCode, SecCSFlags(rawValue: kSecCSDoNotValidateResources | kSecCSCheckNestedCode), nil) }
    }
    
    private static func secCodeInfo(forStaticCode secStaticCode: SecStaticCode) throws -> [String: Any]? {
        try isValid(secStaticCode: secStaticCode)
        var secCodeInfoCFDict: CFDictionary?
        try executeSecFunction { SecCodeCopySigningInformation(secStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &secCodeInfoCFDict) }
        guard let secCodeInfo = secCodeInfoCFDict as? [String: Any] else {
            throw CodesignCheckError.message("CFDictionary returned empty from SecCodeCopySigningInformation")
        }
        return secCodeInfo
    }
    
    private static func codeSigningCertificates(forStaticCode secStaticCode: SecStaticCode) throws -> [SecCertificate] {
        guard
            let secCodeInfo = try secCodeInfo(forStaticCode: secStaticCode),
            let secCertificates = secCodeInfo[kSecCodeInfoCertificates as String] as? [SecCertificate] else { return [] }
        return secCertificates
    }
}
