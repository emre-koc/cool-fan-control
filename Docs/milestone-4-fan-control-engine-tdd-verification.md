# Milestone 4 Fan Control Engine (Pure Core) — TDD Verification

Date: 2026-08-26
Scope: `FanMode`, `TemperatureCurve`, `HysteresisController`, and `FanControlEngine` (Tasks 4.1–4.3). Pure-logic core only — **no fan writes, no helper/XPC, no UI, no IOKit**. All state machines are deterministic value types with injectable inputs and zero wall-clock dependencies.

## Policy decisions

- **`FanMode`** (`auto` / `smart` / `manual(rpm: Int)` / `quiet` / `max`), `Equatable`/`Sendable`/`Codable`. Persisted as **stable JSON** via a custom codec: `{"mode":"manual","rpm":1200}` — the `mode` string is versioned so future modes never renumber anything; unknown mode strings and a missing `rpm` for `manual` are decode errors. `fixedTarget(minimumRPM:maximumRPM:)` maps `quiet` → fan min, `max` → fan max, `manual` → its RPM **raw** (composition clamps it to the fan's `[min, max]`), `auto`/`smart` → nil.
- **`TemperatureCurve`**: ordered `[CurvePoint]` (temperature °C → RPM), piecewise-linear `rpm(at:)`, clamped to `[minimumRPM, maximumRPM]`. Default `TemperatureCurve.default(minimumRPM:maximumRPM:)` = 40 °C → fan min, 85 °C → fan max (fan-specific because bounds are per-fan). Below-first / above-last clamp to the endpoint RPM. **Caller-provided bounds override stored bounds** (`rpm(at:clampedToMinimum:clampedToMaximum:)`) so the engine can drive every fan with one shared curve, clamping per fan.
  - **Validation split:** *points* are persisted user configuration → **typed errors** (`TemperatureCurveError.emptyPoints` / `.nonFiniteTemperature` / `.nonFiniteRPM` / `.nonIncreasingTemperatures`); strictly-increasing finite temperatures required, empty and non-finite rejected. *Bounds* are code invariants (finite, non-negative, min ≤ max) → **preconditions**, matching `BatteryCoolingConfig`/`EffectiveTargetRule` convention. Decoding runs the same validation as `init`.
  - `rpm(at:)` preconditions a finite temperature — missing/non-finite temperature handling is a keep-last policy owned by the controller/engine, not the curve.
- **`HysteresisController`** (anti-hunt, pure): stateful `currentTarget`; `tick(desired:)` where `desired` = curve output (the engine performs the curve lookup, keeping the controller a minimal value-type state machine):
  - First tick initializes `currentTarget` to `desired`.
  - **Rising:** `desired > currentTarget` → follow immediately (no band on the way up — heat must be answered without delay). Equality → no change.
  - **Falling:** step down only when `desired < currentTarget − band`, `band = currentTarget × bandFraction`. **Default band = 5 % of the current target** (`HysteresisConfig.bandFraction = 0.05`, configurable 0...1). **Exact boundary semantics: `desired == currentTarget − band` → NO change** (strictly below). This is the anti-hunt property.
  - **Missing/non-finite `desired` → keep the last target** (no change). `reset()` clears state.
  - **Min-change gate decision:** the plan's Task 4.3 gate (`|new − current| ≥ 100 RPM` AND `≥ 2 s since last write`) requires a wall clock. The task spec makes it optional with a "no wall clock" default, so **the pure engine implements no min-change gate**; the RPM+time write-throttle is an app-layer policy (AppState, Milestone 6) applied after the engine produces targets. The hysteresis band alone already prevents hunting.
- **`FanControlEngine`** (pure orchestrator): one `tick(...)` per control cycle that (1) advances the caller-owned `BatteryCoolingRule` and `CpuThrottleGuard` (inout — every state transition happens in one deterministic pass; the caller keeps the rule objects for UI badges), then (2) per fan computes the mode target and composes it through the **existing `EffectiveTargetRule`** — `effective = max(modeTarget, cpuGuardTarget, batteryTarget)` over non-nil targets, clamped to the fan's `[min, max]`, all nil → nil (Apple auto, no write). `OverrideDecision`/`BatteryCoolingRule`/`CpuThrottleGuard`/`EffectiveTargetRule` are reused verbatim from `OverrideRules.swift` — not reimplemented.
  - Mode → target: `smart` → curve through a per-fan `HysteresisController` (state keyed by fan index, survives mode switches); `manual(rpm)` → fixed RPM; `quiet` → min; `max` → max; `auto` → nil.
  - **Missing-input policy (pinned by tests):** nil **or non-finite** `hottestControlCelsius` in smart mode → hysteresis keeps its last target; **missing data is never interpreted as cold** (no drop to min). A target never initialized → nil → no write (Apple auto, the safe default). This is separate from `CpuThrottleGuard`'s own release-on-missing policy, which already exists. The trusted snapshot already gates plausibility (10 < T ≤ 120) upstream in `TrustedThermalSnapshotBuilder`; the engine trusts what it is given.
  - Safety overrides apply in **any** mode, including `auto` (CPU guard forces max even when Apple auto is selected).
  - Deterministic, no randomness, no wall clock; `Equatable` state, `reset()` (hysteresis only — caller resets rules), `currentTarget(fanIndex:)` accessor for UI.

## RED

Tests authored before any implementation. Focused commands exited 1/134 — the APIs did not exist. Captured log: `/tmp/fan-engine-red.log`.

```sh
swift test --package-path Core --filter FanModeTests            # exit 134 (compile)
swift test --package-path Core --filter TemperatureCurveTests   # exit 134 (compile)
swift test --package-path Core --filter HysteresisControllerTests # exit 134 (compile)
swift test --package-path Core --filter FanControlEngineTests   # exit 134 (compile)
```

Compiler reported missing symbols: `FanMode`, `CurvePoint`, `TemperatureCurve`, `TemperatureCurveError`, `HysteresisConfig`, `HysteresisController`, `FanBounds`, `FanTarget`, `FanControlEngine` (with secondary `type 'Any' cannot conform to 'Equatable'` notes at call sites — all resolved once the typed API landed).

## GREEN

Focused commands:

```sh
swift test --package-path Core --filter FanModeTests            # 10 tests, 0 failures
swift test --package-path Core --filter TemperatureCurveTests   # 19 tests, 0 failures
swift test --package-path Core --filter HysteresisControllerTests # 17 tests, 0 failures
swift test --package-path Core --filter FanControlEngineTests   # 30 tests, 0 failures
```

**76 new tests, 0 failures.** Coverage highlights:

- **FanMode:** Codable round-trip of all five cases; stable JSON shape (`mode`/`rpm` keys); decodes known JSON; unknown mode rejected; `manual` without `rpm` rejected; `quiet`→min / `max`→max / `manual`→raw RPM / `auto`+`smart`→nil; Sendable.
- **Curve:** default points exactly `[(40, min), (85, max)]` with endpoints and exact midpoint (62.5 °C → 3099.5 RPM = 1700 + 2799×0.5); exact midpoint/quarter-point interpolation (25 °C → 150 on 20/100–30/200); exact point values; below-first/above-last clamps; output clamped to stored bounds (1700/4499 points under 2000–4000 bounds → 2000/4000, midpoint unchanged); caller-provided bounds override stored; single-point curve allowed; typed rejections (empty, equal temps, decreasing temps, NaN/∞ temperature, NaN/∞ RPM); Codable round-trip; **decode of empty-points JSON throws** (validation applied on decode); Sendable.
- **Hysteresis:** first-tick init (incl. nil first tick staying uninitialized); rising follows immediately; rising equality holds; falling within band holds (desired == current − band → **no change**, strictly-below semantics pinned at 1425 vs 1424.9 with band 75); custom bandFraction (0.1, 0) honored; nil and non-finite desired keep last target; reset clears and re-initializes; deterministic replay; Equatable state; config default 0.05 + Codable; Sendable.
- **Engine composition:** auto → nil targets (no write); **CPU guard overrides auto**; empty fan list → no targets; quiet→min, max→max, manual inside → unclamped, manual 500 → 1700, manual 9000 → 4499; **two fans with differing ranges** ([1700,4499] + [2000,4000]) clamped per fan for manual/quiet/max; smart curve endpoints and exact midpoint through the engine; **anti-hunt**: ramp to max, hold at 84 °C (desired 4436.8 within band), step down at 80 °C (4188 < boundary 4274.05), 20-tick ±1 °C oscillation never leaves max; **nil/non-finite control temp keeps last target** (2944 at 60 °C, held on nil/NaN/∞ — missing data never interpreted as cold); first-tick nil control → nil (no write); hysteresis state survives mode switches; one curve drives two fans with per-fan clamps; CPU guard beats smart, release restores mode target; battery mid (3099) beats quiet (1700); max beats battery mid; max vs battery high equal at 4499; unplug releases battery rule → quiet min returns; engine advances both rule state machines (tier/engaged observable after tick); custom engine hysteresis band (0.2 vs 0.05) changes the step-down point; Equatable + `reset()` + `currentTarget(fanIndex:)`; deterministic replay (two engines + two rule pairs, identical input sequence → identical targets and rule states); Config default 0.05 + Codable; Sendable everywhere.

No implementation changes were needed during GREEN beyond the initial API surface (one label fix: the engine calls the existing `BatteryCoolingRule.tick(isCharging:batteryTempC:)`).

Strict concurrency:

```sh
swift test --package-path Core -Xswiftc -strict-concurrency=complete
```

Result: **233 tests executed, 0 failures** with Swift 6 complete concurrency checking.

Full repository validation:

```sh
scripts/test.sh
```

Result:
- Python contracts: **5 tests, OK**
- Core: **233 tests, 0 failures** (157 prior + 76 new)
- `CoolFanControl` native macOS build: **BUILD SUCCEEDED**
- `helperd` native macOS build: **BUILD SUCCEEDED**

`git diff --check` reports no whitespace errors. All changes left uncommitted (no commit/push per task).

## Files

- `Core/Sources/FanControlCore/FanMode.swift` (new) — `FanMode` with stable-key Codable and `fixedTarget(minimumRPM:maximumRPM:)`.
- `Core/Sources/FanControlCore/TemperatureCurve.swift` (new) — `CurvePoint`, `TemperatureCurveError`, `TemperatureCurve` (validating init + decoding, defaults, piecewise-linear lookup with stored or caller-provided clamp bounds).
- `Core/Sources/FanControlCore/HysteresisController.swift` (new) — `HysteresisConfig` (5 % default band) + `HysteresisController` (pure anti-hunt state machine).
- `Core/Sources/FanControlCore/FanControlEngine.swift` (new) — `FanBounds`, `FanTarget`, `FanControlEngine` (pure orchestrator; composes through existing `EffectiveTargetRule`).
- `Core/Tests/FanControlCoreTests/FanModeTests.swift` (new) — 10 tests.
- `Core/Tests/FanControlCoreTests/TemperatureCurveTests.swift` (new) — 19 tests.
- `Core/Tests/FanControlCoreTests/HysteresisControllerTests.swift` (new) — 17 tests.
- `Core/Tests/FanControlCoreTests/FanControlEngineTests.swift` (new) — 30 tests.
- `Docs/milestone-4-fan-control-engine-tdd-verification.md` (new) — this document.

No changes to existing files. No repo artifacts; changes left uncommitted.
