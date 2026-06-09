# Daemon Refactor: Helper-Owned Fan Curve Control

**Date:** 2026-06-09
**Target:** personal fork of `exelban/stats` (post v3.1.0-ank.1)
**Scope:** move fan curve management from the in-app `FanCurveController`
into the privileged helper daemon so fans stay managed when Stats.app is
quit.

## Motivation

Phase 1-5 of the daemon refactor migrated the entire fan-curve tick loop
from the Stats menubar app into the existing SMJobBless helper. Result:

| State | RAM before | RAM after |
|---|---|---|
| Stats.app running, idle | ~131 MB | ~131 MB |
| Stats.app quit, helper managing fans | n/a (fans reverted to Apple Auto) | ~12 MB |
| Stats.app running, daemon mode (helper does the work) | ~131 MB | ~110 MB |

The user wants programmable fan curves without keeping a 130 MB menubar
app resident at all times. The privileged helper already exists for SMC
writes (was a 2 MB stub before this refactor). Adding the curve logic
there lets the user quit Stats.app entirely while fans stay under curve
control with a ~12 MB resident-set helper.

## Non-goals

- Removing the in-app `FanCurveController` in this release. It stays as
  the fallback for legacy v1 helpers and as the test-driven reference
  implementation.
- A separate config UI in the helper. The helper has no UI; profiles are
  pushed from Stats.app via XPC and persisted to disk.
- Upstream PR. Personal fork.
- Intel Mac support (out of scope, same as v3.1.0).

## Architecture (post-refactor)

```
┌──────────────────────────────────────────────────────────────────────┐
│ Stats.app (menubar UI)                                               │
│                                                                       │
│  ┌─────────────────────┐  ┌──────────────────────────────────────┐  │
│  │ AppDelegate         │  │ Modules/Sensors                       │  │
│  │  - protocolVersion  │  │  - FanCurveController (FALLBACK only) │  │
│  │    probe at launch  │  │  - skipped if fanctl_daemonMode=true  │  │
│  │  - reinstall prompt │  │  - profile editor UI                  │  │
│  └────────┬────────────┘  └──────────┬───────────────────────────┘  │
└───────────┼─────────────────────────┼────────────────────────────────┘
            │                         │
            │ XPC (NSXPCConnection, machServiceName)
            │   protocolVersion / setActiveProfileJSON / saveProfilesJSON
            │   setOverride / getStatusJSON / setEnabled / version / install
            │                         │
            ▼                         ▼
┌──────────────────────────────────────────────────────────────────────┐
│ /Library/PrivilegedHelperTools/eu.exelban.Stats.SMC.Helper           │
│ (LaunchDaemon, KeepAlive, runs as root)                              │
│                                                                       │
│  ┌──────────────────────┐  ┌─────────────────────────────────────┐  │
│  │ DaemonRunloop        │  │ FanCore (shared with Stats.app)     │  │
│  │  - 2 s tick          │  │  - FanCurveEngine.interpolate       │  │
│  │  - reads sensors     │─►│  - FanProfile / CurvePoint          │  │
│  │  - calls engine      │  │  - HelperStatus snapshot            │  │
│  │  - writes SMC        │  │  - TakeoverStore (in-memory)        │  │
│  └────────┬─────────────┘  └─────────────────────────────────────┘  │
│           │                                                           │
│  ┌────────▼──────────┐  ┌─────────────────┐  ┌──────────────────┐   │
│  │ HelperSensorReader│  │ SMCFanWriter    │  │ PersistentProfile │   │
│  │ (IOReport+IOHID,  │  │ (SMC kext calls)│  │ Store             │   │
│  │  bridge.h/reader.m│  └─────────────────┘  │ /Library/App Sup/ │   │
│  └───────────────────┘                       │  Stats/active.json│   │
│                                              └──────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘
```

Helper is self-contained: it reads sensors via IOReport/IOHID without
the app, interpolates the curve via the shared `FanCore` Swift package,
and writes SMC in-process. The app's role shrinks to (a) profile editor
UI and (b) pushing the active profile JSON over XPC.

## XPC protocol v2 surface

`SMC/Helper/protocol.swift` defines `HelperProtocol` with both legacy v1
methods (kept for backward compat) and the v2 surface used by the daemon:

```swift
// v1 (legacy, retained)
func setFanMode(id: Int, mode: Int, completion: ...)
func setFanSpeed(id: Int, value: Int, completion: ...)
func resetFanControl(completion: ...)
func version(completion: ...)            // CFBundleShortVersionString
func uninstall()

// v2 (new — Phase 4)
func protocolVersion(completion: @escaping (Int) -> Void)
func setActiveProfileJSON(_ data: Data, completion: ...)
func saveProfilesJSON(_ data: Data, completion: ...)
func setOverride(rawMode: Int, fanId: Int, value: Int, completion: ...)
func getStatusJSON(completion: @escaping (Data?) -> Void)
func setEnabled(_ enabled: Bool, completion: ...)
```

`protocolVersion` is the discovery key: a v1 helper doesn't implement
it (returns 0/nil/timeout); a v2 helper returns `2`. The app uses this
to decide whether to enable in-app control or defer to the daemon.

## Persistent files

| Path | Owner | Purpose |
|---|---|---|
| `/Library/PrivilegedHelperTools/eu.exelban.Stats.SMC.Helper` | root | helper binary |
| `/Library/LaunchDaemons/eu.exelban.Stats.SMC.Helper.plist` | root | launchd registration, `KeepAlive = true` |
| `/Library/Application Support/Stats/active.json` | root | active profile JSON (single source of truth post-handoff) |
| `/Library/Application Support/Stats/profiles.json` | root | full profile list (for editor sync across reboots) |

