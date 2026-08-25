# Cool Fan Control — Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Build an open-source macOS menu-bar fan control + temperature/battery monitoring app for **Apple Silicon only** (M1–M5), modeled on the dead "MacFan" app (https://macfan.atiwari.in/ — landing page still up, repo `twrnrg/macfan` is 404, cask tap gone). Includes a **battery-charging monitor** (keep battery ≤ 35 °C while charging) and a **CPU 90 °C throttle guard** (kick fans to max to prevent throttling).

**Product decisions (confirmed by Emre 2026-08-25):** Name **Cool Fan Control** · bundle id `com.alpico.coolfancontrol` ✅ · **macOS 14+** · **MIT license, open source (public GitHub repo under `emrekoch`)** ✅ · **Homebrew cask included** ✅ · free, no telemetry, Developer ID + notarized (outside MAS, like the reference).

**Architecture:** SwiftUI menu-bar app + a root **LaunchDaemon helper** that owns ALL SMC (System Management Controller) access. The GUI computes fan targets (smart curve with hysteresis, fixed RPM, presets, overrides), the root helper writes SMC keys (`F0Md`/`F0Tg`) and reads all sensors. Charging status comes from the **public IOPowerSources API** (no root needed) but is read by the helper so the snapshot stays atomic. Helper installed/registered via `SMAppService.daemon` (macOS 13+), XPC over Mach service, always restores Apple's automatic fan control on quit, crash (heartbeat watchdog), or helper death.

**Tech Stack:** Swift 6, SwiftUI (MenuBarExtra), XPC (`NSXPCConnection`), IOKit (AppleSMC user client), IOPowerSources (battery), `SMAppService.daemon`, XcodeGen, SwiftPM (Core library), XCTest/swift-testing, Developer ID signing + notarytool, Homebrew cask.

---

## Reference app spec (from dead MacFan landing page)

- Smart-by-temperature: fans ramp toward a user-set target temp with **hysteresis** (no hunting). Also fixed per-fan RPM, **Quiet**, **Max**.
- Live CPU + GPU temps; animated fans (spin faster with RPM, blue→amber→red glow).
- Named presets (e.g. "Gaming", "Turbo") — save/apply.
- Menu bar app; **restores Apple auto control on quit**.
- Free, MIT, no telemetry, notarized, macOS 14+, M1–M5, outside MAS + Homebrew cask.

## Emre's additional requirements (V1 scope)

