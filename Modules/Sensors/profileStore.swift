//
//  profileStore.swift
//  Sensors
//
//  Created on 08/06/2026.
//

import Foundation
import Kit

/// Persistence layer for fan curve profiles. Backs onto UserDefaults via `Store.shared`.
///
/// In daemon mode (`fanctl_daemonMode` flag set by `AppDelegate` after the v2
/// helper probe) every write also mirrors out to the helper via XPC so the
/// daemon's `HelperProfileStore` stays in sync. The UserDefaults cache
/// remains the source of truth for app-side UI — the daemon has its own
/// on-disk JSON at `/Library/Application Support/Stats/`.
public final class ProfileStore {
    public static let shared = ProfileStore()

    private let profilesKey = "fanctl_profiles"
    private let activeKey   = "fanctl_activeProfile"

    public init() {}

    private var daemonMode: Bool {
        Store.shared.bool(key: "fanctl_daemonMode", defaultValue: false)
    }

    public func loadProfiles() -> [FanProfile] {
        guard let data = Store.shared.data(key: profilesKey) else { return [] }
        return (try? JSONDecoder().decode([FanProfile].self, from: data)) ?? []
    }

    public func saveProfiles(_ profiles: [FanProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        Store.shared.set(key: profilesKey, value: data)
        if self.daemonMode {
            SMCHelper.shared.saveProfilesJSON(data) { err in
                if let err { error("daemon saveProfilesJSON failed: \(err)") }
            }
        }
    }

    public var activeProfileID: UUID? {
        get {
            let raw = Store.shared.string(key: activeKey, defaultValue: "")
            return raw.isEmpty ? nil : UUID(uuidString: raw)
        }
        set {
            Store.shared.set(key: activeKey, value: newValue?.uuidString ?? "")
            if self.daemonMode {
                // Resolve the UUID against the just-saved profile list and
                // push the full FanProfile to the daemon. nil / unresolved =
                // clear (Apple Auto firmware fallback). Encoded payload is a
                // single FanProfile, matching `Helper.setActiveProfileJSON`'s
                // empty-Data sentinel for clear.
                if let newValue,
                   let active = self.loadProfiles().first(where: { $0.id == newValue }),
                   let data = try? JSONEncoder().encode(active) {
                    SMCHelper.shared.setActiveProfileJSON(data) { err in
                        if let err { error("daemon setActiveProfileJSON failed: \(err)") }
                    }
                } else {
                    SMCHelper.shared.setActiveProfileJSON(Data()) { _ in }
                }
            }
        }
    }

    /// Fan curves are always active. The "disable" semantic is achieved by
    /// activating the built-in "Apple Auto" profile (empty points → controller
    /// relinquishes managed fans back to firmware automatic mode).
    /// Property kept as a settable noop for backward compat with tests.
    public var enabled: Bool {
        get { true }
        set { _ = newValue }
    }

    public func activeProfile() -> FanProfile? {
        guard let id = activeProfileID else { return nil }
        return loadProfiles().first { $0.id == id }
    }

    /// Duplicates `source` into a new editable profile, persists it, and makes
    /// it the active profile. Returns the freshly created copy.
    ///
    /// Apple Auto carries an empty `points` array (the firmware-fallback
    /// semantic) — duplicating it as-is would give the user a curveless
    /// profile to start from, which is hostile. Instead, when the source has
    /// no points we seed from the built-in Balanced profile so the user has
    /// a sensible curve to tweak. Drivers follow the same fallback.
    /// Creates a brand new editable profile seeded from the built-in Balanced
    /// curve (or the first non-empty profile if Balanced is missing), assigns
    /// a unique "Custom N" name, persists it, and makes it active.
    ///
    /// Used by the in-Settings "+ New profile" affordance. Returns the freshly
    /// created profile.
    @discardableResult
    public func createCustomProfile(fanCount: Int = 1,
                                    defaultMaxRPM: Int = 7000) -> FanProfile {
        let existing = self.loadProfiles()
        let builtIns = FanProfile.builtIns(fanCount: fanCount,
                                           defaultMaxRPM: defaultMaxRPM)
        let template = existing.first(where: { $0.name == "Balanced" })
            ?? existing.first(where: { !$0.points.isEmpty })
            ?? builtIns.first(where: { $0.name == "Balanced" })
            ?? builtIns.first
        guard let src = template else {
            // No template anywhere — return a minimal placeholder so the
            // caller doesn't crash on an Optional unwrap. Realistically
            // unreachable because builtIns is non-empty by construction.
            let placeholder = FanProfile(name: "Custom 1",
                                         drivers: [],
                                         points: [])
            var profiles = existing
            profiles.append(placeholder)
            self.saveProfiles(profiles)
            self.activeProfileID = placeholder.id
            return placeholder
        }

        let names = Set(existing.map(\.name))
        var n = 1
        var name = "Custom \(n)"
        while names.contains(name) { n += 1; name = "Custom \(n)" }

        let fresh = FanProfile(
            id: UUID(),
            name: name,
            isBuiltIn: false,
            drivers: src.drivers,
            points: src.points,
            fanOffsetRPM: src.fanOffsetRPM,
            hysteresisC: src.hysteresisC,
            deltaRpmThreshold: src.deltaRpmThreshold
        )
        var profiles = existing
        profiles.append(fresh)
        self.saveProfiles(profiles)
        self.activeProfileID = fresh.id
        return fresh
    }

    /// Restore the profile with `id` to its built-in factory defaults. Returns
    /// true if the stored profile is a built-in whose name matches one of
    /// `FanProfile.builtIns(...)` (Apple Auto / Quiet / Linear / Balanced /
    /// Aggressive / Performance) and the reset was performed, false otherwise
    /// (id missing, not built-in, or name doesn't match a known template).
    ///
    /// Matching is by `isBuiltIn` + name because `FanProfile.builtIns(...)`
    /// generates fresh UUIDs every call (only Apple Auto has a stable UUID via
    /// `appleAutoID`). Names within the built-in set are unique.
    ///
    /// The stored profile's `name` and `id` are preserved (user-rename
    /// respected, UUID stable so active-profile selection survives); every
    /// other field (points, drivers, fanOffsetRPM, hysteresisC,
    /// deltaRpmThreshold, isBuiltIn) is replaced with the factory value.
    /// Posts `.fanProfileChanged` so the editor and popup reload.
    @discardableResult
    public func resetToDefault(_ id: UUID,
                               fanCount: Int = 1,
                               defaultMaxRPM: Int = 7000) -> Bool {
        var all = self.loadProfiles()
        guard let idx = all.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let existing = all[idx]
        guard existing.isBuiltIn else { return false }
        let defaults = FanProfile.builtIns(fanCount: fanCount,
                                           defaultMaxRPM: defaultMaxRPM)
        // Apple Auto has a stable UUID — match by id first for it; the rest
        // match by name (unique within built-ins).
        let template = defaults.first(where: { $0.id == id })
            ?? defaults.first(where: { $0.name == existing.name })
        guard let template else { return false }
        let reset = FanProfile(
            id: existing.id,
            name: existing.name,
            isBuiltIn: template.isBuiltIn,
            drivers: template.drivers,
            points: template.points,
            fanOffsetRPM: template.fanOffsetRPM,
            hysteresisC: template.hysteresisC,
            deltaRpmThreshold: template.deltaRpmThreshold
        )
        all[idx] = reset
        self.saveProfiles(all)
        NotificationCenter.default.post(name: .fanProfileChanged, object: nil)
        return true
    }

    @discardableResult
    public func duplicateProfile(_ source: FanProfile,
                                 fanCount: Int = 1,
                                 defaultMaxRPM: Int = 7000) -> FanProfile {
        var copy = source
        copy.id = UUID()
        copy.isBuiltIn = false
        copy.name = source.name + " (copy)"
        if copy.points.isEmpty || copy.drivers.isEmpty {
            let builtIns = FanProfile.builtIns(fanCount: fanCount,
                                               defaultMaxRPM: defaultMaxRPM)
            let example = builtIns.first(where: { $0.name == "Balanced" })
            if copy.points.isEmpty, let pts = example?.points {
                copy.points = pts
            }
            if copy.drivers.isEmpty, let drv = example?.drivers {
                copy.drivers = drv
            }
        }
        var profiles = loadProfiles()
        profiles.append(copy)
        saveProfiles(profiles)
        activeProfileID = copy.id
        return copy
    }
}

extension ProfileStore {
    /// On first launch (no profiles persisted), seed built-ins and activate Aggressive.
    /// No-op if profiles already exist.
    public func bootstrapIfNeeded(fanCount: Int, defaultMaxRPM: Int) {
        let existing = loadProfiles()
        guard existing.isEmpty else { return }
        let builtIns = FanProfile.builtIns(fanCount: fanCount,
                                           defaultMaxRPM: defaultMaxRPM)
        saveProfiles(builtIns)
        if let aggressive = builtIns.first(where: { $0.name == "Aggressive" }) {
            activeProfileID = aggressive.id
        }
    }

