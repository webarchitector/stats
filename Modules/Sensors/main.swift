//
//  main.swift
//  Sensors
//
//  Created by Serhiy Mytrovtsiy on 17/06/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

public class Sensors: Module {
    private var sensorsReader: SensorsReader?
    private let popupView: Popup
    private let settingsView: Settings
    private let portalView: Portal
    private let notificationsView: Notifications
    private var fanController: FanCurveController?

    private var fanValueState: FanValue {
        FanValue(rawValue: Store.shared.string(key: "\(self.config.name)_fanValue", defaultValue: "percentage")) ?? .percentage
    }

    private var selectedSensor: String

    public init() {
        self.settingsView = Settings(.sensors)
        self.popupView = Popup()
        self.portalView = Portal(.sensors)
        self.notificationsView = Notifications(.sensors)
        self.selectedSensor = Store.shared.string(key: "\(ModuleType.sensors.stringValue)_sensor", defaultValue: "Average System Total")

        super.init(
            moduleType: .sensors,
            popup: self.popupView,
            settings: self.settingsView,
            portal: self.portalView,
            notifications: self.notificationsView
        )
        guard self.available else { return }

        let profileStore = ProfileStore.shared
        let curveHelper = SMCHelperAdapter.shared
        // When the installed helper speaks XPC v2+ (cached at last app launch
        // by `AppDelegate.applicationDidFinishLaunching`), the daemon owns
        // the tick loop server-side. Skip constructing the in-app controller
        // so we don't have two writers racing on the same SMC keys.
        let daemonMode = Store.shared.bool(key: "fanctl_daemonMode", defaultValue: false)
        if !daemonMode {
            self.fanController = FanCurveController(helper: curveHelper, store: profileStore)
            Self.resetStaleCurveModes(helper: curveHelper, store: profileStore)
        } else {
            self.fanController = nil
            info("Daemon mode active - Sensors module skipped in-app FanCurveController init")
        }

        self.sensorsReader = SensorsReader { [weak self] value in
            self?.usageCallback(value)
            // Nil-coalesced via optional chain — no-op in daemon mode.
            self?.fanController?.tick(snapshot: value)
        }
        
        self.settingsView.setList(self.sensorsReader?.list.sensors)
        self.popupView.setup(self.sensorsReader?.list.sensors)
        self.portalView.setup(self.sensorsReader?.list.sensors)
        self.notificationsView.setup(self.sensorsReader?.list.sensors)
        
        self.settingsView.callback = { [weak self] in
            self?.sensorsReader?.read()
        }
        self.settingsView.setInterval = { [weak self] value in
            self?.sensorsReader?.setInterval(value)
        }
        self.settingsView.HIDcallback = { [weak self] in
            DispatchQueue.global(qos: .background).async {
                self?.sensorsReader?.HIDCallback()
                DispatchQueue.main.async {
                    self?.popupView.setup(self?.sensorsReader?.list.sensors)
                    self?.portalView.setup(self?.sensorsReader?.list.sensors)
                    self?.settingsView.setList(self?.sensorsReader?.list.sensors)
                    self?.notificationsView.setup(self?.sensorsReader?.list.sensors)
                }
            }
        }
        self.settingsView.unknownCallback = { [weak self] in
            DispatchQueue.global(qos: .background).async {
                self?.sensorsReader?.unknownCallback()
                DispatchQueue.main.async {
                    self?.popupView.setup(self?.sensorsReader?.list.sensors)
                    self?.portalView.setup(self?.sensorsReader?.list.sensors)
                    self?.settingsView.setList(self?.sensorsReader?.list.sensors)
                    self?.notificationsView.setup(self?.sensorsReader?.list.sensors)
                }
            }
        }
        self.selectedSensor = Store.shared.string(key: "\(ModuleType.sensors.stringValue)_sensor", defaultValue: self.selectedSensor)
        self.settingsView.selectedHandler = { [weak self] value in
            self?.selectedSensor = value
            self?.sensorsReader?.read()
        }
        
        self.setReaders([self.sensorsReader])
    }
    
