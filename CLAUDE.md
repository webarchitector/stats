# CLAUDE.md

## Before Starting

Personal fork of `exelban/stats` extended with **Fan Curve Control** (see `docs/superpowers/specs/2026-06-08-stats-fan-curve-design.md`). Before non-trivial changes to fan-related code, re-read that spec.

Key modified files relative to upstream:
- `SMC/smc.swift` — added `FanMode.curve = 100` case and `isStatsControlled` computed property
- `Modules/Sensors/values.swift` — added `CurvePoint`, `DriverSensor`, `FanProfile` value types
- `Modules/Sensors/fanCurve.swift` — `FanCurve.interpolate`, `FanCurve.effectiveTemperature`, `FanProfile.builtIns` (NEW)
- `Modules/Sensors/profileStore.swift` — persistence layer for profiles (NEW)
- `Modules/Sensors/fanController.swift` — `FanCurveController` + `FanCurveHelper` protocol + `SMCHelperAdapter` (NEW)
- `Modules/Sensors/curveGraph.swift` — mini graph view (NEW)
- `Modules/Sensors/settings.swift` — Fan Curves section (master toggle, profile picker, curve editor, driver checklist, graph, offset, advanced)
- `Modules/Sensors/main.swift` — wires controller into module lifecycle (init bootstrap, reader callback, willTerminate)
- `Modules/Sensors/popup.swift` — predicates excluded `.curve` from raw SMC forwarding
- `SMC/main.swift` — CLI rejects writing `mode=100` (Stats-internal sentinel) to SMC
- `Kit/types.swift` — added `.fanProfileChanged` and `.fanControlEnabledChanged` notification names
- `Tests/Sensors.swift` — 79-test suite covering all of the above (NEW)
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
- New `Store.shared` keys use the `fanctl_` prefix to be greppable (`fanctl_enabled`, `fanctl_profiles`, `fanctl_activeProfile`).
- All XPC calls go through `SMCHelper.shared` (or the `FanCurveHelper` protocol's `SMCHelperAdapter` shim). Don't construct `NSXPCConnection` directly.
- Tests in `Tests/Sensors.swift` (class `SensorsTests: XCTestCase`). Use `@testable import Sensors` + `import Kit`. Note: `private typealias FanMode = Kit.FanMode` is required because `Sensors` class shadows the module name.

## Intentional Decisions — Do NOT "Fix" These

- `FanMode.curve = 100` is **not** a real SMC mode. SMC only understands 0/1/3. When `customMode == .curve`, the controller sets the actual SMC mode to `.forced` and writes RPM periodically; the `.curve` value is a Stats-level marker stored in `Store.shared`. `Modules/Sensors/popup.swift` and `SMC/main.swift` have guards to prevent the sentinel from ever reaching hardware.
- `FanCurveHelper` protocol exists for testability. The real implementation `SMCHelperAdapter` is a thin shim over `SMCHelper.shared`; don't combine them.
- Profile model uses a **master curve + per-fan offset**, not N independent curves per fan. This was a deliberate UX simplification.
- Built-in profiles are protected from deletion. Editing a built-in auto-creates a `(custom)` copy via `persistCurveEdits` / `persistDriverEdits` / `editActiveProfile`.
- `FanCurve.effectiveTemperature` uses raw `Sensor.value` (always Celsius), NOT `Sensor.localValue` (locale-converted). This was a real bug caught in spec review of Phase 2.
- `Modules/Sensors/popup.swift` predicates use `!mode.isAutomatic && !mode.isStatsControlled` so `.curve` never gets forwarded to SMC. The historical `!mode.isAutomatic`-only check would silently corrupt fan state if Stats's `.curve` mode leaks into the popup's "user manually set forced" code path.
- `Tests/Sensors.swift` uses `Store.shared.remove(_:)` to clean up between tests (NOT `UserDefaults.standard.removeObject`) because Store has an in-memory cache layer above UserDefaults.
- `FanCurveController` bootstraps profiles on FIRST tick of the reader callback, not at init — because the controller doesn't know fan count or maxSpeed at init time. The reader's first tick provides this from the `Sensors_List` snapshot.
- Crash recovery: `Sensors.init` calls `resetStaleCurveModes(...)` which iterates fan ids 0..3 and resets any fan whose stored `customMode == .curve` to `.automatic` IF Stats isn't currently configured to manage it (e.g. user disabled curves before a crash). Prevents fans stuck on a stale forced RPM.