    /// When daemon mode is on, ensure the daemon has the same profile list and
    /// active selection that the app has cached locally. Called once at app
    /// launch after `fanctl_daemonMode` is confirmed true.
    ///
    /// After `make uninstall-helper` + reinstall, the daemon's
    /// `/Library/Application Support/Stats/{profiles,active}.json` are empty
    /// and it sits in Apple Auto / relinquish mode until the user touches the
    /// UI (which triggers `saveProfiles` → push). This bootstrap closes that
    /// gap so a freshly-installed daemon picks up the app's last selection
    /// immediately on launch.
    ///
    /// Edge cases:
    /// - Daemon never responds to `getStatusJSON` → `data == nil` → treated as
    ///   empty; bootstrap runs. Safe (no-op if app also has no profiles).
    /// - App has no profiles locally (truly fresh install before
    ///   `bootstrapIfNeeded`) → skip; daemon stays in relinquish mode until
    ///   the user picks a profile, at which point the normal push path fires.
    /// - Daemon already has a profile → do nothing; the regular write-through
    ///   path in `saveProfiles` / `activeProfileID` keeps it in sync.
    public func bootstrapDaemonIfNeeded() {
        guard self.daemonMode else { return }
        SMCHelper.shared.getStatusJSON { [weak self] data in
            guard let self = self else { return }
            let hasDaemonProfile: Bool
            if let data = data,
               let status = try? JSONDecoder().decode(HelperStatus.self, from: data),
               status.activeProfileID != nil {
                hasDaemonProfile = true
            } else {
                hasDaemonProfile = false
            }
            guard !hasDaemonProfile else { return }

            let profiles = self.loadProfiles()
            guard !profiles.isEmpty else { return }
            if let payload = try? JSONEncoder().encode(profiles) {
                SMCHelper.shared.saveProfilesJSON(payload) { err in
                    if let err { error("daemon bootstrap saveProfilesJSON failed: \(err)") }
                }
            }
            if let active = self.activeProfile(),
               let payload = try? JSONEncoder().encode(active) {
                SMCHelper.shared.setActiveProfileJSON(payload) { err in
                    if let err { error("daemon bootstrap setActiveProfileJSON failed: \(err)") }
                }
                info("Bootstrapped daemon: \(profiles.count) profiles, active=\(active.name)")
            }
        }
    }
}