    public override func willTerminate() {
        // Daemon mode: the helper owns all fan state — quitting the app must
        // NOT touch SMC. The whole point of Phase 5 is "Stats can be quit
        // while fans continue to be managed by the daemon".
        if Store.shared.bool(key: "fanctl_daemonMode", defaultValue: false) { return }

        self.fanController?.shutdown()

        guard SMCHelper.shared.isActive(), let reader = self.sensorsReader else { return }

        reader.list.sensors.filter({ $0 is Fan }).forEach { (s: Sensor_p) in
            if let f = s as? Fan, let mode = f.customMode {
                if !mode.isAutomatic && !mode.isStatsControlled {
                    SMCHelper.shared.setFanMode(f.id, mode: FanMode.automatic.rawValue)
                }
            }
        }
    }

    /// Module.disable() (called when the user toggles Sensors off in Settings)
    /// only stops the readers — it doesn't fire willTerminate, so without this
    /// override the fanController stays in .forced mode at last-applied RPM.
    /// Release managed fans before the readers stop ticking.
    ///
    /// Daemon mode: skip — the daemon still ticks and the user's expectation
    /// (per spec) is "engine keeps running". To pause the daemon they call
    /// `SMCHelper.shared.setEnabled(false)` (currently unwired in the UI).
    public override func disable() {
        if Store.shared.bool(key: "fanctl_daemonMode", defaultValue: false) {
            super.disable()
            return
        }
        self.fanController?.shutdown()
        super.disable()
    }

    /// Crash recovery: any fan whose stored customMode is .curve but where Stats is no
    /// longer enabled or has no active profile gets reset to automatic to avoid stuck
    /// forced RPM on the hardware.
    /// `internal` (not `private`) so tests using `@testable import Sensors` can call it.
    internal static func resetStaleCurveModes(helper: FanCurveHelper, store: ProfileStore) {
        guard helper.isActive() else { return }
        for id in 0...3 {
            let key = "fan_\(id)_mode"
            guard Store.shared.exist(key: key) else { continue }
            let raw = Store.shared.int(key: key, defaultValue: 0)
            if raw == FanMode.curve.rawValue {
                let activeOK = store.enabled && store.activeProfile() != nil
                if !activeOK {
                    helper.setFanMode(id: id, mode: FanMode.automatic.rawValue)
                    Store.shared.set(key: key, value: FanMode.automatic.rawValue)
                }
            }
        }
    }
    
    private func usageCallback(_ raw: Sensors_List?) {
        guard let value = raw, self.enabled else { return }
        
        self.popupView.usageCallback(value.sensors)
        self.portalView.usageCallback(value.sensors)
        self.notificationsView.usageCallback(value.sensors)
        
        let activeWidgets = self.menuBar.widgets.filter{ $0.isActive }
        self.sensorsReader?.sleepMode(state: activeWidgets.contains(where: {$0.item is Label}) && activeWidgets.count == 1)
        
        activeWidgets.forEach { (w: SWidget) in
            switch w.item {
            case let widget as Mini:
                if let active = value.sensors.first(where: { $0.key == self.selectedSensor }) {
                    var value: Double = active.localValue/100
                    var unit: String = active.miniUnit
                    if let fan = active as? Fan, self.fanValueState == .percentage {
                        value = Double(fan.percentage)/100
                        unit = "%"
                    }
                    if value > 999 {
                        unit = ""
                    }
                    widget.setValue(value)
                    widget.setSuffix(unit)
                }
            case let widget as StackWidget:
                var list: [Stack_t] = []
                
                value.sensors.forEach { (s: Sensor_p) in
                    if s.state {
                        var value = s.formattedMiniValue
                        if let f = s as? Fan {
                            if self.fanValueState == .percentage {
                                value = "\(f.percentage)%"
                            }
                        }
                        list.append(Stack_t(key: s.key, value: value))
                    }
                }
                
                widget.setValues(list)
            case let widget as BarChart:
                var flatList: [[ColorValue]] = []
                value.sensors.filter{ $0 is Fan }.forEach { (s: Sensor_p) in
                    if s.state, let f = s as? Fan {
                        flatList.append([ColorValue(((f.value*100)/f.maxSpeed)/100)])
                    }
                }
                widget.setValue(flatList)
            default: break
            }
        }
    }
}
