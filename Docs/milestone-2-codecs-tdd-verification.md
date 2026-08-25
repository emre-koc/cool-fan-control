# Milestone 2 SMC Codecs — TDD Verification

Date: 2026-08-25

Scope: pure SMC byte codecs in the Core SwiftPM package only. No IOKit transport, key enumeration, fan discovery, policy, helper/XPC, or UI work is included.

## RED — tests written first

Added `Core/Tests/FanControlCoreTests/SMCCodecTests.swift` before adding any production codec API.

Exact command executed:

```sh
swift test --package-path Core --filter SMCCodecTests 2>&1 | tee /tmp/milestone-2-red.log; test ${PIPESTATUS[0]} -ne 0
```

Result: expected RED. The underlying focused `swift test` command failed during test compilation because the requested API did not exist. Representative diagnostics:

```text
error: cannot find 'SMCCodec' in scope
error: cannot find type 'SMCCodecError' in scope
error: fatalError
```

The final shell status was 0 only because the trailing `test ${PIPESTATUS[0]} -ne 0` asserted that the focused test command failed as expected.

## GREEN — minimal codec implementation

Added `Core/Sources/FanControlCore/SMCCodec.swift` and ran:

```sh
swift test --package-path Core --filter SMCCodecTests 2>&1 | tee /tmp/milestone-2-green.log
```

Result: exit 0. XCTest discovered and executed the intended suite:

```text
Test Suite 'SMCCodecTests' passed
Executed 15 tests, with 0 failures (0 unexpected)
```

SwiftPM also prints a separate Swift Testing summary saying `0 tests in 0 suites`; this project uses XCTest, and the preceding XCTest report confirms that all 15 focused codec tests were discovered and run.

## Correction cycle — reviewer-exposed coverage gaps

A reviewer correctly identified that the original 15-test suite did not exercise the existing `sp78` encoding branch or the guard for a finite `Double` that overflows `Float`. The original history above is retained, but it did not establish those behaviors through RED/GREEN despite the broader coverage wording below.

### Correction RED — remove behavior before adding tests

To create a genuine missing-behavior baseline, only the existing `sp78` encode implementation and the post-conversion `Float.isFinite` overflow guard were temporarily disabled. The rest of the codec remained intact. Six focused tests were then added for:

- `-12.5` encoded as `sp78` bytes `[0xF3, 0x80]`;
- positive and negative `sp78` encode/decode round trips;
- a non-representable `sp78` fraction returning `invalidEncodeValue`;
- values below `-128` and above `127.99609375` returning `valueOutOfRange` with those exact bounds;
- `Double.greatestFiniteMagnitude` encoded as `flt ` returning typed `valueOutOfRange` rather than trapping, emitting infinity, or returning `nonFiniteFloat`.

Exact command executed:

```sh
set -o pipefail; swift test --package-path Core --filter SMCCodecTests 2>&1 | tee /tmp/milestone-2-correction-red.log
```

Result: expected RED with a successful build and 21 discovered XCTest tests. Six correction tests failed solely because the targeted behavior was absent: `sp78` cases observed the temporary `unsupportedDataType("sp78")` baseline, and the finite-Double overflow test reported `XCTAssertThrowsError failed: did not throw an error`.

```text
Test Suite 'SMCCodecTests' failed
Executed 21 tests, with 6 failures (2 unexpected)
```

The two XCTest “unexpected” failures were the throwing encode and round-trip assertions receiving the deliberately disabled `sp78` error; they were behavior failures, not syntax, compilation, discovery, or test-harness errors.

### Correction GREEN — minimal reimplementation

The removed production behavior was minimally restored: signed 7.8 fixed-point scaling/range validation and big-endian two's-complement bytes for `sp78`, plus a finite-result guard after `Double`-to-`Float` conversion with exact Float bounds.

Exact command executed:

```sh
set -o pipefail; swift test --package-path Core --filter SMCCodecTests 2>&1 | tee /tmp/milestone-2-correction-green.log
```

Result: exit 0, with the focused codec count increased from 15 to 21 and no zero-test false green:

```text
Test Suite 'SMCCodecTests' passed
Executed 21 tests, with 0 failures (0 unexpected)
```

## Original full verification

Exact command executed:

```sh
scripts/test.sh 2>&1 | tee /tmp/milestone-2-full.log
```

Result: exit 0.

- Python contracts: 5 tests passed.
- Core SwiftPM tests: 16 XCTest tests passed, 0 failures (15 codec tests plus the existing package-version test).
- `CoolFanControl` app build: `** BUILD SUCCEEDED **`.
- `helperd` build: `** BUILD SUCCEEDED **`.

Additional checks:

```sh
git diff --check
git status --short
git diff --stat
git diff --name-only
```

