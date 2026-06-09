//
//  PersistentProfileStore.swift
//  Helper
//
//  Created on 2026-06-09.
//
//  JSON-backed profile store living at /Library/Application Support/Stats/.
//  The daemon owns this; the app (Phase 5) will write the same files via XPC
//  so the daemon picks up changes on its next tick. Pre-Phase-5 the daemon
//  only READS — `active.json` may legitimately be absent (Apple Auto mode)
//  and `profiles.json` may be empty (no curve profiles configured).
//

import Foundation

final class PersistentProfileStore {
    static let dir = URL(fileURLWithPath: "/Library/Application Support/Stats", isDirectory: true)
    static let activeURL = dir.appendingPathComponent("active.json")
    static let profilesURL = dir.appendingPathComponent("profiles.json")

    init() {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o755])
    }

    func loadActive() -> FanProfile? {
        guard let data = try? Data(contentsOf: Self.activeURL) else { return nil }
        return try? JSONDecoder().decode(FanProfile.self, from: data)
    }

    func setActive(_ profile: FanProfile?) {
        if let profile = profile, let data = try? JSONEncoder().encode(profile) {
            try? data.write(to: Self.activeURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: Self.activeURL)
        }
    }

    func loadAll() -> [FanProfile] {
        guard let data = try? Data(contentsOf: Self.profilesURL) else { return [] }
        return (try? JSONDecoder().decode([FanProfile].self, from: data)) ?? []
    }

    func saveAll(_ profiles: [FanProfile]) {
        if let data = try? JSONEncoder().encode(profiles) {
            try? data.write(to: Self.profilesURL, options: .atomic)
        }
    }
}
