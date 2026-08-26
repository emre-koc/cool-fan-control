# Milestone 4 Safety Overrides + Battery Status — TDD Verification

Date: 2026-08-26
Scope: Battery status model + public IOPowerSources mapping, the two-tier battery cooling rule, the CPU throttle guard, and the effective-target composition rule. Pure-logic core only — **no fan writes, no helper/XPC, no UI, no IOKit SMC writes**. No hardware write validation (Mac mini has no battery); live validation is read-only via IOPowerSources.

## Policy decisions

- **`BatteryState`** is `Equatable`/`Sendable`/`Codable`: `isPresent`, `isCharging`, `chargePercent: Double?`, `temperatureC: Double?`. `temperatureC` is **never fabricated** by IOPowerSources — the production monitor always leaves it nil; a validated SMC `TB0T`/`BT0C` reading (helper-side, Milestone 5) is the only future source. Cooling is fans-only; the model is purely observational and carries no charging/power commands.
- **IOPS mapping (pure `IOPowerSourcesBatteryMapper`):**
  - `IOPSCopyPowerSourcesList` empty / nil blob / nil list → `isPresent = false` (desktop/no-battery case).
  - `kIOPSIsPresentKey` honored when present; missing treated as present (internal batteries may omit it).
  - `isCharging = ("Is Charging" == true) && state != "Battery Power"` — matches plan policy "AC power + charging"; the flag is meaningless on battery power.
  - `chargePercent = clamp(100 × Current Capacity / Max Capacity, 0...100)`; nil when capacity keys are missing or max ≤ 0. First source in the list wins (laptops expose exactly one internal battery).
  - **Real CF shapes:** tests build genuine `CFDictionary` values with CFString keys (`as CFDictionary` bridging of `[String: AnyObject]`), so the exact bridging code path (`as NSDictionary` → `as? Bool/Int/String`) is exercised without hardware.
- **Production monitor** wraps the **public** IOPowerSources API — `IOPSCopyPowerSourcesInfo` / `IOPSCopyPowerSourcesList` / `IOPSGetPowerSourceDescription`. On this SDK the API lives in IOKit's public `ps` submodule (`import IOKit.ps`); no separate framework link needed (IOKit already linked in `Package.swift`). Copy functions return `Unmanaged` and are bridged with `takeRetainedValue()`; the Get function's description is bridged with `takeUnretainedValue()` (owned by the blob). All CF values are created, used, and released inside **one synchronous scope** — Swift ARC manages them, no manual `CFRelease`. Unprivileged (no root).
- **Battery cooling rule** (`BatteryCoolingRule`, stateful, hysteretic, two-tier, charging-only):
  - Rising: `<= midEngage` (33 °C) → off; `> midEngage` → mid; `> highEngage` (35 °C) → high (from any lower state, including direct off→high).
  - Falling: high releases only `< highRelease` (33 °C) → mid; mid releases only `< midRelease` (31 °C) → off. Exact boundaries: 33.0 rising = off; 35.0 = mid; 33.0 falling from high = still high; 31.0 falling from mid = still mid.
  - Not charging → off immediately (unplug releases regardless of temperature). Missing/non-finite temperature → off (reset); **missing data is never interpreted as hot**.
  - Mid target policy-exact: `F0Mn + (F0Mx − F0Mn)/2`, **floored** (M1 mini reference 1700/4499 → 3099), computed from each fan's *provided* min/max on every `decision`. High target = fan maximum. Both overridable via `midRPM`/`highRPM`.
  - Thresholds configurable (`midEngageC`/`highEngageC`/`midReleaseC`/`highReleaseC`, defaults 33/35/31/33); preconditions: release ≤ engage per tier, midEngage ≤ highEngage.
- **CPU throttle guard** (`CpuThrottleGuard`): engages at `>= engageC` (90 °C), releases only `< releaseC` (88 °C). Exact boundaries: 89.9 no; 90.0 yes; 88.1 stays; **88.0 stays** (release is *below* 88); 87.9 releases. nil or non-finite `hottestCPU` → release; **missing data never hot and never cold**. Configurable 90/88 defaults.
- **Effective target** (`EffectiveTargetRule`): `effective = max(modeTarget, cpuGuardTarget, batteryTarget)` over non-nil targets, clamped to `[min, max]`; all nil → nil (auto mode, no write). `min <= max` preconditioned; equal min/max allowed.
- State machines are deterministic value types with Equatable state (`tier`, `engaged`), `reset()`, and replay-identical behavior; all models/protocols `Sendable` under Swift 6 complete concurrency.

## RED

Tests authored before any implementation. Focused commands exited 1 — the APIs did not exist. Captured logs: `/tmp/battery-red.log`, `/tmp/override-red.log`.

```sh
swift test --package-path Core --filter BatteryStateTests   # exit 1
swift test --package-path Core --filter OverrideRulesTests  # exit 1
```

Compiler reported missing symbols: `IOPowerSourcesBatteryMapper`, `BatteryStatusProviding`, `BatteryState`, `IOPowerSourcesBatteryMonitor`, `BatteryCoolingRule`, `CpuThrottleGuard`, `EffectiveTargetRule`, and the `kIOPS*` constants (`kIOPSCurrentCapacityKey`, ...). Because the parameter types did not exist yet, Swift also emitted secondary `'nil' requires a contextual type` errors at call sites — all resolved once the typed API landed.

## GREEN

Focused commands:

