# Milestone 5 Control Service + Write Throttling — TDD Verification

Strict-TDD milestone (RED → minimal production → GREEN), completed 2026-08-26.
This milestone adds the write path: validated fan write commands, per-fan write
rate limiting, and the `ControlService` tick that composes all readers, the pure
engine, throttling, and the write-target seam.

## Policy decisions

### Throttle semantics (`WriteThrottle`)
Pinned by `WriteThrottleTests` (23 tests) and enforced per fan by the service:

- **First command of any kind** → `.send` immediately (no interval or change
  gate — the first write must never be suppressed).
- **Clock anomaly** — `now < lastSentAtNanos` (monotonic regression) → `.skip`,
  never a write, including restores.
- **Automatic proposals (`nil`)** — sent when nothing was ever sent or when the
  last *sent* command was manual (a restore is safety-critical and never
  rate-limited); skipped when the last sent command was already automatic
  (**auto-only-once**: repeated automatic commands collapse until something
  changes).
- **Manual proposals** — after the first send the interval gate applies
  (`now - lastSentAt >= minimumIntervalNanos`, exact elapsed `>=` sends); then:
  - mode changed (auto → manual): change gate against the caller-supplied
    `previousRPM` (the *actual* fan RPM — the best reference after Apple takes
    over); `|Δ| >= minimumChangeRPM` sends, else skip (a trivial switch is not
    worth yanking control from Apple for). Nil/non-finite reference cannot
    prove redundancy → send.
  - same mode (manual → manual): change gate against the last written target;
    `|Δ| >= minimumChangeRPM` **sends at exact equality**, else skip. Equal
    target and mode → always skip.
- `minimumChangeRPM == 0` disables the change gate entirely (equal targets send
  once the interval has elapsed — caller opted out).
- Skips never advance `lastSentAtNanos` — the interval is measured from the
  last *send*.
- Defaults: interval 2 s, minimum change 100 RPM. Config is `Codable` with
  decode-time validation (invalid persisted values throw, never trap).

### Auto-command policy (service level)
- `auto` mode → the engine yields nil effective targets; the service proposes an
  automatic restore. The throttle's auto-only-once policy means the first tick
  emits `.restoreAutomatic` and repeated ticks emit `.none` until something
  changes (mode switch, manual command, fail-safe).
- `manual`/`smart`/`quiet`/`max` → a validated `FanWriteCommand` per fan
  (clamped by the engine to the fan's own `[min, max]`, so command construction
  cannot fail; a defensive failure degrades to a restore, never a crash).
- Fanless (empty fan snapshot) → no fan commands at all; an empty apply batch is
  still delivered each tick.

### Fail-safe chain (never a stale manual target)
Pinned by `ControlServiceTests` — any reader failure or a fully-stale thermal
snapshot restores Apple automatic for every known fan:

1. **Fan-read failure** → `.fanReadFailed(reason:)`; every fan from the last
   successful discovery is restored to automatic. With no fans ever known there
   is nothing to restore and no writes (empty apply).
2. **Thermal transport failure** → `.thermalSourceFailed(reason:)`; every
   current fan is restored to automatic.
3. **Stale-all thermal** → `.staleAllThermal`; every current fan is restored.
   Detection: the snapshot carries *raw readings* but zero fresh ones (a `.stale`
   diagnostic with an empty `readings` array). A **valid-but-empty** snapshot
   (no raw readings at all) is NOT a failure — engine semantics apply (CPU
   guard releases on nil CPU; smart hysteresis holds its last target).
4. Fail-safe restores run through each fan's `WriteThrottle`, so they are never
   rate-limited out of existence (manual → automatic always sends) and the
   throttle state stays coherent across the failure/recovery cycle — on
   recovery the manual target is re-asserted against the actual RPM
   (`testRecoveryAfterFanFailureReassertsManual`).

