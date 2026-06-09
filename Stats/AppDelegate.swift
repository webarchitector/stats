//
//  AppDelegate.swift
//  Stats
//
//  Created by Serhiy Mytrovtsiy on 28.05.2019.
//  Copyright © 2019 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa

import Kit
import UserNotifications

import CPU
import RAM
import Disk
import Net
import Battery
import Sensors
import GPU
import Clock

var modules: [Module] = [
    CPU(),
    GPU(),
    RAM(),
    Disk(),
    Sensors(),
    Network(),
    Battery(),
    Clock()
]

@main
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    internal var settingsWindow: SettingsWindow?
    internal var setupWindow: SetupWindow?
    internal var supportWindow: SupportWindow?

    internal var menuBarItem: NSStatusItem? = nil
    internal var combinedView: CombinedView = CombinedView()

    internal let supportActivity = NSBackgroundActivityScheduler(identifier: "eu.exelban.Stats.support")
    
    internal var clickInNotification: Bool = false
    
    internal var pauseState: Bool {
        Store.shared.bool(key: "pause", defaultValue: false)
    }
    
    private var startTS: Date?
    private var launchStart: Date?
    
    static func main() {
        let launchStart = Date()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegate.launchStart = launchStart
        app.delegate = delegate
        app.run()
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        let startingPoint = self.launchStart ?? Date()

        // Belt-and-suspenders single-instance enforcement. Info.plist already
        // sets LSMultipleInstancesProhibited but LaunchServices doesn't always
        // honor it (e.g. `open -n`, double-clicking the .app via Finder while
        // a different copy of the bundle ran from elsewhere). If another
        // Stats process is alive, activate it and quit ourselves.
        if Self.anotherInstanceIsRunning() {
            NSApplication.shared.terminate(self)
            return
        }

        self.parseArguments()
        self.parseVersion()
        SMCHelper.shared.checkForUpdate()
        // Probe helper protocol version asynchronously and cache the result.
        // v2+ helpers own the curve tick loop server-side; the app's in-app
        // FanCurveController becomes redundant in that mode. The cached flag
        // is read by Sensors.init on the NEXT app launch — meaning the first
        // launch after installing a v2 helper still uses the in-app
        // controller. This is an intentional simplicity trade-off (no
        // synchronous probe at module init time, no race) and self-corrects
        // on relaunch.
        SMCHelper.shared.protocolVersion { version in
            let daemonMode = version >= 2
            Store.shared.set(key: "fanctl_daemonMode", value: daemonMode)
            if daemonMode {
                info("Helper is daemon-aware (v\(version)) - in-app controller will be disabled on next launch")
            } else {
                info("Helper is v\(version) (legacy) - using in-app controller")
            }
        }
        self.setup {
            modules.reversed().forEach{ $0.mount() }
            self.showSettingsIfNoActiveWidgets()
        }
        self.defaultValues()
        self.icon()
        
        NotificationCenter.default.addObserver(self, selector: #selector(listenForAppPause), name: .pause, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleToggleSettings), name: .toggleSettings, object: nil)
        
        NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handleKeyEvent(event)
        }
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handleKeyEvent(event)
            return event
        }
        
        info("Stats started in \((startingPoint.timeIntervalSinceNow * -1).rounded(toPlaces: 4)) seconds")
        self.startTS = Date()
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        modules.forEach{ $0.terminate() }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if self.clickInNotification {
            self.clickInNotification = false
            return true
        }
        guard let startTS = self.startTS, Date().timeIntervalSince(startTS) > 2 else { return false }
        
        let window = self.ensureSettingsWindow()
        if flag {
            window.makeKeyAndOrderFront(self)
        } else {
            window.setIsVisible(true)
        }
        
        return true
    }
    
    @objc private func handleToggleSettings(_ notification: Notification) {
        let module = notification.userInfo?["module"] as? String
        self.ensureSettingsWindow().open(module: module)
    }
    
    /// Terminate any older Stats process with the same bundle id. Returning
    /// `true` means OUR process should quit (an even-newer peer was found).
    /// In the common case — user re-launches Stats while a stale copy still
    /// runs — we keep ourselves (the freshly-launched binary, e.g. just-built
    /// by `make local`) and kick the old one out.
    private static func anotherInstanceIsRunning() -> Bool {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let myBundle = Bundle.main.bundleIdentifier ?? "eu.exelban.Stats"
        let me = NSRunningApplication.current
        let peers = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == myBundle && $0.processIdentifier != myPID
        }
        var shouldExitSelf = false
        for peer in peers {
            // If a peer launched after us, it's the user's intent — defer to it.
            // Otherwise force-quit the older peer; user wants the newest binary.
            // Tie-break (identical launchDate, sub-millisecond race): lower PID
            // wins so both processes deterministically agree on who survives.
            if let peerLaunch = peer.launchDate,
               let myLaunch = me.launchDate {
                if peerLaunch > myLaunch {
                    shouldExitSelf = true
                } else if peerLaunch == myLaunch && peer.processIdentifier < myPID {
                    shouldExitSelf = true
                } else {
                    peer.forceTerminate()
                }
            } else {
                peer.forceTerminate()
            }
        }
        return shouldExitSelf
    }

    private func showSettingsIfNoActiveWidgets() {
        if self.pauseState { return }
        let hasActive = modules.contains(where: { $0.enabled != false && $0.available != false && !$0.menuBar.widgets.filter({ $0.isActive }).isEmpty })
        if hasActive { return }
        self.ensureSettingsWindow().setIsVisible(true)
    }
    
    internal func ensureSettingsWindow() -> SettingsWindow {
        if let w = self.settingsWindow { return w }
        let w = SettingsWindow()
        w.onClose = { [weak self] in self?.settingsWindow = nil }
        self.settingsWindow = w
        return w
    }
    
    internal func ensureSetupWindow() -> SetupWindow {
        if let w = self.setupWindow { return w }
        let w = SetupWindow()
        w.onClose = { [weak self] in self?.setupWindow = nil }
        self.setupWindow = w
        return w
    }
    
    internal func ensureSupportWindow() -> SupportWindow {
        if let w = self.supportWindow { return w }
        let w = SupportWindow()
        w.onClose = { [weak self] in self?.supportWindow = nil }
        self.supportWindow = w
        return w
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        self.clickInNotification = true
        completionHandler()
    }
}
