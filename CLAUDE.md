# CLAUDE.md

## Before Starting

Personal fork of `exelban/stats` extended with **Fan Curve Control** (see `docs/superpowers/specs/2026-06-08-stats-fan-curve-design.md`). Before non-trivial changes to fan-related code, re-read that spec.

Key modified files relative to upstream:
- `SMC/smc.swift` — `FanMode.curve = 100` case + `isStatsControlled` (Stats-internal marker, never written to SMC)
- `Modules/Sensors/values.swift` — `CurvePoint`, `DriverSensor`, `FanProfile` value types
- `Modules/Sensors/fanCurve.swift` — `FanCurve.interpolate`, `FanCurve.effectiveTemperature`, `FanProfile.builtIns`, `FanProfile.appleAutoID` (stable UUID) (NEW)
- `Modules/Sensors/profileStore.swift` — persistence (`fanctl_profiles`, `fanctl_activeProfile` in Store). `enabled` is hard-coded true (no user toggle) (NEW)
- `Modules/Sensors/fanController.swift` — `FanCurveController` (NSLock-guarded state, runs from background `SensorsReader` thread), `FanCurveHelper` protocol, `SMCHelperAdapter` (NEW)
- `Modules/Sensors/curveGraph.swift` — mini graph NSView (NEW)
- `Modules/Sensors/settings.swift` — Fan Curves editor (drivers, points, graph, offset, advanced + Duplicate/Delete). **Active profile picker lives in popup, not Settings.**
- `Modules/Sensors/main.swift` — wires controller into module lifecycle (init bootstrap, reader callback, willTerminate, crash recovery)
- `Modules/Sensors/popup.swift` — single `ModeButtons` NSPopUpButton with profiles + Manual/Off/Max; predicates exclude `.curve` from raw SMC forwarding
- `SMC/main.swift` — CLI rejects writing `mode=100` to SMC
- `Kit/types.swift` — `.fanProfileChanged` notification name
- `Tests/Sensors.swift` — 78-test suite covering all of the above (NEW)
- `Makefile` — `make local` target (NEW)

## Codebase Index

MCP `codebase-memory` has this repo indexed as project `Users-ank-dev-stats`. Use `mcp__codebase-memory__search_code`, `get_architecture`, `trace_path` before manually exploring. `.mcp.json` at repo root wires it up automatically when Claude Code opens this directory.

## Build & Verify

```bash
# Compile only (fastest sanity check):
xcodebuild -scheme Stats -configuration Debug -destination 'platform=macOS,arch=arm64' \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build

# Run the test suite:
xcodebuild -scheme Stats -destination 'platform=macOS,arch=arm64' \
    -only-testing:Tests/SensorsTests \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO test

# Build, ad-hoc sign, install to /Applications (personal dev workflow):
make local
```

Signing flags `CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` are required because the project pins team `RP2S87B72W` with a `Developer ID Application` cert that this machine doesn't have. They tell `xcodebuild` to skip signing during build; `make local` then ad-hoc signs the bundle afterward.

## Release Builds

For personal use, only `make local`. Upstream's `make build` (archive → notarize → sign with `AC_PASSWORD` keychain profile → dmg) needs an Apple Developer account and is not configured here.

`make local` does:
- Release build with `CODE_SIGN_IDENTITY=-` (ad-hoc).
- `codesign --force --deep --sign -` on the bundle (signs nested SMC helper and LaunchAtLogin).
- Quits running Stats, removes old `/Applications/Stats.app`, copies new one.
- `xattr -cr` to strip the quarantine flag so Gatekeeper doesn't refuse the ad-hoc-signed app.

## Post-Task

After completing a feature or fix:

1. `xcodebuild -scheme Stats build` (with the signing-disable flags) — must succeed.
2. `xcodebuild -scheme Stats -destination 'platform=macOS,arch=arm64' -only-testing:Tests/SensorsTests test` — full Sensors test suite passes.
3. `make local` — produces signed app in `/Applications`.
4. (Optional) Bump `CFBundleVersion` in `Stats/Supporting Files/Info.plist` (use `make next-version`).
5. `git commit` (see commit rules below).
6. `mcp__codebase-memory__index_repository(repo_path="/Users/ank/dev/stats", mode="full")` — reindex so future sessions see new files.
7. Short status line to user: version bumped X→Y (if applicable), commit SHA, reindex done.

Don't push to upstream remote — this is a personal fork; commits stay local until explicitly pushed.

## Commit & Code-Attribution Rules

- **No `Co-Authored-By: Claude` trailers.** Same as global `~/CLAUDE.md`. Commit messages contain only what the developer wrote.
- **No "Generated with Claude" footers** in commit bodies.
- **No AI-attribution comments in code.** Files have human authorship only.
- Commit messages: English, imperative, no `feat:`/`fix:` prefixes (matches upstream style).
- One logical change = one commit.

When creating a NEW Swift file in this fork, use a minimal header like `//  Created on YYYY-MM-DD.` — don't keep "Created by Serhiy Mytrovtsiy" attribution on files you authored. For files you **modify** (not create), leave the original header intact.

## Structure Conventions