### Smart-curve input (CPU-inclusive hottestControl)
The smart curve is driven by the **hottest valid allowlisted CPU, GPU, or SoC
IOHID reading** — `thermal.hottestControl`, CPU included (confirmed by spec
review; see the correction section below). The CPU throttle guard stays an
independent safety layer on the hottest pACC/eACC reading
(`thermal.hottestCPU`, 90 °C engage / 88 °C release, its own hysteresis).
Pinned by `testCPUHeatDrivesCurveBelowGuardThreshold` (pACC 85 °C → the curve
ramps to the default curve's max point 4499 RPM while the guard is NOT engaged,
since 85 < 90) and `testThermalNilGuardReleasesAndSmartHolds` (pACC 95 °C →
curve input saturates at fan max AND the guard engages → effective max; on a
nil-CPU tick the guard releases and the smart hysteresis holds its last
CPU-driven target).

### Test-only fix (one, justified)
`testResetClearsState`: the three `XCTAssertNil` state checks ran *after* a tick
that returns `.send` — a send records `lastSentAtNanos`/`lastSentMode`/
`lastSentTargetRPM` by definition, so nil-after-send is objectively impossible
(and would break the interval gate, which measures from the last send). Moved
the nil checks to immediately after `reset()`, preserving every assertion and
the test's intent (reset clears state; the next tick is treated as the first
command). No production behavior was weakened.

## RED

All three suites were written first and confirmed failing to compile. Evidence
logs (missing-symbol failures, 563 error lines each — same compile failure
captured per suite):

- `/tmp/m5-writecommand-red.log`
- `/tmp/m5-throttle-red.log`
- `/tmp/m5-service-red.log`

Missing symbols (identical across all three runs):

```
cannot find type 'FanWriteCommand' in scope        (WriteCommand.swift existed but was never compiled/verified)
cannot find type 'FanWriteCommandError' in scope
cannot find type 'WriteThrottle' in scope          (WriteThrottle.swift existed but was never compiled/verified)
cannot find type 'WriteThrottleConfig' in scope
cannot find type 'ControlService' in scope         (file was missing entirely)
cannot find type 'ControlState' in scope
cannot find type 'FanWriteAction' in scope
cannot find type 'FanWriteTargets' in scope
```

Example (service log):

```
Core/Tests/FanControlCoreTests/ControlServiceTests.swift:39:45: error: cannot find type 'FanWriteTargets' in scope
Core/Tests/FanControlCoreTests/ControlServiceTests.swift:40:37: error: cannot find type 'FanWriteAction' in scope
```

Production added this milestone:

- `Core/Sources/FanControlCore/ControlService.swift` (new — the whole service:
  `ControlService` actor, `Config`, `ControlState`, `FanControlState`,
  `FanWriteAction`, `FanWriteTargets`, `ControlFailure`).

## GREEN

Focused suites (the milestone's fixed contract; counts include the
spec-review correction — ControlServiceTests 15 → 16):

```
Test Suite 'WriteCommandTests'   passed — 21 tests, 0 failures
Test Suite 'WriteThrottleTests'  passed — 23 tests, 0 failures
Test Suite 'ControlServiceTests' passed — 16 tests, 0 failures
                                           60 tests, 0 failures
```

Strict concurrency (full package):

```
swift test --package-path Core -Xswiftc -strict-concurrency=complete
Executed 297 tests, with 0 failures (0 unexpected)
```

Full gate: `scripts/test.sh` — Python contract tests 5/5 OK; full Core suite
297 tests, 0 failures; `bootstrap.sh` OK; Debug `xcodebuild` for the app and
helperd schemes (`CODE_SIGNING_ALLOWED=NO`) both `BUILD SUCCEEDED`; script
exit 0. Log: `/tmp/m5-full-test.log`.

Hygiene: `git diff --check` clean (tracked + untracked milestone files); all
milestone files remain uncommitted (7 untracked files), per the working
agreement.

## Files

- `Core/Sources/FanControlCore/WriteCommand.swift` — pre-existing (unverified);
  now compiled and exercised by `WriteCommandTests`.
