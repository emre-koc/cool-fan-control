# Milestone 5 SMC Write Executor + Watchdog Gate — TDD Verification

Strict-TDD milestone (RED → minimal production → GREEN), completed 2026-08-26 on a
resumed (timed-out) milestone. This milestone adds the SMC write path: the pure
`FanWriteRequestBuilder`, the `SMCWriter` actor that re-verifies live metadata before
every write, the `WriteExecuting` seam (deliberately distinct from the read-only
executor), and the helper's `WatchdogGate` heartbeat restore decision.

Pure logic only: no IOKit write path, no root helper, no XPC, no UI. The production
`WriteExecuting` implementation and live root-write validation are deferred to the
helper milestone (Task 5.x); Core ships only the seam + scripted-fake-tested writer.

## Policy decisions

- **Manual writes never clamp.** A target outside the LIVE `[F{idx}Mn, F{idx}Mx]`
  limits is a typed `.targetOutOfBounds` error — the writer re-reads limits at apply
  time and never trusts construction-time bounds, never silently clamps
  (`testLiveOutOfBoundsTargetIsTypedErrorAndNeverClamped`, `testOutOfBoundsTargetIsTypedErrorNeverClamped`).
  Construction bounds (in `FanWriteCommand`) are a pre-filter; live bounds are the
  authority.
- **Restore semantics.** `restoreAutomatic()` writes `F{idx}Md = 0` for EVERY
  discovered fan (no target writes), validating each fan's `F{idx}Md` metadata before
  writing; fanless machines (`FNum == 0`) are a no-op. `apply` with a non-empty batch
  on `FNum == 0` is a typed `.fanCountZero` error and never writes.
- **Watchdog boundaries (uniform strictly-greater rule).** The gate restores ONLY when
  the silent interval STRICTLY exceeds the limit: `age == timeout` and `now == grace`
  are still armed. A heartbeat resets the timer; a heartbeat after a restore ends the
  restore; a regressed monotonic clock with no heartbeat restores immediately
  (fail-safe — age untrustworthy); a claimed heartbeat always resets even under a
  regressed clock (live ping is strongest liveness evidence). Defaults 30 s heartbeat
  timeout / 10 s startup grace, matching plan Task 5.5.
- **Separate write seam.** `WriteExecuting` mirrors `SMCExecuting`'s shape (explicit
  selector + wire image) but is a DISTINCT protocol: writes permit command 6
  (`WRITE_BYTES`), which the read-only executor/validator must never see. Tests pin
  that command 6 never reaches the reader (`testManualApplyExactCallSequence`,
  `testConcurrentAppliesAreCompleteAndNeverTouchReadExecutorWithWrites`).
- **Partial-write surfacing.** A manual sequence is `[F{idx}Md=1, F{idx}Tg=encoded]`.
  If `Md` lands and `Tg` fails, the writer throws `.partialWrite(committedFanIndex,
  failingKey, underlyingDescription)` — the caller MUST restore automatic control
  (`testPartialWriteFailureSurfacesWhenModeLandsButTargetFails`). A failure on the
  first write of a sequence passes through unwrapped (nothing committed).
- **Unknown live mode byte refuses.** A manual write is refused when the live
  `F{idx}Md` byte is neither 0 nor 1 (`.unknownMode`, `0xFF` when the caller had no
  live read); automatic writes ignore the live mode byte.
- **Encoding follows the fan's reported type.** `F{idx}Tg` payloads are encoded with
  SMCCodec using the type/size READ LIVE from the key (never inferred from the key
  name): `flt `/4 or `fpe2`/2, anything else is a typed `.unsupportedTargetDataType`.
- **Write-response acceptance.** Write responses are unmeasured on this host; the
  writer accepts the exact echoed key or the zero sentinel (mirroring measured read
  behavior) and maps driver result 132 → `.keyNotFound`. Live root-write validation is
  deferred to the helper milestone.

## RED

Tests authored before any implementation. The focused command exited 1 at the compile
stage — the production APIs did not exist. Captured log: `/tmp/m5-writer-red.log`
(captured 10:44:43; production files first written 10:44:50/10:45:13).

```sh
swift test --package-path Core --filter 'WatchdogGateTests|SMCWriterTests'   # exit 1 (compile)
```

Compiler reported missing symbols: `SMCWriter`, `SMCWriterError`, `SMCWriting`,
`WriteExecuting`, `WatchdogGate`, `WatchdogGateConfig`, `FanWriteRequestBuilder`
(plus secondary `type 'Any' cannot conform to 'Equatable'` / `reference to member
'writeBytes' cannot be resolved` notes at call sites — resolved once the typed API
landed; `error: emit-module command failed with exit code 1`).

## GREEN

Focused command:

```sh
swift test --package-path Core --filter 'WatchdogGateTests|SMCWriterTests'   # exit 0
```

**48 new tests, 0 failures** — `SMCWriterTests` 35, `WatchdogGateTests` 13. Coverage
highlights:

- Manual flt request → `[F0Md=1 (ui8), F0Tg=flt-encoded]`, exact bytes
  (2500.0 → `0x451C4000` little-endian); fpe2 fixture → `2000 * 4 = 8000 = 0x1F40`.
