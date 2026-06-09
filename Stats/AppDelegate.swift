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

    /// Set after a user-facing reinstall prompt has been shown in the current
    /// session. Probe completion is async and can fire more than once during
    /// startup (e.g. helper disconnected mid-probe) — without this guard the
    /// user could see the alert two or three times in quick succession.
    private static var didPromptForReinstall = false
    
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
        self.probeHelperAndMaybePromptMigration()
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
    
    /// Probe the installed helper's XPC protocol version, cache the
    /// daemon-mode flag, and — if the helper is v1 / missing / unreachable —
    /// surface a one-time reinstall prompt. The probe completion runs on a
    /// background queue (XPC); UI work hops to `.main`.
    ///
    /// Decision matrix:
    /// - Helper file missing → prompt (helper not installed at all).
    /// - Probe times out after 3 s → prompt (file present but daemon stuck).
    /// - Probe returns 0 / 1 → prompt (legacy v1 helper still on disk).
    /// - Probe returns ≥ 2 → cache `fanctl_daemonMode = true`, no prompt.
    ///
    /// The prompt is dismissable; user choice to skip falls through to the
    /// in-app `FanCurveController` (helper file might still be a working v1).
    private func probeHelperAndMaybePromptMigration() {
        let helperInstalled = SMCHelper.shared.isInstalled
        var settled = false
        let settle: (Int) -> Void = { version in
            DispatchQueue.main.async {
                if settled { return }
                settled = true
                let daemonMode = version >= 2
                Store.shared.set(key: "fanctl_daemonMode", value: daemonMode)
                if daemonMode {
                    info("Helper is daemon-aware (v\(version)) - in-app controller will be disabled on next launch")
                    // If the daemon has no active profile (fresh install /
                    // post `make uninstall-helper`), push the app's cached
                    // profile list + selection so fans get managed from this
                    // launch instead of sitting in Apple Auto until the user
                    // touches the UI.
                    DispatchQueue.global(qos: .background).async {
                        ProfileStore.shared.bootstrapDaemonIfNeeded()
                    }
                    return
                }
                if version == 0 && !helperInstalled {
                    info("Helper not installed - prompting user to install")
                } else {
                    info("Helper is v\(version) (legacy) - prompting user to reinstall")
                }
                self.promptForHelperReinstall(currentVersion: version, helperInstalled: helperInstalled)
            }
        }
        SMCHelper.shared.protocolVersion { version in settle(version) }
        // 3 s safety net — if XPC blocks (file present, daemon wedged) we
        // still want to give the user feedback rather than spin forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            settle(0)
        }
    }

    /// Show a modal NSAlert offering to (re)install the helper. Runs at most
    /// once per session (`didPromptForReinstall`).
    ///
    /// Why no week-long suppression: probe runs once at launch; if user
    /// dismissed, they won't see it again until the next app launch — already
    /// rare enough. Adding a Store-backed timestamp adds state that can
    /// desync across upgrades.
    private func promptForHelperReinstall(currentVersion: Int, helperInstalled: Bool) {
        if Self.didPromptForReinstall { return }
        Self.didPromptForReinstall = true

        let alert = NSAlert()
        if !helperInstalled {
            alert.messageText = "Install fan control helper?"
            alert.informativeText = "Stats uses a background daemon for fan control. The helper needs to be installed. You'll be prompted for your password."
        } else {
            alert.messageText = "Helper update required"
            alert.informativeText = "Stats now uses a background daemon for fan control. The installed helper (v\(currentVersion)) needs to be reinstalled. You'll be prompted for your password."
        }
        alert.addButton(withTitle: helperInstalled ? "Reinstall Helper" : "Install Helper")
        alert.addButton(withTitle: "Skip (use in-app fallback)")

        if alert.runModal() == .alertFirstButtonReturn {
            SMCHelper.shared.install { installed in
                if installed {
                    info("Helper (re)install succeeded — re-probing protocol version")
                    // Give launchd a moment to (re)load the LaunchDaemon plist.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        SMCHelper.shared.protocolVersion { v in
                            let daemonMode = v >= 2
                            Store.shared.set(key: "fanctl_daemonMode", value: daemonMode)
                            info("Post-install probe: helper protocolVersion=\(v), daemonMode=\(daemonMode)")
                            if daemonMode {
                                DispatchQueue.global(qos: .background).async {
                                    ProfileStore.shared.bootstrapDaemonIfNeeded()
                                }
                            }
                        }
                    }
                } else {
                    error_msg("Helper (re)install failed; falling back to in-app controller")
                    Store.shared.set(key: "fanctl_daemonMode", value: false)
                }
            }
        } else {
            info("User skipped helper (re)install; using in-app controller")
            Store.shared.set(key: "fanctl_daemonMode", value: false)
        }
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
        // "Newest wins": defer to any peer that out-ranks us. Rank by
        // launchDate, tie-broken by PID (lower wins) so both processes agree
        // deterministically on who survives. A missing launchDate (e.g. run
        // from a terminal / Xcode rather than via LaunchServices) falls back to
        // the PID tie-break rather than blanket-killing every peer.
        func peerOutranksMe(_ peer: NSRunningApplication) -> Bool {
            if let peerLaunch = peer.launchDate, let myLaunch = me.launchDate,
               peerLaunch != myLaunch {
                return peerLaunch > myLaunch
            }
            return peer.processIdentifier < myPID
        }

        let shouldExitSelf = peers.contains(where: peerOutranksMe)
        // Only evict the older peers once we know WE are the survivor —
        // terminating eagerly inside the decision loop would let a process
        // that is itself about to exit kill peers it should have deferred to.
        if !shouldExitSelf {
            peers.forEach { $0.forceTerminate() }
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