- `Core/Sources/FanControlCore/WriteThrottle.swift` — pre-existing (unverified);
  now compiled and exercised by `WriteThrottleTests`.
- `Core/Sources/FanControlCore/ControlService.swift` — new this milestone.
- `Core/Tests/FanControlCoreTests/WriteCommandTests.swift` — RED tests (kept).
- `Core/Tests/FanControlCoreTests/WriteThrottleTests.swift` — RED tests (kept;
  one assertion-order fix, see policy above).
- `Core/Tests/FanControlCoreTests/ControlServiceTests.swift` — RED tests (kept).
- `Docs/milestone-5-control-service-tdd-verification.md` — this document.

## Spec-review correction (2026-08-26, post-milestone)

### The deviation
The service originally fed the engine `hottestControlCelsius` from a private
`curveInputCelsius(from:)` helper that scanned `thermal.readings` for the
hottest control candidate **excluding CPU** (`isControlCandidate &&
!isCPU` — SOC/GPU only), with a comment justifying it as "CPU heat is owned by
the throttle guard … would double-drive the fan on CPU bursts". That policy was
**self-authored by the earlier milestone agent** and recorded only in this
doc's "Policy decisions" section — it was never approved by the product spec.
An independent spec review rejected it: the confirmed contract (founding
research + Emre) is that the smart curve input is the **hottest valid
allowlisted CPU, GPU, or SoC IOHID reading — CPU included** — i.e.
`thermal.hottestControl`, which the m3 builder already computes CPU-inclusively
(`isControlCandidate` includes pACC/eACC, pinned by `ThermalReaderTests`). The
`FanControlEngine.tick(hottestControlCelsius:)` docs ("CPU/GPU/SOC") and
`TrustedThermalSnapshot.hottestControl` docs ("CPU/GPU/SOC only, never PMGR")
were already CPU-inclusive; only `ControlService` deviated. The throttle guard
behavior is unchanged: it remains on the hottest pACC/eACC reading
(`thermal.hottestCPU`), engage ≥ 90 °C, release < 88 °C.

### RED (tests first — pinned the confirmed policy, then observed the failure)
Rewrote `testThermalNilGuardReleasesAndSmartHolds` (held target 2944 → 4499,
throttle-collapsed `.none` on the equal held target) and added
`testCPUHeatDrivesCurveBelowGuardThreshold` (pACC 85 °C → curve max 4499 with
the guard NOT engaged). All other tests untouched. Against the unmodified
production:

```
swift test --package-path Core --filter ControlServiceTests
# exit 1 — Executed 16 tests, with 6 failures (0 unexpected)
```

The 6 failures were the deviation in action: pACC 85 °C drove the curve to
1700 RPM (SOC 40 °C input) instead of 4499, and the nil-CPU tick held 2944
(curve@SOC-60) instead of the CPU-driven 4499. Log:
`/tmp/m5-curve-correction-red.log`.

### GREEN (minimal production fix)
Deleted the CPU-excluding `curveInputCelsius(from:)` helper and fed
`hottestControlCelsius: thermal.hottestControl?.celsius` (CPU-inclusive).
Throttle, fail-safe, battery, and guard behavior untouched.

```
swift test --package-path Core --filter 'WriteCommandTests|WriteThrottleTests|ControlServiceTests'
# exit 0 — WriteCommandTests 21, WriteThrottleTests 23, ControlServiceTests 16 = 60 tests, 0 failures
swift test --package-path Core -Xswiftc -strict-concurrency=complete
# exit 0 — Executed 297 tests, with 0 failures (0 unexpected)
scripts/test.sh   # exit 0 — Python 5/5, Core 297/297, app + helperd BUILD SUCCEEDED ×2
git diff --check  # clean
```

Logs: `/tmp/m5-curve-correction-green.log`, `/tmp/m5-curve-correction-strict.log`,
`/tmp/m5-curve-correction-full.log`. All 7 milestone files remain uncommitted.
