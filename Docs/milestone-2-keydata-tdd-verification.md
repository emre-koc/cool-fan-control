# Milestone 2 AppleSMC Key Data — TDD Verification

Date: 2026-08-25 to 2026-08-26

Scope: pure printable FourCC handling and explicit AppleSMC 80-byte key-data wire serialization in the Core SwiftPM package. No IOKit calls, hardware access, fan/sensor discovery, policy, helper/XPC, or UI code is included.

## RED — tests written first

Added `Core/Tests/FanControlCoreTests/SMCKeyDataTests.swift` before adding any production FourCC or key-data API.

Exact command:

```sh
set -o pipefail; swift test --package-path Core --filter 'SMCFourCCTests|SMCKeyDataTests' 2>&1 | tee /tmp/milestone-2-keydata-red.log
```

Result: expected exit 1 during test compilation because the requested APIs were absent. Representative diagnostics:

```text
error: cannot find 'SMCFourCC' in scope
error: cannot find 'SMCKeyData' in scope
error: cannot find type 'SMCKeyDataError' in scope
error: cannot find 'SMCCommand' in scope
error: fatalError
```

This was a missing-API RED, not a zero-test false green.

## GREEN — explicit 80-byte implementation

Added `Core/Sources/FanControlCore/SMCKeyData.swift` with minimal APIs required by the focused tests, then ran:

```sh
set -o pipefail; swift test --package-path Core --filter 'SMCFourCCTests|SMCKeyDataTests' 2>&1 | tee /tmp/milestone-2-keydata-green.log
```

Result: exit 0. XCTest discovered and passed 12 focused tests (3 FourCC and 9 key-data tests), with 0 failures.

## FourCC byte-initializer TDD cycle

A direct `[UInt8]` initializer was then specified by a new test before implementation.

RED command:

```sh
set -o pipefail; swift test --package-path Core --filter SMCFourCCTests 2>&1 | tee /tmp/milestone-2-fourcc-bytes-red.log
```

Result: expected exit 1 because `SMCFourCC(bytes:)` did not exist (`extraneous argument label 'bytes:' in call`).

After adding the initializer, the final focused command was:

```sh
set -o pipefail; swift test --package-path Core --filter 'SMCFourCCTests|SMCKeyDataTests' 2>&1 | tee /tmp/milestone-2-keydata-final-green.log
```

Result: exit 0. XCTest discovered and passed 13 focused tests (4 FourCC and 9 key-data tests), with 0 failures. SwiftPM separately prints a Swift Testing summary of 0 tests because these suites use XCTest; the preceding XCTest report confirms discovery and execution.

## Design contract covered

- Printable ASCII FourCC strings/bytes must contain exactly four bytes; invalid length, non-ASCII, and control bytes produce typed errors.
- FourCC numeric values are canonical big-endian (`FNum == 0x464E756D`) and preserve spaces/case.
- The AppleSMC parameter wire image is always exactly 80 bytes and is assembled with indexed `[UInt8]` operations only—no `MemoryLayout`, raw struct copies, unsafe pointers, or Foundation dependency.
- Apple Silicon native scalar fields are little-endian. Thus canonical FourCC numeric `0x464E756D` occupies key field bytes `[6D, 75, 4E, 46]` in the host-ABI wire image.
- Corrected offsets are asserted directly: version 4...9, pad 10...11, pLimit 12...27, packed keyInfo 28...36, pad 37...39, result 40, status 41, command/data8 42, pad 43, data32 44...47, payload 48...79.
- The regression test specifically proves `result` is byte 40 and command is byte 42.
- Commands are data8 values read=5, write=6, index=8, info=9; the separate IOKit selector constant is always 2.
- Request fixtures cover `FNum` key-info/read, write payload padding, and live-catalog final index 1007 (`#KEY == 1008`).
- Decode rejects wire images not exactly 80 bytes. Construction and encoding reject payloads over 32 bytes and malformed fixed-size version/pLimit fields with typed errors.
- Public value types are Equatable/Hashable/Sendable as applicable.

## Full verification

Exact command:

```sh
set -o pipefail; scripts/test.sh 2>&1 | tee /tmp/milestone-2-keydata-full.log
```

Result: exit 0.

- Python scaffold contracts: 5 tests passed.
- Core SwiftPM: 38 XCTest tests passed, 0 failures (24 codecs, 4 FourCC, 9 key-data, 1 package-version).
- `CoolFanControl` native build: `** BUILD SUCCEEDED **`.
- `helperd` native build: `** BUILD SUCCEEDED **`.

Final checks:

```sh
git diff --check
# Also run git diff --no-index --check against /dev/null for each untracked file.
git status --short
```

All whitespace checks passed. `git status --short` lists exactly the three intended untracked files: the source, test, and this verification record. Generated `.build` and `DerivedData` files remain ignored. No commit or push was performed.

## Spec-review correction — canonical payload and data-size safety

A later specification review found three gaps: short model payloads did not remain equal after an encode/decode round trip, reported data sizes above the 32-byte ABI payload were accepted, and write requests did not require their logical payload length to match the reported size.

### Correction RED

The regression tests were added before the behavior change. The first focused run used:

```sh
set -o pipefail; swift test --package-path Core --filter 'SMCFourCCTests|SMCKeyDataTests' 2>&1 | tee /tmp/milestone-2-keydata-correction-compile-red.log
```

Result: expected exit 1 while compiling the new tests because the two new typed error cases did not yet exist. This run also exposed and corrected a test-only `[Int]` inference error. Only `dataSizeTooLarge(maximum:actual:)` and `payloadSizeMismatch(reported:logical:)` were then added to the production error enum so the behavioral RED could run.

Behavioral RED command:

```sh
set -o pipefail; swift test --package-path Core --filter 'SMCFourCCTests|SMCKeyDataTests' 2>&1 | tee /tmp/milestone-2-keydata-correction-red.log
```

Result: expected exit 1. XCTest executed 18 focused tests and reported 17 assertion failures across the new regressions: empty/short payloads remained 0/3 bytes and lost round-trip equality, construction/encode/decode accepted `dataSize == 33`, request factories exposed empty payload arrays, and write requests accepted zero- and two-byte logical payloads for a reported size of one. Existing tests continued to execute; this was a behavioral RED, not a zero-test false green.

### Correction GREEN

The minimal correction now:

- validates `keyInfo.dataSize <= 32` during construction, encode, and decode;
- zero-pads initializer payloads of 0...32 bytes to the canonical fixed 32-byte public buffer;
- requires encode-time payloads to remain exactly 32 bytes after public mutation;
- validates write-request logical payload length against the reported data size before canonical padding; and
- preserves the existing 80-byte request wire fixtures and zero padding.

Focused GREEN command:

```sh
set -o pipefail; swift test --package-path Core --filter 'SMCFourCCTests|SMCKeyDataTests' 2>&1 | tee /tmp/milestone-2-keydata-correction-green.log
```

Result: exit 0. XCTest discovered and passed all 18 focused tests (4 FourCC and 14 key-data), with 0 failures.

Full verification command:

```sh
set -o pipefail; scripts/test.sh 2>&1 | tee /tmp/milestone-2-keydata-correction-full.log
```

Result: exit 0. Python scaffold contracts passed 5 tests; Core SwiftPM passed 43 XCTest tests with 0 failures (24 codecs, 4 FourCC, 14 key-data, 1 package-version); both the `CoolFanControl` and `helperd` native builds reported `** BUILD SUCCEEDED **`.