```sh
swift test --package-path Core --filter BatteryStateTests    # 17 tests, 0 failures
swift test --package-path Core --filter BatteryCoolingRuleTests  # 23 tests, 0 failures
swift test --package-path Core --filter CpuThrottleGuardTests    # 11 tests, 0 failures
swift test --package-path Core --filter EffectiveTargetRuleTests # 11 tests, 0 failures
```

**62 new tests, 0 failures.** Coverage highlights:

- **Exact hysteresis sequence** (must-pass): rising 32.9→off, 33.1→mid, 35.1→high; falling 33.1→still high, 32.9→mid, 31.1→mid, 30.9→off; unplug while engaged (`.high` at 36 °C) → off immediately.
- Not charging never overrides even at 40/45/50/60 °C; charging-stopped-mid-engagement releases.
- Exact boundaries: 33.0 off; 35.0 mid; 33.0 from high holds; 31.0 from mid holds; mid holds within the hysteresis band (34→32.5→33.8); rising direct off→high at 36; mid→high at 35.1.
- Missing/non-finite temperature never engages and **resets** an engaged rule (36 °C → high, then nil → off).
- Decisions: mid = 3099 (floored midpoint 1700/4499) and 3000 for 2000/4000; high = 4499; off → inactive; configured `midRPM`/`highRPM` honored; `midPointRPM` exact policy.
- Custom thresholds honored (27/30 engage, 25/27 release, full rising/falling sweep).
- CPU guard: 89.9 no → 90.0 yes → 88.1/88.0 stays → 87.9 releases; re-engage; nil/non-finite release from engaged and never engage from nil; `decision` forces fan max only when engaged; custom 85/80 config honored.
- Effective target: all-nil → nil; single target below min clamps to min, above max clamps to max; CPU guard > battery > mode ordering via max; equal min/max allowed; exact at-min/at-max.
- Config defaults per spec (33/35/31/33; 90/88), Codable round-trips, Equatable state + `reset()`, deterministic replay (two rules fed identical inputs stay equal), Sendable assertions on every model/protocol/fake.

One test-expectation fix during GREEN (not an implementation change): after `.high`, a tick at 30 °C yields `.mid` first (release is `< 33`), not `.off` — the test now walks the real release path (32.9 → mid, 30.9 → off) as the spec sequence does.

Strict concurrency:

```sh
swift test --package-path Core -Xswiftc -strict-concurrency=complete
```

Result: **156 tests executed, 0 failures** with Swift 6 complete concurrency checking.

Full repository validation:

```sh
scripts/test.sh
```

Result:

- Python contracts: **5 tests, OK**
- Core: **156 tests, 0 failures** (94 prior + 62 new)
- `CoolFanControl` native macOS build: **BUILD SUCCEEDED**
- `helperd` native macOS build: **BUILD SUCCEEDED**

`git diff --check` reports no whitespace errors. All changes left uncommitted.

## Live read-only battery check (unprivileged, twice)

A temporary `/tmp/live-battery.swift` harness instantiated the production `IOPowerSourcesBatteryMonitor()`, compiled with Swift 6 complete concurrency checking and IOKit, run without `sudo` (euid 501):

```sh
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  Core/Sources/FanControlCore/*.swift /tmp/live-battery.swift \
  -framework IOKit -o /tmp/live-battery
/tmp/live-battery
```

Run 1 (`/tmp/battery-live-run1.txt`) and Run 2 (`/tmp/battery-live-run2.txt`, ~1 s later) both reported:

```text
HARNESS euid=501 isPresent=false isCharging=false chargePercent=nil temperatureC=nil
```

The `isPresent=false` path is asserted (this M1 Mac mini has no battery; `IOPSCopyPowerSourcesList` returns an empty list). Sanity cross-check: `pmset -g batt` reports `Now drawing from 'AC Power'` with no battery line — consistent with a battery-less desktop. Battery-*present* mapping is validated purely via the real-CF-dictionary unit tests (charging on AC, plugged-and-full, on-battery-power never charging, missing capacities, Is Present false, percent clamping, first-source precedence). Real battery-temperature charging-cooling behavior remains a hardware checklist item for Emre's M1 Max MacBook Pro (Milestone 8).

## Files

- `Core/Sources/FanControlCore/BatteryMonitor.swift` (new) — `BatteryState`, `BatteryStatusProviding`, pure `IOPowerSourcesBatteryMapper`, production `IOPowerSourcesBatteryMonitor` (`import IOKit.ps`, one synchronous ARC-managed CF scope).
- `Core/Sources/FanControlCore/OverrideRules.swift` (new) — `OverrideDecision`, `BatteryCoolingConfig`/`BatteryCoolingTier`/`BatteryCoolingRule`, `CpuThrottleGuardConfig`/`CpuThrottleGuard`, `EffectiveTargetRule`.
- `Core/Tests/FanControlCoreTests/BatteryStateTests.swift` (new) — 17 tests (model, Codable, Sendable, async fake provider, production-monitor conformance incl. desktop `isPresent=false`, 10 real-CF-shape mapper tests).
- `Core/Tests/FanControlCoreTests/OverrideRulesTests.swift` (new) — 45 tests (23 battery rule, 11 CPU guard, 11 effective target).
- `Docs/milestone-4-safety-overrides-tdd-verification.md` (new) — this document.
- `Package.swift` unchanged (IOKit already linked; IOPS symbols come from its public `ps` submodule). No repo artifacts; changes left uncommitted.
