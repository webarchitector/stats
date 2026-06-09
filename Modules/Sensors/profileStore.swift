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
}
