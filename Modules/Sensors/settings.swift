//
//  settings.swift
//  Sensors
//
//  Created by Serhiy Mytrovtsiy on 23/06/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

internal class Settings: NSStackView, Settings_v {
    private var updateIntervalValue: Int = 3
    private var hidState: Bool
    private var fanSpeedState: Bool = false
    private var fansSyncState: Bool = false
    private var unknownSensorsState: Bool = false
    private var fanValueState: FanValue = .percentage
    private var fanCurveContainer: NSStackView?
    private var profilePopup: NSPopUpButton?
    private var editPicker: NSPopUpButton?
    private var pointsTable: NSTableView?
    private let pointsDataSource = CurvePointsTable()
    private var driversTable: NSTableView?
    private let driversDataSource = DriversTable()
    private var offsetField: NSTextField?
    private var offsetRow: PreferencesRow?
    private var hysteresisField: NSTextField?
    private var thresholdField: NSTextField?
    private var graphView: CurveGraphView?
    private var deleteBtn: NSButton?

    public var callback: (() -> Void) = {}
    public var HIDcallback: (() -> Void) = {}
    public var unknownCallback: (() -> Void) = {}
    public var setInterval: ((_ value: Int) -> Void) = {_ in }
    public var selectedHandler: (String) -> Void = {_ in }

    private let title: String
    private var list: [Sensor_p] = []
    private var sensorsPrefs: PreferencesSection?
    private var selectedSensor: String = "Average System Total"
    