- Automatic → `[F0Md=0]` only, ignores garbage live mode byte / target metadata.
- Strict in-bounds: target at exact live min/max allowed; below/above → typed error,
  never clamped.
- `FNum == 0` → typed error for non-empty apply (never writes); restore is a no-op.
- Fan index out of range (positive and negative) → typed error, never writes.
- Unknown live mode byte (2, 0xFF, nil) → `.unknownMode`; known bytes (0, 1) accepted.
- Missing/unsupported target metadata (nil type; flt/2, fpe2/4, ui16/2, sp78/2) →
  typed errors.
- Live-metadata validation: invalid `FNum`/`F{idx}Mn`/`F{idx}Mx`/`F{idx}Md` metadata,
  negative live RPM, min > max → typed errors, never writes.
- Exact call sequences pinned: manual = 10 reader calls (2 per key × FNum/Mn/Mx/Md/Tg),
  2 write calls selector 2; automatic = 4 reader calls, 1 write; restore = 2 + 2N.
- Partial-write surfacing; first-call transport failure passes through; reader
  transport failure passes through; malformed 79-byte write response →
  `.malformedResponse(expected: 80, actual: 79)`.
- 20-way concurrent applies: 200 reader calls (never command 6), 40 write calls, all
  `.writeBytes`.
- Watchdog: grace strictly-greater restore (== armed), heartbeat keeps alive (age ==
  timeout armed), heartbeat resets, heartbeat after timeout ends restore, first
  heartbeat during grace switches domains, future-clock restore, regressed-clock
  heartbeat resets, `reset()` re-applies grace, custom config, default config values,
  Equatable + deterministic replay, Sendable assertions.

**Test-only fix during GREEN (no implementation change):**
`testConcurrentAppliesAreCompleteAndNeverTouchReadExecutorWithWrites` originally
asserted the write stream was exactly `[F0Md, F0Tg] × 20` in strict per-apply order.
Under 20 concurrent applies this is not guaranteed and is not a bug: `SMCWriter` is a
reentrant actor that suspends at each `write`, so applies interleave at the batch
level — whole-batch serialization across concurrent callers is explicitly the helper
milestone's composition concern (per the `SMCWriter` doc comment). The assertion was
replaced with the guarantees the design DOES make: 40 write calls, all `.writeBytes`,
exactly 20 `F0Md` + 20 `F0Tg`, and the prefix property that a target write never
precedes its own mode write (plus the unchanged reader-side assertions). No assertion
weakened — the impossible strict-order one was corrected, mirroring the m5
`testResetClearsState` reorder precedent.

Strict concurrency:

```sh
swift test --package-path Core -Xswiftc -strict-concurrency=complete   # exit 0
```

Result: **345 tests executed, 0 failures** with Swift 6 complete concurrency checking.

Full repository validation:

```sh
scripts/test.sh   # exit 0
```

Result:
- Python contracts: **5 tests, OK**
- Core: **345 tests, 0 failures** (297 prior + 48 new)
- `CoolFanControl` native macOS build: **BUILD SUCCEEDED**
- `helperd` native macOS build: **BUILD SUCCEEDED**

`git diff --check` (with intent-to-add over the 5 new files — two sources, two test
suites, and this document) reports no whitespace errors. All changes left
uncommitted (no commit/push per task).

### Error propagation on the privileged path

`SMCCodecError` values raised while decoding a live RPM or encoding a `Tg`
payload (for example `nonFiniteFloat` from a garbage `flt ` payload, or
`invalidEncodeValue` for a non-representable `fpe2` target) propagate unwrapped,
alongside transport errors — they are typed, `Equatable`, `Sendable`, occur
**before** the failing command is written, and are covered by the
restore-on-any-failure contract. This matches the documented "transport errors
pass through unwrapped" surface; a uniform wrapper is deferred unless the helper
boundary needs one.

## Deferred to the helper milestone

- Production `WriteExecuting` implementation (serialized root connection; validates
  selector 2 and wire length; permits commands {5, 6, 8, 9}).
- Live root write validation: response key behavior, result/status mapping, and
  `Md=1`/`Tg` round-trip on real hardware (`scripts/hardware-test.sh`, root).
- Whole-batch serialization across concurrent callers.

## Files

- `Core/Sources/FanControlCore/SMCWriter.swift` (new) — `WriteExecuting` seam,
  `SMCWriting` protocol, `SMCWriterError`, `FanWriteRequestBuilder`, `SMCWriter` actor.
- `Core/Sources/FanControlCore/WatchdogGate.swift` (new) — `WatchdogGateConfig` +
  `WatchdogGate` pure heartbeat gate.
- `Core/Tests/FanControlCoreTests/SMCWriterTests.swift` (new) — 35 tests + scripted
  reader/writer fakes.
- `Core/Tests/FanControlCoreTests/WatchdogGateTests.swift` (new) — 13 tests.
- `Docs/milestone-5-smc-write-executor-tdd-verification.md` (new) — this document.

No changes to existing files. No repo artifacts; changes left uncommitted.