`git diff --check` passed. Only the intended untracked source, test, and this verification document remain; generated `.build` and `DerivedData` content is ignored. A scan of changed Swift files found no common secret/key patterns. `swift-format` is not installed, so normal Swift style was used.

## Design choices covered by tests

- `flt ` reconstructs IEEE-754 bits from four little-endian bytes without unaligned pointer loads; exact M1 hardware vectors cover 1700, 2443, and 4499 RPM plus realistic temperatures.
- `fpe2`, `sp78`, `ui16`, and `ui32` use SMC big-endian byte order; `ui8 ` is one byte.
- Fixed-point and unsigned encoders reject non-representable fractional values and out-of-range values rather than rounding silently.
- Data type strings must be exact four-byte ASCII FourCCs; supported types and their required byte sizes are explicit.
- Public codec/data-type/error types are `Sendable` and equatable where applicable for Swift 6 concurrency.
- The implementation uses portable `[UInt8]` APIs and has no Foundation dependency.

## Correction full verification

Exact commands executed after the correction GREEN:

```sh
set -o pipefail; scripts/test.sh 2>&1 | tee /tmp/milestone-2-correction-full.log
git diff --check
git status --short
```

All commands exited 0. The full script reported:

- Python contracts: 5 tests passed.
- Core SwiftPM tests: 22 XCTest tests passed, 0 failures (21 codec tests plus the existing package-version test).
- `CoolFanControl` app build: `** BUILD SUCCEEDED **`.
- `helperd` build: `** BUILD SUCCEEDED **`.

`git diff --check` produced no errors. Because the three intended files are still untracked, each was also checked with `git diff --no-index --check /dev/null <file>`; all three whitespace checks passed. `git status --short` lists only the same intended source, test, and verification-document files.

## Quality-review regression — strict advertised `flt ` bounds

A quality review found that the post-conversion `Float.isFinite` guard did not enforce the exact bounds advertised by `valueOutOfRange`. `Double(Float.greatestFiniteMagnitude).nextUp` and `(-Double(Float.greatestFiniteMagnitude)).nextDown` are finite `Double` values outside those bounds, but each rounds back to a finite `Float` and was accepted.

### Regression RED — just-outside values rejected

Focused tests were added first for the positive and negative just-outside values. Each expects the exact typed `valueOutOfRange(dataType:value:minimum:maximum:)` error with minimum `-Double(Float.greatestFiniteMagnitude)` and maximum `Double(Float.greatestFiniteMagnitude)`. A stable boundary check also confirms that both exact advertised bounds remain accepted.

Exact command executed:

```sh
set -o pipefail; swift test --package-path Core --filter SMCCodecTests 2>&1 | tee /tmp/milestone-2-advertised-bound-red.log
```

Result: expected RED after a successful build. XCTest discovered 24 focused codec tests; only the two just-outside assertions failed because encoding returned successfully:

```text
XCTAssertThrowsError failed: did not throw an error
Test Suite 'SMCCodecTests' failed
Executed 24 tests, with 2 failures (0 unexpected)
```

### Regression GREEN — guard the original `Double`

Before conversion to `Float`, the implementation now checks the original finite `Double` against the declared minimum and maximum. NaN and infinities still return `nonFiniteFloat`, and the existing post-conversion finite guard remains as overflow safety. No precision-loss or subnormal policy changed.

Exact command executed:

```sh
set -o pipefail; swift test --package-path Core --filter SMCCodecTests 2>&1 | tee /tmp/milestone-2-advertised-bound-green.log
```

Result: exit 0 with all focused tests discovered and passing:

```text
Test Suite 'SMCCodecTests' passed
Executed 24 tests, with 0 failures (0 unexpected)
```

### Regression full verification

Exact commands executed after GREEN:

```sh
set -o pipefail; scripts/test.sh 2>&1 | tee /tmp/milestone-2-advertised-bound-full.log
git diff --check
git diff --no-index --check /dev/null Core/Sources/FanControlCore/SMCCodec.swift
git diff --no-index --check /dev/null Core/Tests/FanControlCoreTests/SMCCodecTests.swift
git diff --no-index --check /dev/null Docs/milestone-2-codecs-tdd-verification.md
git status --short
```

The full script exited 0:

- Python contracts: 5 tests passed.
- Core SwiftPM tests: 25 XCTest tests passed, 0 failures (24 codec tests plus the existing package-version test).
- `CoolFanControl` app build: `** BUILD SUCCEEDED **`.
- `helperd` build: `** BUILD SUCCEEDED **`.

`git diff --check` produced no errors. Each untracked file's `git diff --no-index --check` produced no whitespace diagnostics (exit 1 is expected because each file differs from `/dev/null`). `git status --short` still lists exactly the same three intended untracked files: codec source, codec tests, and this verification document.
