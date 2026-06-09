//
//  HelperTakeoverStore.swift
//  Helper
//
//  Created on 2026-06-09.
//
//  TakeoverStore implementation for the daemon. The app-side equivalent reads
//  `Fan.customMode` via the Store; the daemon doesn't share the user's
//  defaults domain, so it keeps its own JSON file at
//  /Library/Application Support/Stats/takeover.json mapping fanID → bool.
//  The bool means "user took over this fan — engine must not write SMC".
//

import Foundation

final class HelperTakeoverStore: TakeoverStore {
    static let url = URL(fileURLWithPath: "/Library/Application Support/Stats/takeover.json")
    private var state: [Int: Bool] = [:]
    private let lock = NSLock()

    init() {
        if let data = try? Data(contentsOf: Self.url),
           let map = try? JSONDecoder().decode([String: Bool].self, from: data) {
            for (k, v) in map { if let id = Int(k) { state[id] = v } }
        }
    }

    func userTookOver(fan: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return state[fan] ?? false
    }

    func setStatsManaged(fan: Int) { setUserTakeover(fan: fan, value: false) }

    // Released by Stats — the engine no longer owns this fan, and the user
    // never claimed it either, so the takeover flag clears.
    func setReleased(fan: Int) { setUserTakeover(fan: fan, value: false) }

    func setUserTookOver(fan: Int) { setUserTakeover(fan: fan, value: true) }

    private func setUserTakeover(fan: Int, value: Bool) {
        // Write while holding the lock so two concurrent setters can't reorder
        // their file writes relative to their in-memory updates (last-writer-
        // wins on the file would otherwise be able to persist a stale flag).
        // Calls are rare (user picker actions), so file I/O under the lock is
        // not a contention concern.
        lock.lock()
        defer { lock.unlock() }
        state[fan] = value
        let snapshot = state.reduce(into: [String: Bool]()) { $0[String($1.key)] = $1.value }
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: Self.url, options: .atomic)
        }
    }
}