    public init(_ module: ModuleType) {
        self.title = module.stringValue
        self.hidState = SystemKit.shared.device.platform == .m1 ? true : false
        
        super.init(frame: NSRect.zero)
        self.orientation = .vertical
        self.spacing = Constants.Settings.margin
        
        self.updateIntervalValue = Store.shared.int(key: "\(self.title)_updateInterval", defaultValue: self.updateIntervalValue)
        self.hidState = Store.shared.bool(key: "\(self.title)_hid", defaultValue: self.hidState)
        self.fanSpeedState = Store.shared.bool(key: "\(self.title)_speed", defaultValue: self.fanSpeedState)
        self.fansSyncState = Store.shared.bool(key: "\(self.title)_fansSync", defaultValue: self.fansSyncState)
        self.unknownSensorsState = Store.shared.bool(key: "\(self.title)_unknown", defaultValue: self.unknownSensorsState)
        self.fanValueState = FanValue(rawValue: Store.shared.string(key: "\(self.title)_fanValue", defaultValue: self.fanValueState.rawValue)) ?? .percentage
        self.selectedSensor = Store.shared.string(key: "\(self.title)_sensor", defaultValue: self.selectedSensor)
        
        self.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Update interval"), component: selectView(
                action: #selector(self.changeUpdateInterval),
                items: ReaderUpdateIntervals,
                selected: "\(self.updateIntervalValue)"
            ))
        ]))
        
        self.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Fan value"), component: selectView(
                action: #selector(self.toggleFanValue),
                items: FanValues,
                selected: self.fanValueState.rawValue
            )),
            PreferencesRow(localizedString("Save the fan speed"), component: switchView(
                action: #selector(self.toggleSpeedState),
                state: self.fanSpeedState
            )),
            PreferencesRow(localizedString("Synchronize fan's control"), component: switchView(
                action: #selector(self.toggleFansSync),
                state: self.fansSyncState
            ))
        ]))
        
        var sensorsRows: [PreferencesRow] = [
            PreferencesRow(localizedString("Show unknown sensors"), component: switchView(
                action: #selector(self.toggleuUnknownSensors),
                state: self.unknownSensorsState
            ))
        ]
        if isARM {
            sensorsRows.append(PreferencesRow(localizedString("HID sensors"), component: switchView(
                action: #selector(self.toggleHID),
                state: self.hidState
            )))
        }
        sensorsRows.append(PreferencesRow(localizedString("Sensor to show"), id: "active_sensor", component: selectView(
            action: #selector(self.handleSelection),
            items: [],
            selected: self.selectedSensor)
        ))
        let sensorsPrefs = PreferencesSection(sensorsRows)
        self.sensorsPrefs = sensorsPrefs
        self.addArrangedSubview(sensorsPrefs)

        // Fan curves are always enabled. Activate Apple Auto profile to defer
        // to firmware; pick any other profile to take over.
        //
        // Settings only exposes per-profile editing (curve, drivers, advanced)
        // and profile management (duplicate/delete). The active profile picker
        // lives in the menubar popup (FanView).
        let curveContainer = NSStackView()
        curveContainer.orientation = .vertical
        curveContainer.spacing = Constants.Settings.margin
        curveContainer.alignment = .width
        self.fanCurveContainer = curveContainer
        self.addArrangedSubview(curveContainer)

        NotificationCenter.default.addObserver(self,
            selector: #selector(self.activeProfileChangedExternally),
            name: .fanProfileChanged, object: nil)

        // ─── Profile picker + "+ New" button (top of the editor) ───
        // Discoverable entry point for profile management. Picking switches
        // the active profile (same semantics as the menubar popup picker);
        // "+ New" seeds a fresh "Custom N" from Balanced and activates it.
        let editLabel = NSTextField(labelWithString: localizedString("Edit profile:"))
        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        picker.target = self
        picker.action = #selector(self.editPickerChanged(_:))
        self.editPicker = picker

        let newBtn = NSButton(title: "+ " + localizedString("New profile"),
                              target: self,
                              action: #selector(self.newProfile))
        newBtn.bezelStyle = .rounded
        newBtn.controlSize = .small
        newBtn.toolTip = localizedString("Create a new profile from Balanced and switch to it")

        let pickerSpacer = NSView()
        pickerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let editPickerRow = NSStackView(views: [editLabel, picker, newBtn, pickerSpacer])
        editPickerRow.orientation = .horizontal
        editPickerRow.alignment = .centerY
        editPickerRow.spacing = 8

        let editPickerSection = PreferencesSection()
        editPickerSection.add(PreferencesRow(nil, component: editPickerRow))
        curveContainer.addArrangedSubview(editPickerSection)

        // ─── Graph (visual anchor — sized so the curve is readable at a glance) ───
        let graph = CurveGraphView()
        graph.translatesAutoresizingMaskIntoConstraints = false
        graph.heightAnchor.constraint(equalToConstant: 220).isActive = true
        self.graphView = graph

        let graphSection = PreferencesSection(title: localizedString("Fan curve"))
        graphSection.add(graph)
        graphSection.translatesAutoresizingMaskIntoConstraints = false
        graphSection.widthAnchor.constraint(equalToConstant: 320).isActive = true

        // ─── Points table with labelled add/remove buttons below ───
        let table = NSTableView()
        let tempCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("temp"))
        tempCol.title = localizedString("Temp °C")
        tempCol.width = 80
        let rpmCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rpm"))
        rpmCol.title = localizedString("RPM")
        rpmCol.width = 80
        table.addTableColumn(tempCol)
        table.addTableColumn(rpmCol)
        table.dataSource = self.pointsDataSource
        table.delegate = self.pointsDataSource
        table.usesAlternatingRowBackgroundColors = true
        self.pointsDataSource.onEdit = { [weak self] _ in
            self?.persistCurveEdits()
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // 200pt fits a typical 7-9 point curve without scrolling
        // (header ~17pt + ~20pt per row).
        scroll.heightAnchor.constraint(equalToConstant: 200).isActive = true
        self.pointsTable = table

        // Use named labels (not just "+"/"−") so the affordance is obvious.
        let addBtn = NSButton(title: "+ " + localizedString("Add point"),
                              target: self, action: #selector(self.addPoint))
        let removeBtn = NSButton(title: "− " + localizedString("Remove"),
                                 target: self, action: #selector(self.removePoint))
        addBtn.bezelStyle = .rounded
        removeBtn.bezelStyle = .rounded
        addBtn.controlSize = .small
        removeBtn.controlSize = .small
        addBtn.toolTip = localizedString("Add point")
        removeBtn.toolTip = localizedString("Remove selected point")
        let pointsButtons = NSStackView(views: [addBtn, removeBtn, NSView()])
        pointsButtons.orientation = .horizontal
        pointsButtons.spacing = 6

        let pointsSection = PreferencesSection(title: localizedString("Points"))
        pointsSection.add(scroll)
        pointsSection.add(PreferencesRow(nil, component: pointsButtons))
        pointsSection.translatesAutoresizingMaskIntoConstraints = false
        pointsSection.widthAnchor.constraint(equalToConstant: 220).isActive = true

        // ─── Driver sensors ───
        let driversTableView = NSTableView()
        let driverCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("driver"))
        driverCol.title = localizedString("Sensor")
        driversTableView.addTableColumn(driverCol)
        driversTableView.headerView = nil
        driversTableView.dataSource = self.driversDataSource
        driversTableView.delegate = self.driversDataSource
        self.driversDataSource.onToggle = { [weak self] sel in
            self?.persistDriverEdits(Array(sel))
        }
        let driverScroll = NSScrollView()
        driverScroll.documentView = driversTableView
        driverScroll.hasVerticalScroller = true
        driverScroll.translatesAutoresizingMaskIntoConstraints = false
        driverScroll.heightAnchor.constraint(equalToConstant: 140).isActive = true
        self.driversTable = driversTableView

        let driversSection = PreferencesSection(
            title: localizedString("Driver sensors (max of)")
        )
        driversSection.add(driverScroll)
        driversSection.translatesAutoresizingMaskIntoConstraints = false
        driversSection.widthAnchor.constraint(equalToConstant: 220).isActive = true

        // Three-column row: Fan curve / Points / Drivers side by side.
        // Advanced + action bar remain full-width rows below.
        // Trailing spacer absorbs leftover horizontal space so NSStackView
        // doesn't try to stretch the fixed-width columns.
        let topSpacer = NSView()
        topSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let topRow = NSStackView(views: [graphSection, pointsSection, driversSection, topSpacer])
        topRow.orientation = .horizontal
        topRow.alignment = .top
        topRow.distribution = .fill
        topRow.spacing = 12
        curveContainer.addArrangedSubview(topRow)

        // ─── Advanced: offset, hysteresis, threshold ───
        let offset = NSTextField()
        offset.target = self
        offset.action = #selector(self.commitOffset(_:))
        offset.stringValue = String(ProfileStore.shared.activeProfile()?.fanOffsetRPM ?? 50)
        offset.widthAnchor.constraint(equalToConstant: 80).isActive = true
        self.offsetField = offset
        let offsetRow = PreferencesRow(
            localizedString("Secondary fan offset (RPM)"), component: offset)
        offsetRow.isHidden = self.list.compactMap({ $0 as? Fan }).count < 2
        self.offsetRow = offsetRow

        let hyst = NSTextField()
        hyst.target = self
        hyst.action = #selector(self.commitHysteresis(_:))
        hyst.stringValue = String(ProfileStore.shared.activeProfile()?.hysteresisC ?? 2.0)
        hyst.widthAnchor.constraint(equalToConstant: 80).isActive = true
        self.hysteresisField = hyst

        let thresh = NSTextField()
        thresh.target = self
        thresh.action = #selector(self.commitThreshold(_:))
        thresh.stringValue = String(ProfileStore.shared.activeProfile()?.deltaRpmThreshold ?? 150)
        thresh.widthAnchor.constraint(equalToConstant: 80).isActive = true
        self.thresholdField = thresh

        let advancedSection = PreferencesSection(title: localizedString("Advanced"))
        advancedSection.add(offsetRow)
        advancedSection.add(PreferencesRow(localizedString("Hysteresis (°C)"), component: hyst))
        advancedSection.add(PreferencesRow(localizedString("RPM apply threshold"), component: thresh))
        curveContainer.addArrangedSubview(advancedSection)

        // ─── Bottom action bar ───
        // Duplicate is the primary action (most common: "fork a built-in,
        // then tweak") so it gets the recommended bezel + return key.
        // Delete is destructive and unavailable for built-ins; render it
        // borderless to de-emphasise.
        let duplicateBtn = NSButton(title: localizedString("Duplicate"),
                                    target: self,
                                    action: #selector(self.duplicateProfile))
        duplicateBtn.bezelStyle = .rounded
        duplicateBtn.keyEquivalent = "\r"
        let deleteBtn = NSButton(title: localizedString("Delete"),
                                 target: self,
                                 action: #selector(self.deleteProfile))
        deleteBtn.bezelStyle = .rounded
        if #available(macOS 11.0, *) {
            deleteBtn.hasDestructiveAction = true
        }
        self.deleteBtn = deleteBtn
        deleteBtn.isEnabled = !(ProfileStore.shared.activeProfile()?.isBuiltIn ?? true)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [deleteBtn, spacer, duplicateBtn])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        let actionSection = PreferencesSection()
        actionSection.add(buttonRow)
        curveContainer.addArrangedSubview(actionSection)

        self.refreshCurveEditor()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func load(widgets: [widget_t]) {
        var sensors = self.list
        guard !sensors.isEmpty else {
            return
        }
        if !self.unknownSensorsState {
            sensors = sensors.filter({ $0.group != .unknown })
        }
        
        self.subviews.filter({ $0.identifier == NSUserInterfaceItemIdentifier("sensor") }).forEach { v in
            v.removeFromSuperview()
        }
        
        var types: [SensorType] = []
        sensors.forEach { (s: Sensor_p) in
            if !types.contains(s.type) {
                types.append(s.type)
            }
        }
        
        var buttonList: [KeyValue_t] = []
        types.forEach { (typ: SensorType) in
            let section = PreferencesSection(title: localizedString(typ.rawValue))
            section.identifier = NSUserInterfaceItemIdentifier("sensor")
            
            let filtered = sensors.filter{ $0.type == typ }
            var groups: [SensorGroup] = []
            filtered.forEach { (s: Sensor_p) in
                if !groups.contains(s.group) {
                    groups.append(s.group)
                }
            }
            groups.forEach { (group: SensorGroup) in
                filtered.filter{ $0.group == group }.forEach { (s: Sensor_p) in
                    let btn = switchView(
                        action: #selector(self.toggleSensor),
                        state: s.state
                    )
                    btn.identifier = NSUserInterfaceItemIdentifier(rawValue: s.key)
                    section.add(PreferencesRow(localizedString(s.name), component: btn))
                    buttonList.append(KeyValue_t(key: s.key, value: "\(localizedString(typ.rawValue)) - \(s.name)"))
                }
            }
            
            self.addArrangedSubview(section)
        }
        
        if let row = self.sensorsPrefs?.findRow("active_sensor") {
            if !widgets.isEmpty {
                self.sensorsPrefs?.setRowVisibility(row, newState: widgets.contains(where: { $0 == .mini }))
            }
            row.replaceComponent(with: selectView(
                action: #selector(self.handleSelection),
                items: buttonList,
                selected: self.selectedSensor
            ))
        }
    }
    
    public func setList(_ list: [Sensor_p]?) {
        guard let list else { return }
        self.list = self.unknownSensorsState ? list : list.filter({ $0.group != .unknown })
        self.load(widgets: [])
        self.refreshDriversChecklist()
        self.offsetRow?.isHidden = self.list.compactMap({ $0 as? Fan }).count < 2
    }
    
    @objc private func toggleSensor(_ sender: NSControl) {
        guard let id = sender.identifier else { return }
        Store.shared.set(key: "sensor_\(id.rawValue)", value: controlState(sender))
        self.callback()
    }
    @objc private func changeUpdateInterval(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let value = Int(key) else { return }
        self.updateIntervalValue = value
        Store.shared.set(key: "\(self.title)_updateInterval", value: value)
        self.setInterval(value)
    }
    @objc private func toggleSpeedState(_ sender: NSControl) {
        self.fanSpeedState = controlState(sender)
        Store.shared.set(key: "\(self.title)_speed", value: self.fanSpeedState)
        self.callback()
    }
    @objc private func toggleHID(_ sender: NSControl) {
        self.hidState = controlState(sender)
        Store.shared.set(key: "\(self.title)_hid", value: self.hidState)
        self.HIDcallback()
    }
    @objc private func toggleFansSync(_ sender: NSControl) {
        self.fansSyncState = controlState(sender)
        Store.shared.set(key: "\(self.title)_fansSync", value: self.fansSyncState)
    }
    @objc private func toggleuUnknownSensors(_ sender: NSControl) {
        self.unknownSensorsState = controlState(sender)
        Store.shared.set(key: "\(self.title)_unknown", value: self.unknownSensorsState)
        self.unknownCallback()
    }
    @objc private func toggleFanValue(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String, let value = FanValue(rawValue: key) {
            self.fanValueState = value
            Store.shared.set(key: "\(self.title)_fanValue", value: self.fanValueState.rawValue)
            self.callback()
        }
    }
    @objc private func handleSelection(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem, let id = item.representedObject as? String else { return }
        self.selectedSensor = id
        Store.shared.set(key: "\(self.title)_sensor", value: self.selectedSensor)
        self.selectedHandler(self.selectedSensor)
    }

    /// Called only after profile mutations (duplicate/delete) — no longer rebuilds
    /// a Settings-local popup since the active picker now lives in the menubar.
    private func reloadProfilePicker() {
        self.deleteBtn?.isEnabled = !(ProfileStore.shared.activeProfile()?.isBuiltIn ?? true)
    }

    /// Settings's editor edits the ACTIVE profile. Active is changed either
    /// from the menubar popup (`ModeButtons`) or from the in-Settings edit
    /// picker. Both paths post `.fanProfileChanged`; this observer refreshes
    /// the editor + the picker selection in lock-step.
    @objc private func activeProfileChangedExternally() {
        self.refreshCurveEditor()
        self.reloadEditPicker()
        self.deleteBtn?.isEnabled = !(ProfileStore.shared.activeProfile()?.isBuiltIn ?? true)
    }

    private func refreshCurveEditor() {
        let pts = ProfileStore.shared.activeProfile()?.points ?? []
        self.pointsDataSource.points = pts
        self.pointsTable?.reloadData()
        self.refreshDriversChecklist()
        self.graphView?.points = pts
        let maxRpm = Int(self.list.compactMap({ $0 as? Fan }).map(\.maxSpeed).max() ?? 7000)
        self.graphView?.maxRPM = maxRpm
        // Mirror Advanced text fields to the new active profile.
        let active = ProfileStore.shared.activeProfile()
        self.offsetField?.stringValue = String(active?.fanOffsetRPM ?? 50)
        self.hysteresisField?.stringValue = String(active?.hysteresisC ?? 2.0)
        self.thresholdField?.stringValue = String(active?.deltaRpmThreshold ?? 150)
        self.reloadEditPicker()
    }

    /// Rebuild the in-Settings profile picker. Each item carries the profile
    /// UUID via `representedObject`; the currently active profile is selected.
    private func reloadEditPicker() {
        guard let picker = self.editPicker else { return }
        picker.removeAllItems()
        let profiles = ProfileStore.shared.loadProfiles()
        let activeID = ProfileStore.shared.activeProfileID
        for p in profiles {
            picker.addItem(withTitle: p.name)
            picker.lastItem?.representedObject = p.id
            if p.id == activeID { picker.select(picker.lastItem) }
        }
    }

    @objc private func editPickerChanged(_ sender: NSPopUpButton) {
        guard let uuid = sender.selectedItem?.representedObject as? UUID,
              uuid != ProfileStore.shared.activeProfileID else { return }
        // Same semantics as the menubar popup-picker switching profile.
        ProfileStore.shared.activeProfileID = uuid
        NotificationCenter.default.post(name: .fanProfileChanged, object: nil)
    }

    /// "+ New" button — creates a fresh editable "Custom N" profile seeded
    /// with Balanced's curve + drivers and activates it. The
    /// `.fanProfileChanged` post triggers the editor reload + menubar popup
    /// refresh.
    @objc private func newProfile() {
        let fans = self.list.compactMap({ $0 as? Fan })
        let fanCount = max(1, fans.count)
        let defaultMaxRPM = Int(fans.map(\.maxSpeed).max() ?? 7000)
        _ = ProfileStore.shared.createCustomProfile(fanCount: fanCount,
                                                    defaultMaxRPM: defaultMaxRPM)
        NotificationCenter.default.post(name: .fanProfileChanged, object: nil)
    }

    private func refreshDriversChecklist() {
        let profile = ProfileStore.shared.activeProfile()
        let selected = Set(profile?.drivers.map(\.key) ?? [])
        self.driversDataSource.selected = selected
        let allTemps: [(String, String)] = self.list
            .filter { $0.type == .temperature }
            .map { ($0.key, $0.name) }
        self.driversDataSource.allSensors = allTemps
        self.driversTable?.reloadData()
    }

    private func persistDriverEdits(_ keys: [String]) {
        var profiles = ProfileStore.shared.loadProfiles()
        guard let activeID = ProfileStore.shared.activeProfileID,
              let idx = profiles.firstIndex(where: { $0.id == activeID }) else { return }
        if profiles[idx].isBuiltIn {
            var copy = profiles[idx]
            copy.id = UUID()
            copy.isBuiltIn = false
            copy.name = profiles[idx].name + " (custom)"
            copy.drivers = keys.map { DriverSensor(key: $0) }
            profiles.append(copy)
            ProfileStore.shared.activeProfileID = copy.id
        } else {
            profiles[idx].drivers = keys.map { DriverSensor(key: $0) }
        }
        ProfileStore.shared.saveProfiles(profiles)
        NotificationCenter.default.post(name: .fanProfileChanged, object: nil)
        self.reloadProfilePicker()
    }

    @objc private func commitOffset(_ sender: NSTextField) {
        let v = max(0, min(1000, Int(sender.stringValue) ?? 50))
        sender.stringValue = String(v)
        self.editActiveProfile { $0.fanOffsetRPM = v }
    }
    @objc private func commitHysteresis(_ sender: NSTextField) {
        let v = max(0.5, min(10, Double(sender.stringValue) ?? 2.0))
        sender.stringValue = String(v)
        self.editActiveProfile { $0.hysteresisC = v }
    }
    @objc private func commitThreshold(_ sender: NSTextField) {
        let v = max(50, min(500, Int(sender.stringValue) ?? 150))
        sender.stringValue = String(v)
        self.editActiveProfile { $0.deltaRpmThreshold = v }
    }

    private func editActiveProfile(_ mutate: (inout FanProfile) -> Void) {
        var profiles = ProfileStore.shared.loadProfiles()
        guard let activeID = ProfileStore.shared.activeProfileID,
              let idx = profiles.firstIndex(where: { $0.id == activeID }) else { return }
        if profiles[idx].isBuiltIn {
            var copy = profiles[idx]
            copy.id = UUID()
            copy.isBuiltIn = false
            copy.name = profiles[idx].name + " (custom)"
            mutate(&copy)
            profiles.append(copy)
            ProfileStore.shared.activeProfileID = copy.id
        } else {
            mutate(&profiles[idx])
        }
        ProfileStore.shared.saveProfiles(profiles)
        NotificationCenter.default.post(name: .fanProfileChanged, object: nil)
        self.reloadProfilePicker()
    }

    @objc private func addPoint() {
        var pts = self.pointsDataSource.points
        let lastTemp = pts.last?.tempC ?? 50
        pts.append(CurvePoint(tempC: lastTemp + 5, rpm: 3000))
        pts.sort { $0.tempC < $1.tempC }
        self.pointsDataSource.points = pts
        self.pointsTable?.reloadData()
        self.persistCurveEdits()
    }

    @objc private func removePoint() {
        guard let row = self.pointsTable?.selectedRow, row >= 0,
              self.pointsDataSource.points.count > 2 else { return }
        self.pointsDataSource.points.remove(at: row)
        self.pointsTable?.reloadData()
        self.persistCurveEdits()
    }

    private func persistCurveEdits() {
        var profiles = ProfileStore.shared.loadProfiles()
        guard let activeID = ProfileStore.shared.activeProfileID,
              let idx = profiles.firstIndex(where: { $0.id == activeID }) else { return }
        if profiles[idx].isBuiltIn {
            // Editing a built-in: duplicate first.
            var copy = profiles[idx]
            copy.id = UUID()
            copy.isBuiltIn = false
            copy.name = profiles[idx].name + " (custom)"
            copy.points = self.pointsDataSource.points
            profiles.append(copy)
            ProfileStore.shared.activeProfileID = copy.id
        } else {
            profiles[idx].points = self.pointsDataSource.points
        }
        ProfileStore.shared.saveProfiles(profiles)
        NotificationCenter.default.post(name: .fanProfileChanged, object: nil)
        self.reloadProfilePicker()
    }

    @objc private func duplicateProfile() {
        guard let original = ProfileStore.shared.activeProfile() else { return }
        let fans = self.list.compactMap({ $0 as? Fan })
        let fanCount = max(1, fans.count)
        let defaultMaxRPM = Int(fans.map(\.maxSpeed).max() ?? 7000)
        _ = ProfileStore.shared.duplicateProfile(original,
                                                 fanCount: fanCount,
                                                 defaultMaxRPM: defaultMaxRPM)
        self.reloadProfilePicker()
        self.refreshCurveEditor()
        NotificationCenter.default.post(name: .fanProfileChanged, object: nil)
    }

    @objc private func deleteProfile() {
        var profiles = ProfileStore.shared.loadProfiles()
        guard let activeID = ProfileStore.shared.activeProfileID,
              let idx = profiles.firstIndex(where: { $0.id == activeID }),
              !profiles[idx].isBuiltIn else { return }
        profiles.remove(at: idx)
        ProfileStore.shared.saveProfiles(profiles)
        ProfileStore.shared.activeProfileID = profiles.first?.id
        self.reloadProfilePicker()
        self.refreshCurveEditor()
        NotificationCenter.default.post(name: .fanProfileChanged, object: nil)
    }

    fileprivate final class DriversTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var allSensors: [(key: String, name: String)] = []
        var selected: Set<String> = []
        var onToggle: (Set<String>) -> Void = { _ in }

        func numberOfRows(in t: NSTableView) -> Int { allSensors.count }

        func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
            guard row < allSensors.count else { return nil }
            let s = allSensors[row]
            let cb = NSButton(checkboxWithTitle: "\(s.name) (\(s.key))",
                              target: self,
                              action: #selector(self.toggle(_:)))
            cb.tag = row
            cb.state = selected.contains(s.key) ? .on : .off
            return cb
        }

        @objc fileprivate func toggle(_ sender: NSButton) {
            guard sender.tag < allSensors.count else { return }
            let key = allSensors[sender.tag].key
            if sender.state == .on { selected.insert(key) } else { selected.remove(key) }
            onToggle(selected)
        }
    }

    fileprivate final class CurvePointsTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var points: [CurvePoint] = []
        var onEdit: ([CurvePoint]) -> Void = { _ in }

        func numberOfRows(in tableView: NSTableView) -> Int { points.count }

        func tableView(_ tableView: NSTableView,
                       objectValueFor tableColumn: NSTableColumn?,
                       row: Int) -> Any? {
            guard let id = tableColumn?.identifier.rawValue, row < points.count else { return nil }
            let pt = points[row]
            switch id {
            case "temp": return pt.tempC
            case "rpm":  return pt.rpm
            default:     return nil
            }
        }

        func tableView(_ tableView: NSTableView,
                       setObjectValue object: Any?,
                       for tableColumn: NSTableColumn?,
                       row: Int) {
            guard let id = tableColumn?.identifier.rawValue, row < points.count else { return }
            switch id {
            case "temp":
                if let s = object as? String, let v = Double(s) { points[row].tempC = v }
                else if let v = object as? Double { points[row].tempC = v }
            case "rpm":
                if let s = object as? String, let v = Int(s) { points[row].rpm = v }
                else if let v = object as? Int { points[row].rpm = v }
            default: break
            }
            points.sort { $0.tempC < $1.tempC }
            onEdit(points)
        }
    }
}
