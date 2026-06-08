# Fan Curve Control for Stats (personal fork)

**Date:** 2026-06-08
**Target:** personal fork of `exelban/stats` v3.0.1
**Scope:** add temperature-driven fan curve control to the Sensors module on Apple Silicon Macs; M5 single-fan and M-Pro/M-Max dual-fan supported via the same model.

## Goal

Today's stats supports two fan modes: `automatic` (Apple firmware) and `forced` (fixed RPM). On Apple Silicon, Apple's default fan curve trades cooling for quiet, which lets the SoC reach thermal pressure under sustained loads (compile, llama.cpp, Final Cut). The user wants programmable curves: temperature → RPM, with multiple switchable profiles, applied automatically. Implementation must add ≤1 MB RAM and ≤0.1% CPU overhead on top of stats' baseline, since the entire feature exists to *reduce* heat — burning CPU to do it would defeat the purpose.

## Non-goals

- Upstream PR to exelban (this is a personal fork — we don't constrain ourselves to upstream's idioms or i18n strings).
- Removing other languages or modules from stats (out of scope; bridging C/Obj-C is necessary; Python build scripts don't ship in the binary).
- A separate daemon / headless mode (rejected by the user in favor of keeping the curve logic inside Stats.app — option X in brainstorming).
- Per-fan independent profiles (rejected in favor of one global profile that contains a master curve + per-fan offset).
- Fan control on Intel Macs (out of scope; stats already supports `forced` there and current Intel users aren't the target).

## Approach

Extend the existing `Modules/Sensors/` module with a new mode value (`FanMode.curve = 100`), new value types (`CurvePoint`, `DriverSensor`, `FanProfile`), and one new controller class (`FanCurveController`) that subscribes to the existing `SensorsReader` callback. UI is one new section in the existing settings panel. No new module, no new XPC interface, no new timer.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ Modules/Sensors (existing module, extended)                     │
│                                                                  │
│  ┌────────────────────┐  ┌──────────────────────────────────┐  │
│  │ SensorsReader      │  │ FanCurveController (new)         │  │
│  │ (existing)         │─►│  - subscribed to SensorsReader   │  │
│  │  reads temps & RPM │  │  - reads active profile          │  │
│  │  callback ~1-2s    │  │  - eval curve → target RPM       │  │
│  └────────────────────┘  │  - call SMCHelper.setFanSpeed    │  │
│           │              └──────────────────────────────────┘  │
│           ▼                            │                         │
│  ┌────────────────────┐  ┌─────────────▼────────────────────┐  │
│  │ Popup (existing,   │  │ Settings (existing, extended:    │  │
│  │ unchanged)         │  │  new Fan Curves section)         │  │
│  └────────────────────┘  └──────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                                       │
                                       ▼ XPC (reused, no changes)
                ┌──────────────────────────────────────────┐
                │ eu.exelban.Stats.SMC.Helper (existing)   │
                │  setFanMode, setFanSpeed, resetFanControl│
                └──────────────────────────────────────────┘
```

Why this shape:
- Reuses `SensorsReader` callback — no new polling timer, no extra CPU outside the work that already happens every tick.
- Reuses XPC helper — zero changes to privileged code, zero re-installation prompts when patching.
- Logic lives next to the existing `Fan` struct — natural ownership.

## Data model

```swift
// SMC/smc.swift
public enum FanMode: Int, Codable {
    case automatic = 0
    case forced    = 1
    case auto3     = 3
    case curve     = 100        // NEW. Stats-level mode (not an SMC value).
    public var isAutomatic: Bool { self == .automatic || self == .auto3 }
    public var isStatsControlled: Bool { self == .curve }
}

// Modules/Sensors/values.swift (additions)
public struct CurvePoint: Codable, Equatable {
    public var tempC: Double
    public var rpm: Int
}

public struct DriverSensor: Codable, Equatable {
    public var key: String          // SMC/HID sensor key, e.g. "TC0D" or "TG0D"
    public var weight: Double = 1.0 // reserved for future weighted-average modes
}

public struct FanProfile: Codable, Equatable, Identifiable {
    public var id: UUID = UUID()
    public var name: String
    public var isBuiltIn: Bool = false
    public var drivers: [DriverSensor]      // ≥1; effective temp = max of these
    public var points: [CurvePoint]         // ≥2 or empty (empty = Apple automatic)
    public var fanOffsetRPM: Int = 50       // for 2-fan machines; fan1 = master + offset
    public var hysteresisC: Double = 2.0
    public var deltaRpmThreshold: Int = 150
}
```

The `Fan` struct itself gains no fields. All profile data lives globally.

### Persistence

All via `Store.shared` (UserDefaults wrapper). New keys:

| Key | Type | Meaning |
|---|---|---|
| `fanctl_enabled` | Bool | Master toggle. When false, controller is a no-op even if other state is set. |
| `fanctl_profiles` | Data (JSON `[FanProfile]`) | Global profile list. |
| `fanctl_activeProfile` | String (UUID) | Currently-active profile id. |

Existing keys (`fan_<id>_mode`, `fan_<id>_speed`) are reused — `fan_<id>_mode = 100` means "Stats curve active for fan <id>" and `fan_<id>_speed` becomes the last-applied RPM for delta throttling.

Total persistence footprint: ≤30 KB for 4 built-ins + ~10 custom profiles.

### Built-in profiles

Generated on first launch by `FanProfile.builtIns(fanCount:, maxSpeeds:)`. Identical points for 1-fan and 2-fan machines; the offset handles fan 1 (when present).

| Profile | Points (tempC → RPM) | Default? |
|---|---|---|
| Apple Auto | empty → controller relinquishes → SMC `.automatic` | — |
| Quiet | (50,1200) (62,1600) (72,2400) (80,3500) (86,5000) (90,MAX) | — |
| Balanced | (40,1300) (52,1800) (62,2600) (72,3800) (80,5200) (86,MAX) | — |
| Aggressive | (35,1300) (45,2000) (55,3000) (65,4200) (72,5400) (78,MAX) | **active on first launch** |

All non-Auto presets use `drivers = [TC0D (CPU diode), TG0D (GPU diode)]`, `fanOffsetRPM = 50`. `MAX` placeholder is resolved to each fan's `maxSpeed` at apply time.

Rationale for thresholds:
- **Floor 1200-1300 RPM** — edge of audible on MBP single fan. Below it firmware can't sustain even idle SoC long-term.
- **Knee placement** — Quiet 70°C (tolerate heat for silence), Balanced 60°C (~Apple-default-ish), Aggressive 50°C (early ramp).
- **Top-out** — Quiet/Balanced 86-90°C (just below thermal pressure), Aggressive 78°C (well below throttle threshold).
- **Symmetric for 2 fans + 50 RPM offset** — both fans on MBP Pro/Max are blower fans exhausting through the same display vent; layout is symmetric, no intake/exhaust distinction. Offset breaks beat frequency between fans for cleaner acoustic.

### Reconciliation across machines

A profile JSON imported from a different-fan-count machine is auto-reconciled at load:
- `points` and `drivers` are universal; no migration needed.
- `fanOffsetRPM` is ignored on 1-fan machines, used on 2-fan.

## Controller

```swift
// Modules/Sensors/fanController.swift (new file)
final class FanCurveController {
    private let helper: SMCHelper
    private var lastApplied: [Int: Int] = [:]
    private var lastTempForHyst: [Int: Double] = [:]
    private var managedFans: Set<Int> = []
    private var isAsleep: Bool = false
    private var observers: [NSObjectProtocol] = []

    init(helper: SMCHelper)
    func tick(snapshot: Sensors_List?)
    func shutdown()
    private func applyIfNeeded(fan: Fan, target: Int, temp: Double, hysteresisC: Double, deltaThreshold: Int)
    private func relinquish()
    private func handleWillSleep()
    private func handleDidWake()
}
```

### Tick

Called from existing `SensorsReader` callback in `Sensors.main.swift`:

```swift
self.sensorsReader = SensorsReader { [weak self] value in
    self?.usageCallback(value)
    self?.fanController?.tick(snapshot: value)
}
```

No new timer.

Tick body:
1. Bail if `fanctl_enabled == false` or `helper.isActive() == false` or asleep.
2. Load active profile from `Store.shared`; if missing or `points` empty → `relinquish()` and return.
3. Lookup driver temperatures from snapshot; `effectiveTemp = max(driverTemps)`.
4. For each `Fan` in snapshot:
   - `baseRpm = interpolate(profile.points, effectiveTemp)`
   - `target = clamp(baseRpm + (fan.id == 0 ? 0 : profile.fanOffsetRPM), fan.minSpeed, fan.maxSpeed)`
   - `applyIfNeeded(...)` (hysteresis + delta-throttle)

### Apply

```swift
private func applyIfNeeded(fan: Fan, target: Int, temp: Double, ...) {
    if !managedFans.contains(fan.id) {
        helper.setFanMode(fan.id, mode: FanMode.forced.rawValue)
        managedFans.insert(fan.id)
    }
    let last = lastApplied[fan.id]
    let lastTemp = lastTempForHyst[fan.id] ?? -999
    let isLowering = (last != nil) && (target < last!)
    if isLowering && (lastTemp - temp) < hysteresisC { return }   // downward hysteresis
    if let last = last, abs(target - last) < deltaThreshold { return }
    helper.setFanSpeed(fan.id, value: target)
    lastApplied[fan.id] = target
    lastTempForHyst[fan.id] = temp
    Store.shared.set(key: "fan_\(fan.id)_speed", value: target)
}
```

Hysteresis applies **only on lowering** (cooling-first: we never delay ramp-up). Delta-threshold suppresses XPC roundtrips when temperature drifts slowly.

### Interpolation

Piecewise linear with clamping at endpoints:

```swift
func interpolate(points: [CurvePoint], tempC: Double) -> Int {
    guard let first = points.first, let last = points.last else { return 0 }
    if tempC <= first.tempC { return first.rpm }
    if tempC >= last.tempC  { return last.rpm }
    for i in 1..<points.count {
        let a = points[i-1], b = points[i]
        if tempC <= b.tempC {
            let t = (tempC - a.tempC) / (b.tempC - a.tempC)
            return Int((1.0 - t) * Double(a.rpm) + t * Double(b.rpm))
        }
    }
    return last.rpm
}
```

### Sleep/wake

| Event | Action |
|---|---|
| `NSWorkspace.willSleepNotification` | `relinquish()` — return managed fans to `.automatic`; set `isAsleep = true`. |
| `NSWorkspace.didWakeNotification` | `isAsleep = false`. Next tick re-applies because `managedFans` is empty. |
| `Sensors.willTerminate` | `controller.shutdown()` → `relinquish()`. Guarantee: stats quitting never leaves a fan stuck in `.forced`. |
| Crash without `willTerminate` | At next launch, if `customMode == .curve` but `fanctl_enabled == false` or active profile missing → reset to `.automatic` during `Sensors.init` before the reader starts. |

### Profile change

`Settings` writes to `Store.shared`, then posts `NotificationCenter.default.post(name: .fanProfileChanged, object: nil)`. Controller subscribes:

```swift
NotificationCenter.default.addObserver(forName: .fanProfileChanged, ...) { [weak self] _ in
    self?.lastApplied.removeAll()
    self?.lastTempForHyst.removeAll()
}
```

This guarantees the new profile applies on the next tick without being blocked by hysteresis from the old curve.

## UI

One new section in `Modules/Sensors/settings.swift`, between existing fan-related rows and notifications section. No new tab, no new window.

```
▼ Fan Curves                              [enable ⬤────⚪ ]
   Active profile:    [Aggressive          ▼]   [+] dup  [×] delete
   Driver sensors (max of):  ☑ CPU diode  ☑ GPU diode  ☐ CPU package  …
   Curve points:    table editor (Temp / RPM, add/remove rows)
                    mini graph preview (polyline)
   Fan 1 offset:    [ 50 ] RPM    (shown only if fanCount ≥ 2)
   ▸ Advanced:      hysteresis, delta threshold, per-fan override toggle
```

States:
| Master toggle | Profile selected? | Helper installed? | Behavior |
|---|---|---|---|
| OFF | any | any | Section collapsed/grayed; controller is no-op |
| ON | no | any | Banner "Select a profile"; controller relinquishes each tick |
| ON | yes | yes | Normal operation |
| ON | yes | no | Overlay "Install helper" + install button (uses existing `SMCHelper.install()`) |

Validation on save:
- Curve points: ≥2; sorted by tempC ascending; unique tempC; in range [20, 110]°C; RPM ≥ fan.minSpeed.
- Drivers: ≥1.
- Offset: [0, 1000] RPM.
- Hysteresis: [0.5, 10] °C.
- Threshold: [50, 500] RPM.

Save button disabled while invalid; red inline hints under offending fields.

## Performance budget

| Source | Cost |
|---|---|
| Reuse of `SensorsReader` callback | 0 new wakeups |
| Per-tick work (stable temp) | ~5 µs CPU (lookup + max + interpolate + compare) |
| Per-tick work (temp drift > threshold) | ~5 µs + 1 ms XPC roundtrip → ≤1× per few seconds |
| RAM steady-state | ~50 KB (controller state + profiles + UI views when settings open) |
| Persistence | ≤30 KB in UserDefaults plist |

Net overhead on top of stats baseline: ≤1 MB RAM, ≤0.1 % CPU averaged.

## Edge cases

| Case | Handling |
|---|---|
| Helper missing | Master toggle disabled; "Install helper" hint. |
| Helper crashes during run | `tick` sees `helper.isActive() == false`, no-ops. Resumes when helper restarts. |
| Driver sensor disappears from snapshot | Skipped in `lookupTemps`. If all drivers gone → tick skips apply; UI marks driver row red. |
| 0 fans (desktop) | Sensors reader exposes no `Fan` → controller no-op. UI hides whole section. |
| Custom profile named like built-in | Allowed; ids differ; picker shows both. |
| Built-in profile deletion | Forbidden (delete button disabled). |
| Profile JSON corruption | Falls back to `builtIns(...)` and logs warning. |
| 2-fan machine with asymmetric maxSpeed | Per-fan `maxSpeed` clamp at apply preserves correctness. |
| RPM stored in profile exceeds current fan's max | Clamped at apply, stored value preserved (portable across machines). |
| Fork rolled back to upstream | Risk: fans stuck in `.forced` if user downgrades without disabling. Mitigation: README warns; also patch `Sensors.willTerminate` to coerce `FanMode.curve` → `.automatic` so any version that doesn't understand 100 still releases the fan on quit. |

## Testing

### Unit tests

New file `Tests/SensorsTests/FanCurveTests.swift`:
- `interpolate`: below first / above last / midpoint between two / empty / single point.
- Hysteresis: blocks lowering inside band; allows raising; allows lowering past band.
- Delta throttle: skips when |target - last| < threshold; first apply always passes; post-relinquish always applies.
- Driver max: picks highest among present; skips missing.
- Clamp: enforces min/max; adds offset only for fan 1; preserves stored profile values.
- Relinquish: clears state for all managed fans; emits `.automatic` for each.
- Profile change: clears `lastApplied`/`lastTempForHyst`.
- Sleep/wake: `willSleep` → relinquish; `didWake` → next tick re-applies.

Use a fake `SMCHelper` (in-memory spy) and synthesized `Sensors_List`.

### Manual integration checklist (in design doc)

1. Enable + Aggressive profile → fan ramps under `yes > /dev/null` load within 5 s.
2. Switch to Quiet → fan slows within 2-3 s.
3. Disable master → Apple curve resumes within 2 s.
4. Sleep then wake → fan back under control within 1-2 s after wake.
5. Quit Stats.app → `smc -k F0Md -r` shows 0 (automatic).
6. `kill -9 Stats.app` then reopen → at startup, fan mode is reset to 0.
7. 2-fan machine: `smc -k F0Ac -r` vs `smc -k F1Ac -r` shows ~offset RPM gap.
8. Activity Monitor: Stats.app averaged CPU ≤ 0.5 %.

## What changes, file by file

| File | Change | Approx lines |
|---|---|---|
| `SMC/smc.swift` | Add `case curve = 100` to `FanMode`; add `isStatsControlled`. | +5 |
| `Modules/Sensors/values.swift` | Add `CurvePoint`, `DriverSensor`, `FanProfile`. | +60 |
| `Modules/Sensors/fanController.swift` | **NEW**: controller class. | +200 |
| `Modules/Sensors/profileStore.swift` | **NEW**: persistence + built-ins generator. | +120 |
| `Modules/Sensors/curveGraph.swift` | **NEW**: mini graph NSView. | +60 |
| `Modules/Sensors/settings.swift` | New Fan Curves section. | +250 |
| `Modules/Sensors/main.swift` | Wire controller into reader callback + lifecycle. | +30 |
| `Kit/types.swift` | Two new `Notification.Name`s. | +2 |
| `Tests/SensorsTests/FanCurveTests.swift` | **NEW** test file. | +250 |

Total: ~1000 lines (incl. tests). No changes to XPC helper, no changes to `SensorsReader`, no changes to other modules.

## Build, sign, install

The existing `Makefile` targets `archive` / `notarize` / `sign` (with Apple ID / `AC_PASSWORD` keychain profile) are upstream's distribution flow. For the personal fork we want a single local-install target that does **ad-hoc signing** (no Apple Developer cert needed) and installs into `/Applications`.

New Makefile target:

```makefile
# Build for current arch, ad-hoc sign, install to /Applications.
local: clean
	xcodebuild \
		-scheme $(APP) \
		-configuration Release \
		-derivedDataPath $(BUILD_PATH)/DerivedData \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGN_STYLE=Manual \
		DEVELOPMENT_TEAM="" \
		ONLY_ACTIVE_ARCH=YES \
		build
	# Re-sign deeply (signs SMC helper + LaunchAgent inside the bundle):
	codesign --force --deep --sign - \
		$(BUILD_PATH)/DerivedData/Build/Products/Release/$(APP).app
	# Replace the installed version (preserves user prefs in ~/Library/Preferences):
	@if [ -d "/Applications/$(APP).app" ]; then \
		osascript -e 'tell application "$(APP)" to quit' 2>/dev/null || true; \
		sleep 1; \
		rm -rf "/Applications/$(APP).app"; \
	fi
	cp -R $(BUILD_PATH)/DerivedData/Build/Products/Release/$(APP).app /Applications/
	# Remove quarantine attr so Gatekeeper doesn't refuse the ad-hoc-signed app:
	xattr -cr "/Applications/$(APP).app"
	@echo "Stats installed to /Applications. Launch from Spotlight."
```

Notes:
- `CODE_SIGN_IDENTITY="-"` is the official ad-hoc identity. Works for personal use; cannot be distributed.
- `--deep` is required because the bundle contains `eu.exelban.Stats.SMC.Helper` and `LaunchAtLogin.app` as nested code that must also be signed.
- `xattr -cr` strips the quarantine flag that macOS sets on copied bundles (otherwise Gatekeeper blocks an ad-hoc-signed app on first launch).
- The user-installed XPC helper at `/Library/PrivilegedHelperTools/eu.exelban.Stats.SMC.Helper` is **not** replaced automatically — when first run of our patched build invokes the helper, stats' existing `SMCHelper.install()` flow detects signature mismatch and prompts for admin password to re-install. Expected and correct.
- The bumped `CFBundleVersion` (from `next-version` target) is **not** invoked here — we don't notarize, so version bumps are optional. Bump manually if you want App to know about the change.

Verify after install:

```bash
codesign -dv /Applications/Stats.app           # → Signature=adhoc
spctl -a -vv /Applications/Stats.app           # will say "rejected" — expected for adhoc; not blocking with quarantine cleared
ls -la /Library/PrivilegedHelperTools/         # helper still present from previous install; re-installs on first XPC call
```

## Post-task pipeline (after each completed feature/fix)

Automated, no asking per step (follows the same pattern as `~/www/dev/edmp-client-tui`):

1. `xcodebuild -scheme Stats -configuration Debug build` — must succeed.
2. Run XCTest target (Tests scheme) — full suite must pass.
3. `make local` — produces signed `.app` in `/Applications/`.
4. Bump `CFBundleVersion` in `Stats/Supporting Files/Info.plist` (existing `next-version` target works for this; use it manually since `local` doesn't call it).
5. `git add <changed files>` and `git commit` (rules below).
6. Reindex codebase memory: `mcp__codebase-memory__index_repository(repo_path="/Users/ank/dev/stats", mode="full")` so `search_code` / `get_architecture` / `trace_path` see the new files.
7. Report to user: short line — build OK, version bumped from X→Y, commit SHA, reindex done.

Do not push to upstream remote — this is a personal fork; commits stay local until explicitly pushed.

## Commit and code-attribution rules (fork-local)

These override stats' upstream conventions for the fork:

- **No `Co-Authored-By: Claude` / `Co-Authored-By: Anthropic` trailers.** Same rule as user's global `~/CLAUDE.md`. Commit messages contain only the subject and body the developer wrote; no AI attribution.
- **No "Generated with Claude" footers in commit body.** Drop them if any tool tries to insert them.
- **No AI-attribution comments in source code.** Don't mark code as "generated by", "with help from", "Claude wrote this", etc. Code is code; review history is in git.
- **Commit message style:** English, imperative, no `feat:` / `fix:` prefixes (matches stats upstream style — see `git log` for examples). One logical change = one commit.
- **Cocoa file header comments** that stats uses (`//  Created by Serhiy Mytrovtsiy …`): when adding a NEW Swift file in the fork, use **your own name and date** as the file-header author. Don't keep "Created by Serhiy Mytrovtsiy" on a file you wrote. For files **modified** (not created), leave the original header as-is.

## Structure and solution rules (fork-local)

- All new files in `Modules/Sensors/` follow the existing Swift conventions: 4-space indent, `// MARK:` for sections, `private` by default, `public` only when crossing module boundary (`Kit/` ↔ `Modules/*/`).
- New `Notification.Name` entries go in `Kit/types.swift` next to existing ones — don't scatter them.
- New `Store.shared` keys go through the existing wrapper, not raw `UserDefaults.standard`.
- All XPC calls go through `SMCHelper.shared` — never construct `NSXPCConnection` directly in module code.
- New tests in `Tests/SensorsTests/`, mirroring existing pattern (one file per concern, XCTestCase subclass).
- Settings UI uses existing `PreferencesSection` / `PreferencesRow` / `switchView` / `selectView` builders from `Kit/preferences.swift` — do not introduce a new layout idiom.

## After implementation: update fork's AI-instruction docs

Once the feature is merged into the fork's main branch:

1. **Create `CLAUDE.md` at fork root** if absent, encoding the rules in this section (build/sign/install, post-task pipeline, commit attribution, structure rules). Use `~/www/dev/edmp-client-tui/CLAUDE.md` as the structural template (sections: Before Starting, Codebase Index, Build & Verify, Release Builds, Post-Task, Versioning & Commits).
2. **Add a `Codebase Index` block** that documents: "MCP `codebase-memory` indexed this repo — use `mcp__codebase-memory__search_code`, `get_architecture`, `trace_path` before exploring."
3. **Optional `AGENTS.md`** for deeper details (component map, where XPC helper lives, where sensors are read).
4. After CLAUDE.md is written, run a final `mcp__codebase-memory__index_repository(mode="full")` so subsequent sessions start from a current index.

## Out of scope (future work)

- Per-fan independent curves (model already supports it via an optional `fanOverrides` field; UI would be an advanced disclosure).
- Schedule-based profile switching (e.g. Quiet at night).
- Menubar quick-switcher for active profile.
- Triggers ("if battery > 40 °C force RPM ≥ X").
- Asymmetric domain-biased profile (CPU drivers on fan 0, GPU on fan 1) — dropped because real-world delta ≤ 2 °C and it complicates the single-curve UI.
