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
    
    /// True if a Stats process other than self is already running. Activates
    /// the existing instance so the user sees menubar widgets jump.
    private static func anotherInstanceIsRunning() -> Bool {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let myBundle = Bundle.main.bundleIdentifier ?? "eu.exelban.Stats"
        let peers = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == myBundle && $0.processIdentifier != myPID
        }
        guard let peer = peers.first else { return false }
        peer.activate(options: [.activateIgnoringOtherApps])
        return true
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
