# Stats (personal fork)

Personal fork of [exelban/stats](https://github.com/exelban/stats) extended with **temperature-driven fan curve control** for Apple Silicon MacBook Pros (verified on M5).

Original Stats is a beautiful macOS menubar monitor for CPU/GPU/RAM/sensors/etc. This fork adds:

## What's added vs. upstream

- **Fan curve controller** — picks active profile (Apple Auto / Quiet / Balanced / Aggressive / custom) from a single menubar popup. Profile's curve points (temp → RPM) drive the fan through the existing signed XPC helper.
- **Smart fan behaviors**:
  - 3-sample median temp smoothing kills HID jitter.
  - Derivative pre-ramp: ≥2°C/s rising → +500 RPM bonus, anticipates thermal spikes.
  - Battery safety floor: ≥40°C battery for 30+s → enforces 2500 RPM minimum.
- **NSLock-guarded controller** state — safe across background reader callbacks and main-thread observers.
- **Single-instance enforcement** — `LSMultipleInstancesProhibited` + runtime check.

## What's removed vs. upstream

- **Bluetooth, Remote modules** — Bluetooth triggered TCC prompts on every ad-hoc rebuild; Remote was a wrapper for cloud sync.
- **`Kit/plugins/SystemStats.swift`** — exelban's commercial cloud sync (mac-stats.com OAuth, MQTT remote control). Not needed personally.
- **`Kit/plugins/Updater.swift`** — auto-update from upstream releases. Not used in a personal fork.
- **WidgetKit extension** (`Widgets/`) — Notification Center / Lock Screen widgets. macOS 27 entitlements rejected the auto-donation flow; Stats hammered Spotlight ~10 errors/sec.
- **LevelDB sensor history** (`Kit/lldb/`) — popup time-series charts. Saves ~15-20 MB RAM.

## Build & install

```bash
# Compile + run tests:
xcodebuild -scheme Stats -configuration Debug -destination 'platform=macOS,arch=arm64' \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build

xcodebuild -scheme Stats -destination 'platform=macOS,arch=arm64' \
    -only-testing:Tests/SensorsTests \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO test

# Build, ad-hoc sign, install to /Applications:
make local
```

`make local` does the local-dev workflow: Release build with ad-hoc codesigning, replaces `/Applications/Stats.app`, strips quarantine, ready to launch via Spotlight.

## Fan curve usage

After `make local`, launch Stats. On first run with the SMC helper installed (auth dialog appears), the controller bootstraps 4 built-in profiles and activates **Aggressive** by default. To change:

- **Menubar → Sensors → Fans section**: profile picker replaces the Automatic toggle.
- **Settings → Sensors → Fan Curves**: edit curve points, drivers, hysteresis, offset, advanced.

Picking **Manual / Off / Max** from the popup yields the fan to direct user control; the controller silently stops managing that fan until you pick a profile again.

## Upstream sync policy

This fork **never pushes to upstream** (`origin` = `exelban/stats`). Personal work lives on `ank` remote → `webarchitector/stats`. Commit messages avoid AI-attribution trailers per the fork's `CLAUDE.md` policy.

To sync upstream changes:
```bash
git fetch origin
git merge origin/master  # then resolve conflicts manually
```

## License

MIT (inherited from upstream stats).