The helper writes both files atomically. Stats.app pushes them over
XPC; the helper persists them so a reboot without Stats.app running
still resumes the active profile.

## Migration path: v1 → v2

App launches → `AppDelegate.applicationDidFinishLaunching` calls
`probeHelperAndMaybePromptMigration()`. Flow:

1. Read `SMCHelper.shared.isInstalled` synchronously (checks
   `/Library/PrivilegedHelperTools/...`).
2. Issue async XPC `protocolVersion` call. Race it against a 3 s timer.
3. Result handling (whichever fires first wins; the other is ignored
   via a `settled` guard):
   - `version >= 2` → cache `Store.fanctl_daemonMode = true`, done.
   - `version < 2` or timeout or helper missing → cache flag = false,
     show one-time NSAlert: "Helper update required" (or "Install
     helper" if missing entirely).
4. Alert buttons:
   - **"Reinstall Helper" / "Install Helper"** → call
     `SMCHelper.shared.install(completion:)` (existing SMJobBless flow,
     prompts for admin password). On success, wait 2 s for launchd to
     load the new plist, re-probe, and update the cache.
   - **"Skip"** → cache `daemonMode = false`. In-app
     `FanCurveController` runs the fallback path.
5. `didPromptForReinstall` static flag prevents the alert from showing
   twice in one session if both the XPC completion and the 3 s timer
   fire late.

The cached `fanctl_daemonMode` is read by `Sensors.init` on the *next*
launch — meaning the first launch after a successful reinstall still
uses the in-app controller. This is the simplicity trade-off from
Phase 5: no synchronous probe at module init time, no race.

## Apple-firmware override failsafe

Moved into the daemon. The 3-tick override-streak detector (was
`FanCurveController.appleOverridden`) now lives in
`HelperTakeoverStore`. In-memory only; not persisted. If the daemon
detects Apple's firmware reverting its `.forced` writes back to
`.automatic` for 3 consecutive ticks on a given fan id, it stops
issuing writes for that fan for the rest of the session. Cleared by
the next `setActiveProfileJSON` call (user picker action) or a daemon
restart (launchd `KeepAlive` re-spawn).

## What changed, file by file (cumulative across Phases 1-6)

| File | Change |
|---|---|
| `FanCore/` (NEW) | 12 pure-Swift files compiled into both `Sensors` and the Helper. `FanCurveEngine`, `FanProfileBuiltins`, `HelperStatus`, `TakeoverStore`, `EngineSnapshot`, `Sensor`, `Types`, `FanCoreClock`, `FanCoreLogger`, `FanCurve`, `FanSnapshot`, `FanCurveHelperProtocol`. |
| `SMC/Helper/` | gained 8 new files: `HelperSensorReader.swift`, `SMCFanWriter.swift`, `PersistentProfileStore.swift`, `HelperTakeoverStore.swift`, `HelperLogger.swift`, `DaemonRunloop.swift`, `bridge.h`/`reader.m` (Obj-C IOHID bridge), `HelperBridge.h` (Swift-importable C interop). |
| `SMC/Helper/protocol.swift` | v2 method surface added on `HelperProtocol`. |
| `SMC/Helper/Launchd.plist` | `KeepAlive = true` so daemon survives Stats.app quit and re-spawns on crash. |
| `Kit/helpers.swift` | `SMCHelper.shared` gains v2 wrappers (`protocolVersion`, `setActiveProfileJSON`, `saveProfilesJSON`, `setOverride`, `getStatusJSON`, `setEnabled`). |
| `Modules/Sensors/main.swift` | `Sensors.init` reads `fanctl_daemonMode`; if true, skips constructing `FanCurveController`. |
| `Modules/Sensors/profileStore.swift` | When daemon mode is on, profile writes also call `setActiveProfileJSON`/`saveProfilesJSON`. |
| `Modules/Sensors/popup.swift` | Picker actions hop through `SMCHelper.setActiveProfileJSON` / `setOverride` instead of touching SMC directly when daemon mode is on. |
| `Stats/AppDelegate.swift` | Probe + migration prompt (this phase). |
| `Makefile` | `uninstall-helper`, `install-helper` targets (this phase). |
| `Tests/Sensors.swift` | 118 tests covering FanCore engine, in-app controller fallback, profile (de)serialization, XPC protocol shape. |

## Tests

`xcodebuild -scheme Stats -destination 'platform=macOS,arch=arm64' \
  -only-testing:Tests/SensorsTests \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO test`

→ `Executed 118 tests, 0 failures`.

The helper itself is not unit-tested (XPC + SMC kext calls require root
and break test isolation); it is validated manually by smoke-testing
profile push → SMC RPM read-back, plus the `make local` install loop.

## Rollback

If the daemon refactor causes problems in production:

```bash
make uninstall-helper                  # purge daemon + persistent state
git checkout v3.1.0-ank.1               # last in-app-only release tag
make local                              # rebuild + reinstall app
# Next app launch: SMJobBless prompt to install the v1 helper.
```

`make uninstall-helper` is idempotent and safe to re-run.

## Out of scope (future work)

- Helper-side schedule (cron-style profile switching).
- Helper-side log file at `/var/log/Stats.helper.log` (currently logs
  to os_log only).
- Removing the in-app `FanCurveController` entirely after one release
  cycle of dual-stack operation (likely v4.1.0-ank.1).
- Self-signed Developer ID flow for distributing the helper outside the
  current ad-hoc install (would unlock notarization).
