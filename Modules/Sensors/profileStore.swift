//
//  profileStore.swift
//  Sensors
//
//  Created on 08/06/2026.
//

import Foundation
import Kit

/// Persistence layer for fan curve profiles. Backs onto UserDefaults via `Store.shared`.
public final class ProfileStore {
    public static let shared = ProfileStore()

    private let profilesKey = "fanctl_profiles"
    private let activeKey   = "fanctl_activeProfile"

    public init() {}

    public func loadProfiles() -> [FanProfile] {
        guard let data = Store.shared.data(key: profilesKey) else { return [] }
        return (try? JSONDecoder().decode([FanProfile].self, from: data)) ?? []
    }

    public func saveProfiles(_ profiles: [FanProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        Store.shared.set(key: profilesKey, value: data)
    }

    public var activeProfileID: UUID? {
        get {
            let raw = Store.shared.string(key: activeKey, defaultValue: "")
            return raw.isEmpty ? nil : UUID(uuidString: raw)
        }
        set {
            Store.shared.set(key: activeKey, value: newValue?.uuidString ?? "")
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