1. **Battery charging monitor:** show charging status; while charging, keep the battery cool with a **two-tier rule** — fans kick in at **33 °C** at **mid level** (midpoint of the fan's min–max range), and step **higher** above **35 °C** (default: fan max). Each tier has hysteresis so fans don't hunt.
2. **CPU throttle guard:** when CPU temp reaches **90 °C**, fans go to **max** to prevent throttling (release ≈88 °C with hysteresis). This is an absolute safety override above any selected mode.
3. Overrides stack: `effectiveTarget = max(modeTarget, cpuOverride, batteryOverride)` — then clamped to `[F0Mn, F0Mx]`.

## Hardware/OS findings from today's probe (this M1 Mac mini, macOS 26.5.2)

- Machine: `Macmini9,1` (Apple M1), macOS 26.5.2 → hardware-validation target for fans (1 fan). **No battery** — battery features validated on Emre's M1 Max MacBook Pro.
- Classic AppleSMC struct-method interface (`IOConnectCallStructMethod`, selectors 9/5) opens fine unprivileged but **every read returns `kIOReturnUnsupported` (0xe00002c7) as non-root**.
- Conclusion: **reads AND writes require root** on this OS. All SMC traffic goes through the root helper — the GUI never touches SMC directly. (TG Pro / Macs Fan Control / Stats all use the same SMC keys on M-series, so root access is expected to work — **must be confirmed in Milestone 0**.)
- Root probe binary ready at `/tmp/smc_probe` (compile from the C in this session) — needs `sudo` run by Emre.

### Key SMC keys (Apple Silicon)

| Key | Type | Meaning |
|---|---|---|
| `FNum` | ui8 | number of fans |
| `F0Ac` / `F1Ac` | fpe2 | actual fan RPM |
| `F0Mn` / `F0Mx` | fpe2 | min / max RPM |
| `F0Md` | ui8 | 0 = auto (system), 1 = manual |
| `F0Tg` | fpe2 | target RPM (manual mode) |
| `TC0P` | sp78 | CPU proximity temp |
| `TCXC` | sp78 | CPU (may be absent on some M-series) |
| `TG0P` | sp78 | GPU proximity temp |
| `TM0P` | sp78 | memory temp |
| `TH0P` / `TH1P` | sp78 | SSD/NAND temp |
| `TB0T` | sp78 | battery temp (fallback `BT0C`; probe both on MBP) |

Data type codecs: `fpe2` = u16/4, `sp78` = s16/256, `ui8`/`ui16`/`ui32` raw, `flt` = IEEE754.

**Fanless Macs (MacBook Air): `FNum == 0` → hide fan UI, temp-only mode; fan-based battery-cooling impossible → show note, rely on macOS charging management.**
**Battery-less Macs (Mac mini/Studio/Pro desktops): hide battery UI entirely (`BatteryState.isPresent == false`).**

---

## Project layout

```
~/cool-fan-control/
  AGENTS.md, README.md, LICENSE (MIT), .gitignore
  project.yml                     # XcodeGen (app + helper targets)
  Core/                           # SwiftPM package — ALL testable logic
    Package.swift
    Sources/FanControlCore/
      SMCDataTypes.swift          # 4-char keys, type codecs (fpe2/sp78/ui8/...)
      SMCKeyData.swift            # AppleSMC struct packing
      SMCClient.swift             # IOKit wrapper: open/close, readKey, writeKey
      FanDiscovery.swift          # FNum, per-fan F0Mn/Mx, FanState model
      SensorCatalog.swift         # known temp keys + display names + fallbacks
      SensorSnapshot.swift        # EWMA smoothing
      BatteryMonitor.swift        # IOPowerSources wrapper → BatteryState
      FanControlEngine.swift      # modes, curve, hysteresis, OVERRIDES (PURE)
      TemperatureCurve.swift      # piecewise-linear (temp→RPM)
      OverrideRules.swift         # CPU 90 °C guard + battery 35 °C rule (PURE)
      Preset.swift / PresetStore.swift
      FanSnapshot.swift           # Codable state passed over XPC (+ BatteryState)
    Tests/FanControlCoreTests/    # unit tests (run WITHOUT hardware)
  Helper/
    Sources/helperd/main.swift    # XPC listener, root
    Sources/helperd/HelperService.swift
    Sources/helperd/HelperProtocol.swift  # shared w/ app
    com.alpico.coolfancontrol.helper.plist # LaunchDaemon plist (MachServices)
  App/
    Sources/ MacFanControlApp.swift (→ CoolFanControlApp.swift), MenuBarView.swift,
    FanGaugeView.swift, BatteryCardView.swift, CurveEditorView.swift,
    PresetsView.swift, SettingsView.swift, HelperClient.swift, AppState.swift
  Scripts/
    bootstrap.sh, test.sh, build.sh, notarize.sh, make-dmg.sh, hardware-test.sh
  Docs/
    architecture.md, hardware-verification.md, hardware-notes.md
```

> **Confirmed 2026-08-25:** bundle id `com.alpico.coolfancontrol`; helper `com.alpico.coolfancontrol.helper`; XPC Mach service `com.alpico.coolfancontrol.helper.xpc`.

---

## Milestone 0 — Hardware spike (de-risk FIRST, before any code)

### Task 0.1: Confirm root SMC reads work
- Emre runs `sudo /tmp/smc_probe` (or `scripts/hardware-test.sh read` once repo exists).
- **Expected (Mac mini M1):** `FNum=1`, `F0Ac` ≈ 1200–2000 RPM, `F0Mn`/`F0Mx` sane, `TC0P` 35–70 °C; note which of `TCXC`/`TG0P`/`TM0P`/`TH0P` exist; `TB0T`/`BT0C` will ERR (no battery — expected).
- **Then on MBP M1 Max:** confirm `TB0T` (or `BT0C`) returns battery temp; `pmset -g batt` (unprivileged, read-only) shows charging status as a sanity cross-check for IOPowerSources.
- **If classic SMC is dead even as root:** stop and pivot — investigate `powermetrics` (root) for temps and re-evaluate fan-write path (research task; unlikely given existing M-series apps).

### Task 0.2: Confirm root SMC writes + auto-restore
- Small script: set `F0Md=1` + `F0Tg=F0Mn` (min RPM), sleep 3 s, read `F0Ac` (expect drop), then `F0Md=0` (expect return to auto). **Never write above `F0Mx`. Always restore `F0Md=0` in a `trap`.**
- Record results in `Docs/hardware-notes.md`.
- **Commit:** `docs: hardware spike results`.

---

## Milestone 1 — Repo & toolchain

### Task 1.1: Project skeleton
- `mkdir ~/cool-fan-control`, write `AGENTS.md` (goal, V1 scope, non-goals: Intel NOT supported, no App Store, no charging-control — we cool via fans only), `README.md`, `.gitignore` (`.build/`, `DerivedData/`, `*.dmg`, `.DS_Store`), `LICENSE` (MIT, name = Emre Koch / project). `git init`, first commit.

### Task 1.2: Core SwiftPM package
- `Core/Package.swift` with `FanControlCore` library + `FanControlCoreTests` (swift-tools 6.0).
- Trivial placeholder test. Verify: `swift test --package-path Core` → 1 passed.

### Task 1.3: XcodeGen project
- `Scripts/bootstrap.sh`: `brew install xcodegen` if missing, then `xcodegen generate`.
- `project.yml`: targets `CoolFanControl` (app, macOS 14+, not sandboxed, `MenuBarExtra`), `helperd` (command-line tool), test targets; shared `DEVELOPMENT_TEAM=2D7FVQV9WG`, `CODE_SIGN_IDENTITY=Developer ID Application`.
- Verify: `xcodegen generate` + `xcodebuild -project ... -scheme CoolFanControl build` succeeds.

### Task 1.4: Test script
- `Scripts/test.sh`: runs `swift test --package-path Core` then `xcodebuild test` (unit tests only).
- Verify: exits 0.

---

## Milestone 2 — SMC core (TDD; codecs are pure, no hardware needed)

### Task 2.1: `SMCDataTypes.swift` — type codecs
- `enum SMCDataType { case ui8, ui16, ui32, flt, fpe2, sp78, ch8 }` with `decode/encode` from `[UInt8]` (payload bytes as AppleSMC returns them; big-endian for `ch8*`).
- **Test:** known vectors — `fpe2` bytes `[0x1F, 0x40]` → 2000.0 RPM; round-trip `ui8`, `sp78` `[0x4B, 0x00]` → 75.0 °C; `flt`; invalid lengths throw.

### Task 2.2: `SMCKeyData.swift` — struct packing
- `fourCharCode("F0Tg")`, `SMCKeyData` C-struct (packed) encode/decode, key validation (exactly 4 ASCII chars).
- **Test:** round-trip; rejects `"TOOLONG"`, empty.

### Task 2.3: `SMCClient.swift` — IOKit wrapper
- `SMCClient()`: `IOServiceGetMatchingService("AppleSMC")`, `IOServiceOpen`, `readKey(_:) -> SMCValue?`, `writeKey(_:value:) -> Bool`; clean close/deinit.
- Unit tests: protocol seam (`protocol SMCHandling`) so engine tests never need hardware.
- Hardware test (root, manual): `scripts/hardware-test.sh read` prints all keys via the real client.

### Task 2.4: `FanDiscovery.swift` — fan model
- `FanInfo { index, minRPM, maxRPM, currentRPM, mode, targetRPM }`; discover via `FNum`, `F{0,1}*`; `FanSnapshot` struct.
- **Test:** parse known SMC values into `FanInfo`; `FNum=0` → empty fans.

---

## Milestone 3 — Sensors (CPU/GPU/battery)

### Task 3.1: `SensorCatalog.swift`
- Ordered list with probe order + fallbacks: CPU `[TC0P, TCXC]`, GPU `[TG0P]`, Memory `[TM0P]`, SSD `[TH0P, TH1P]`, Battery `[TB0T, BT0C]`; display names. `SensorReading { key, name, celsius? }`.
- **Test:** catalog well-formed (no dupes, names non-empty); fallback picks first readable key from a fake map.

### Task 3.2: `SensorSnapshot.swift`
- `SensorMonitor`: takes raw readings, applies EWMA (α=0.3, 1 s cadence), publishes `Snapshot { temps: [SensorReading], fans: [FanInfo], battery: BatteryState }`.
- **Test:** EWMA converges; NaN/invalid readings skipped.

### Task 3.3: `BatteryMonitor.swift` — charging status + battery temp
- Wraps **IOPowerSources** (public API): `isPresent`, `isCharging` (power-source state == AC + charging), `chargePercent`. Battery *temperature* still comes from SMC (`TB0T`/`BT0C`) via the helper.
- `BatteryState { isPresent, isCharging, chargePercent: Double?, temperatureC: Double? }`, Codable.
- **Test:** map IOPS dictionaries (real shapes from `IOPSCopyPowerSourcesInfo`) → `BatteryState`; absent source → `isPresent=false`; desktop (no battery) case.

---

## Milestone 4 — Fan control engine (pure logic, the TDD heart)

### Task 4.1: `FanControlEngine.swift` — modes
- `enum FanMode: Codable { case auto, smart, manual(rpm: Int), quiet, max }`.
- **Test:** Codable round-trip; `max` maps to `F0Mx`; `quiet` maps to `F0Mn`.

### Task 4.2: `TemperatureCurve.swift`
- Points `[(temp: Double, rpm: Double)]` (default: 40 °C→min, 85 °C→max), piecewise-linear `rpm(at:)`, clamped to `[minRPM, maxRPM]`.
- **Test:** interpolation midpoints; below-first/above-last clamps; empty curve → error.

### Task 4.3: `HysteresisController.swift` — the anti-hunt state machine
- Stateful: `currentTarget: Double?`, direction (rising/falling). On each tick(temp):
  1. desired = curve.rpm(at: temp)
  2. **Rising:** if desired > currentTarget → new target = desired.
  3. **Falling:** only step down when `temp < setpointTemp - hysteresis` (default 3 °C) → new target = curve.rpm(at: temp - hysteresis).
  4. Min-change gate: apply only if `|new - current| ≥ 100 RPM` AND ≥ 2 s since last write.
- **Test (critical):** oscillate temp ±0.5 °C around setpoint for 200 ticks → target changes ≤ 1 time; ramp 50→80 → monotonic ↑; ramp 80→50 → steps down in hysteresis bands; clamps.

### Task 4.4: `Preset.swift` / `PresetStore.swift`
- `Preset { name, mode, curve? }`; store JSON at `~/Library/Application Support/CoolFanControl/presets.json`; seed `Quiet`, `Gaming`, `Turbo`, `Max`.
- **Test:** save/load round-trip; corrupt file → fresh defaults; duplicate names rejected; RPM validated against `minRPM...maxRPM`.

### Task 4.5: `OverrideRules.swift` — CPU 90 °C guard + battery 35 °C rule ⭐
Two stateful (hysteresis) override rules, each pure and independently tested:

```swift
struct CpuThrottleGuard {        // CPU ≥ 90 °C → fans MAX; release < 88 °C
    var engaged = false
    mutating func tick(cpuTempC: Double?) -> OverrideDecision
    // engaged when cpuTempC >= 90 (hysteresis: stays engaged until < 88)
    // decision = .forceRPM(fanMax) when engaged, else .inactive
}
struct BatteryCoolingRule {       // two tiers: charging && batteryTemp > kickoff → mid; > highTemp → higher
    var tier: Tier = .off          // .off / .mid / .high  (stateful, hysteresis)
    mutating func tick(isCharging: Bool, batteryTempC: Double?) -> OverrideDecision
    // rising:   temp > 33 → .mid (forceRPM(midRPM)); temp > 35 → .high (forceRPM(highRPM))
    // falling:  .high releases when temp < 33 (→ back to .mid, still engaged); .mid releases when temp < 31
    //           OR no longer charging → .off
    // midRPM = F0Mn + (F0Mx - F0Mn) / 2; highRPM default = F0Mx (both configurable)
    // decision = .forceRPM(active tier's RPM) when engaged, else .inactive
}
```

- Engine computes: `effectiveTarget = max(modeTarget, cpuOverride ?? 0, batteryOverride ?? 0)` → clamp `[F0Mn, F0Mx]` → min-change gate.
- **Tests:** CPU guard: 89.9 → inactive; 90 → max; 89 → still max (hysteresis); 88 → released; exactly 90/88 boundary. Battery tiers: not charging + 40 °C → inactive; charging + 32.9 → off; 33.1 → mid; 35.1 → high; falling 34.9 → still high; 33.1 → still high (release < 33); 32.9 → mid (still engaged); 31.1 → mid; 30.9 → off; unplug while engaged → off. Priority: manual 1500 RPM + CPU 90 → effective = max; battery mid active + CPU guard inactive → effective = mid. Fanless (`F0Mx == nil`) → overrides inert.

### Task 4.6: Settings model
- `EngineSettings { cpuGuardTemp: 90, cpuGuardRelease: 88, batteryKickoffTemp: 33, batteryKickoffRPM: .midFan, batteryHighTemp: 35, batteryHighRPM: .maxFan, tierHysteresis: 2, hysteresis: 3, minChangeRPM: 100, minInterval: 2s }` — Codable, persisted, all overridable in Settings UI.
- **Test:** defaults sane; Codable round-trip; range validation (release < trigger, RPM within fan bounds).

---

## Milestone 5 — Root helper daemon + XPC (single writer principle)

> The helper is the ONLY process that writes SMC. The app computes; the helper applies. All reads also go through the helper (see probe finding).

### Task 5.1: `helperd` executable
- Command-line tool target (no sandbox). Main: `NSXPCListener` on Mach service `com.alpico.coolfancontrol.helper.xpc`, `resume()`.
- Boots `SMCClient`; on launch, **ensures auto mode** (`F0Md=0`) until told otherwise.

### Task 5.2: `HelperProtocol.swift` (shared by app + helper)
```swift
@objc protocol FanControlHelperProtocol {
    func readSnapshot(reply: @escaping (FanSnapshot) -> Void)    // temps + fans + BatteryState
    func setMode(fanIndex: Int, mode: FanMode, reply: @escaping (Bool) -> Void)
    func restoreAuto(reply: @escaping (Bool) -> Void)
    func ping(reply: @escaping (Bool) -> Void)                   // heartbeat
}
```
- `FanSnapshot` now includes `battery: BatteryState` (helper reads IOPS + `TB0T`).
- **Test:** FanSnapshot/FanMode/BatteryState encode over `NSXPCConnection` (two in-process endpoints, loopback).

### Task 5.3: XPC plumbing
- Helper: `NSXPCListener` delegate → `FanControlHelperService` (clamps RPM to `min...max`, sets `F0Md=1` then `F0Tg`).
- App: `HelperClient` (`init(machServiceName:)`, `remoteObjectProxy`, invalidation → auto-reconnect with backoff 1/2/5 s).
- **Test:** loopback connection tests (no root needed); hardware apply via `scripts/hardware-test.sh write <rpm>` (root, restores auto after).

### Task 5.4: Install via `SMAppService.daemon`
- Embed helper binary + `com.alpico.coolfancontrol.helper.plist` (with `MachServices`) in app bundle `Contents/Library/LaunchServices/`.
- On launch: `SMAppService.daemon(plistName:).register()` (throws if not in `/Applications` or signing invalid). Show install state in UI.
- **Verify manually:** `launchctl print system/com.alpico.coolfancontrol.helper`, `ps aux | grep helperd`.

### Task 5.5: Safety — heartbeat + auto-restore watchdog
- App pings helper every 5 s. Helper: no ping for **30 s** → `F0Md=0` on all fans. `restoreAuto` on app `willTerminate` and helper shutdown.
- **Test:** watchdog timer (fake clock); RPM clamp; never writes when `FNum==0`.

---

## Milestone 6 — Menu bar UI

### Task 6.1: `MenuBarExtra` popover shell
- `CoolFanControlApp` with `MenuBarExtra`, popover: header (CPU/GPU temps), fan cards (animated glyph + RPM), **battery card** (when present), mode controls, presets menu, "Quit" (restores auto).
- `FanGaugeView`: `Canvas`-drawn fan; rotation ∝ RPM; blade color white→blue→amber→**red ≥ 90 °C**.

### Task 6.2: Mode controls
- Picker Auto / Smart / Manual / Quiet / Max; per-fan slider `minRPM...maxRPM`; live target display.
- `AppState` (ObservableObject): 1 s `Timer` → `helper.readSnapshot` → engine tick (curve + overrides) → `setMode` only when target changed.

### Task 6.3: Curve editor
- `CurveEditorView`: Smart curve points (30–100 °C × min–max RPM); hysteresis slider (0–10 °C); live preview at current temp.

### Task 6.4: Battery card + override badges
- `BatteryCardView`: charge %, charging bolt, battery temp; temp > 33 °C → amber, > 35 °C → red; **"Battery cooling"** badge at tier 1 (mid), **"Battery cooling (high)"** at tier 2.
- **"Throttle guard"** badge while CPU ≥ 90 °C rule is engaged (red).
- Presets UI + onboarding: first-run sheet "Install helper?" → registers daemon, shows success/failure + recovery hint (move to /Applications).

---

## Milestone 7 — Settings & lifecycle

### Task 7.1: Settings window
- Launch at login (`SMAppService.mainApp.register()`), polling interval (0.5/1/2 s), start mode (Auto default), **rule setpoints** (CPU guard 90/88, battery guard 35/33, battery-cool RPM), toggle each rule on/off.

### Task 7.2: Sleep/wake + helper restart
- On wake: re-read snapshot, re-assert mode (firmware may reset to auto). On helper drop: banner, reconnect, re-assert mode.
- **Test:** state-machine transitions (unit); hardware: `pmset sleepnow` manual check.

### Task 7.3: Fanless + battery-less machines
- `FNum == 0` → hide fan UI, temp-only mode, overrides inert, note about battery cooling. `BatteryState.isPresent == false` → hide battery card/rules entirely. **Test:** both paths.

### Task 7.4: Intel guard
- `sysctl hw.optional.arm64 == 1` at launch; else "Apple Silicon only" alert + exit. **Test:** mocked sysctl.

---

## Milestone 8 — Hardening & E2E verification

### Task 8.1: `Docs/hardware-verification.md` checklist (this M1 mini + MBP M1 Max)
- [ ] Auto mode: RPM matches system; no writes when idle.
- [ ] Manual min → RPM drops; manual max → RPM rises; never exceeds F0Mx.
- [ ] Smart: load CPU (`yes > /dev/null &`) → ramp; unload → ramp down with hysteresis, no oscillation.
- [ ] **CPU guard:** heavy load until ~90 °C → fans hit max, badge shows; release at 88 °C.
- [ ] **Battery tiers (MBP):** with charger plugged, temporarily lower setpoints (e.g. kickoff 27 / high 30) in Settings → fans hit mid, then high as temp crosses; verify release bands; restore defaults (33/35). Unplug while engaged → rule releases.
- [ ] Quit from menu bar → `F0Md` back to 0 within 1 s. `kill -9` → watchdog restores auto within 30 s.
- [ ] Presets persist; corrupt presets.json recovers.
- [ ] Sleep/wake re-asserts mode; fanless/battery-less paths render correctly.

### Task 8.2: Robustness pass
- Timer invalidation, XPC reconnect storms (backoff caps), no retain cycles, memory flat over 1 h.

### Task 8.3: QA
- macOS 14 (if available) + 26; dark/light; accessibility labels.

---

## Milestone 9 — Packaging & distribution

### Task 9.1: Signing
- Developer ID Application (Team `2D7FVQV9WG`), hardened runtime, app + helper **not sandboxed**. `codesign --deep --verify` + `spctl -a -vv` pass.

### Task 9.2: Notarization
- `Scripts/notarize.sh`: `xcrun notarytool submit --apple-id emrekoch@gmail.com --team-id 2D7FVQV9WG --password "@keychain:notary-app-password"` → wait → `xcrun stapler staple`. (App-specific password stored in keychain, never in files/repo.)

### Task 9.3: DMG
- `Scripts/make-dmg.sh` (hdiutil/create-dmg), clean layout, signed + stapled. Verify mount → `spctl --assess --type open`.

### Task 9.4: Homebrew cask ✅ (confirmed)
- Own tap `alpico/homebrew-tap` with cask `cool-fan-control` (pin version + SHA), or submit upstream to homebrew-cask. README install: `brew install --cask alpico/tap/cool-fan-control`.

### Task 9.5: Public GitHub release
- Public repo (handle TBD — likely `emrekoch`), MIT license file, tag `v0.1.0`, attach DMG, release notes.

---

## Milestone 10 — Docs & release

### Task 10.1: Final docs
- `README.md`: features, install (DMG + brew), dev setup, architecture link. `Docs/architecture.md`, `AGENTS.md` (scope boundaries: M-series only, no Intel, no MAS, no telemetry, no charging control — fans only; TDD + scoped-commit conventions).

### Task 10.2: v0.1.0 tag + release notes
- Tag, attach notarized DMG, update `hardware-verification.md` with final results.

---

## Files likely to change (summary)

- New: everything under `~/cool-fan-control/` (layout above).
- External: none (system frameworks only: IOKit, IOPowerSources, XPC, SwiftUI).

## Verification strategy

- **Unit (no hardware):** codecs, packing, curve, hysteresis, override rules, presets, watchdog, Codable/XPC loopback → `Scripts/test.sh`.
- **Hardware (this M1 mini + MBP M1 Max, root):** `scripts/hardware-test.sh read|write|restore` + Milestone 8 checklist, every step documented with observed values.
- **Packaging:** codesign verify, spctl, notarytool result, stapled DMG, cask install on clean machine.

## Risks, tradeoffs, open questions

**Risks:**
1. ⚠️ **SMC interface locked on macOS 26 even as root** — unprivileged reads already return `kIOReturnUnsupported`; if root is also blocked, pivot: temps via `powermetrics` (root), fan-write path needs research. Milestone 0 gates everything.
2. **Battery temp key on M-series unconfirmed** (`TB0T` vs `BT0C`) — probed on MBP M1 Max in Milestone 0; fallback chain already in catalog.
3. `SMAppService.daemon` friction: must run from `/Applications`; re-register after updates.
4. SMC key names vary across M1–M5 → sensor fallback + discovery.
5. Overheating during manual tests → test at min RPM first, restore auto in a `trap`, never write above `F0Mx`.
6. No App Store (unsandboxed by design) — matches reference.

**Tradeoffs:**
- All SMC through root helper (more moving parts) vs. per-app root: helper is standard, safer, and required for reads on this OS.
- Smart curve computed in GUI vs helper: GUI keeps the rich UI; helper stays a dumb auditable writer; watchdog lives in helper.
- Battery cooling is **fans-only** (we do NOT pause/limit charging — that's macOS's domain via its own thermal management; note in README).

**Decisions — all confirmed (2026-08-25):** bundle id `com.alpico.coolfancontrol` · GitHub `emrekoch` · battery tiers 33 °C @ mid / 35 °C @ high (configurable) · MIT · macOS 14+ · cask ✅

---

## Execution handoff

When execution starts: `subagent-driven-development` — fresh subagent per task, two-stage review (spec compliance, then code quality). Milestone 0 requires Emre to run the root probe interactively (`sudo`) since this shell has no sudo access.
