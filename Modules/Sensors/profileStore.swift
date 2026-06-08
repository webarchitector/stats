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
    private let enabledKey  = "fanctl_enabled"

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

    public var enabled: Bool {
        get { Store.shared.bool(key: enabledKey, defaultValue: false) }
        set { Store.shared.set(key: enabledKey, value: newValue) }
    }

    public func activeProfile() -> FanProfile? {
        guard let id = activeProfileID else { return nil }
        return loadProfiles().first { $0.id == id }
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