- All new fan-curve code lives in `Modules/Sensors/` next to existing fan-related logic.
- New `Notification.Name` entries go in `Kit/types.swift` next to existing ones.
- New `Store.shared` keys use the `fanctl_` prefix to be greppable (`fanctl_profiles`, `fanctl_activeProfile`).
- All XPC calls go through `SMCHelper.shared` (or the `FanCurveHelper` protocol's `SMCHelperAdapter` shim). Don't construct `NSXPCConnection` directly.
- Tests in `Tests/Sensors.swift` (class `SensorsTests: XCTestCase`). Use `@testable import Sensors` + `import Kit`. Note: `private typealias FanMode = Kit.FanMode` is required because `Sensors` class shadows the module name.

## Intentional Decisions — Do NOT "Fix" These

- **`FanMode.curve = 100` is a Stats-level sentinel**, never written to SMC. The controller sets actual SMC mode to `.forced` and writes RPM periodically; `customMode = .curve` is stored to signal "Stats is managing this fan". `popup.swift` and `SMC/main.swift` have guards preventing the sentinel from reaching hardware.
- **`FanCurveHelper` protocol exists for testability.** Real implementation `SMCHelperAdapter` is a thin shim over `SMCHelper.shared`; don't combine them. `SMCHelperAdapter.isActive()` checks helper FILE presence on disk, NOT the XPC connection state. Doing `SMCHelper.shared.isActive()` here causes a chicken-and-egg deadlock — XPC connection is lazy, only forms on first write call.
- **Profile model: master curve + per-fan offset**, not N independent curves per fan. Deliberate UX simplification.
- **Built-in profiles protected from deletion.** Editing a built-in auto-creates a `(custom)` copy via `persistCurveEdits` / `persistDriverEdits` / `editActiveProfile`.
- **Apple Auto profile has stable UUID** `00000000-0000-0000-0000-000000000A07` (`FanProfile.appleAutoID`). Lookup by UUID, not name — survives localization and user renames.
- **`FanCurve.effectiveTemperature` uses raw `Sensor.value`** (always Celsius), NOT `Sensor.localValue` (locale-converted). Real bug caught in spec review of Phase 2.
- **`popup.swift` predicates** use `!mode.isAutomatic && !mode.isStatsControlled` so `.curve` never gets forwarded to SMC.
- **`Tests/Sensors.swift` uses `Store.shared.remove(_:)`** to clean up between tests (NOT `UserDefaults.standard.removeObject`) because Store has an in-memory cache layer above UserDefaults.
- **`FanCurveController` bootstraps profiles on FIRST tick** of the reader callback, not at init — because the controller doesn't know fan count or maxSpeed at init time. Reader's first tick provides this from the `Sensors_List` snapshot.
- **`FanCurveController` is thread-locked** with `NSLock`. `SensorsReader.read()` runs on a background queue → `tick()` runs there; NSWorkspace sleep/wake observers + `.fanProfileChanged` observer run on `.main`. All mutate the same dictionaries → without the lock, concurrent read/write would crash. `tick()` holds the lock for its whole body; `shutdown()` and observers take it via `relinquishLocked()`.
- **User takeover is signaled by `Fan.customMode == .forced`**. When user picks Manual/Off/Max in popup, the callback sets `customMode = .forced`. Controller's `applyIfNeeded` and `relinquishLocked` both check this and skip the fan — never writing SMC for user-owned fans. Picking a profile back clears `customMode` (via callback(.automatic)) so controller can re-take.
- **Crash recovery**: `Sensors.init` calls `resetStaleCurveModes(...)` iterating fan ids 0..3, resetting any fan whose stored `customMode == .curve` to `.automatic` if no active profile exists. Prevents fans stuck in forced mode after a stats crash.
- **SMJobBless requirements are relaxed** (`Stats/Supporting Files/Info.plist` + `SMC/Helper/Info.plist`) to `identifier "..."` only (no `anchor apple generic` + team cert). Required for ad-hoc-signed builds to install the helper. Do NOT re-add Apple cert requirements unless you have a Developer ID signing identity.
- **Active profile picker lives in popup, NOT Settings.** Settings exposes only per-profile editing (drivers/points/graph/offset/advanced) + Duplicate/Delete. The picker is implemented as a single `NSPopUpButton` in `ModeButtons` with profiles + separator + Manual/Off/Max items. Selecting Manual/Off/Max calls `silentlyActivateAppleAuto()` (FanProfile.appleAutoID) so the controller relinquishes on next tick and doesn't overwrite the user's manual write.
- **Fan curves are ALWAYS enabled** — no master toggle. `ProfileStore.enabled` returns hardcoded `true` (kept for test compatibility). "Disable" semantic = select Apple Auto profile.
- **Apple-firmware override failsafe is IN-MEMORY only.** `FanCurveController` keeps `appleOverridden: Set<Int>` (+ `lastSetMode`, `overrideStreak`) — never persisted. If Apple's thermal firmware reverts our `.forced` write back to `.automatic` for 3 consecutive ticks, the controller stops issuing SMC writes for that fan id for the rest of the session. Cleared by `.fanProfileChanged` (user picker action) and reset on every app launch. `Store.shared.fanctl_activeProfile` is left untouched so the picker still shows the user's last selection. Per-tick SMC mode refresh lives on `Fan.smcMode` (populated in `SensorsReader.read()`); detection happens at the top of `FanCurveController.tick()` BEFORE the per-fan apply loop so this tick's writes don't bias the comparison.
- **Profile changes apply immediately.** The `.fanProfileChanged` observer caches `lastSnapshot` per tick, then on user picker action either relinquishes (Apple Auto) or re-ticks (non-Apple) synchronously — no ~1s lag waiting for next reader tick. Pre-existing bug fix: switching to Apple Auto now actually writes `.automatic` to SMC because `relinquishLocked` runs BEFORE `managedFans.removeAll()` (the old order cleared the set then iterated an empty set, leaving fans stuck in `.forced`).
