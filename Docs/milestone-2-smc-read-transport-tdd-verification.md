# Milestone 2 AppleSMC read transport — TDD verification

Date: 2026-08-26

## Scope

Implemented only the unprivileged, read-only AppleSMC transport in `FanControlCore`:

- `SMCValue`: public `Sendable` logical value with a printable FourCC type, a maximum size of 32, exact logical byte-count validation, and optional `SMCCodec` numeric decoding.
- `SMCReading`: public `Sendable` async protocol for `read(_:)` and `key(at:)`, suitable for hardware-free fakes and later key/fan discovery.
- `SMCExecuting`: exact byte-buffer/selector seam used by scripted unit-test executors.
- `SMCClient`: command 9 key-info followed by command 5 read, plus command 8 key-at-index enumeration. Every call uses selector 2 and exact 80-byte explicit wire images.
- `AppleSMCIOKitExecutor`: actor-serialized AppleSMC connection opened with service type 0. The service object is released on every open path, a partially opened connection is closed on failure, and the successful connection is closed on deinit. `IOConnectCallStructMethod` uses only a small `withUnsafeBytes`/`withUnsafeMutableBytes` bridge and verifies the returned size is exactly 80.
- Typed errors distinguish service lookup, open, IOKit call, driver result, driver status, result 132 key-not-found, malformed output, invalid size/type/key, and inconsistent read metadata.

No write method, fan-control behavior, helper/XPC, sensor policy, UI, `sudo`, or command 6 call was added or used. The existing wire-model command-6 fixture from Task 2.2 was not exercised by the transport.

## Strict TDD evidence

### Initial RED

Command:

```sh
swift test --package-path Core --filter SMCClientTests
```

Result: expected compile RED before production implementation. Missing symbols included `SMCExecuting`, `SMCTransportError`, `SMCValue`, `SMCReading`, and `SMCClient`; zero tests could execute because the requested API did not yet exist. Full output: `/tmp/smc-transport-red.log`.

### Initial GREEN

After the minimal production implementation, the focused suite executed 13 tests with 0 failures. During the first live run, real AppleSMC command-5 responses were observed to return an all-zero key-info field even though command 9 returned valid metadata. The client correctly rejected this under the first consistency rule, so this live behavior was corrected through a second TDD cycle rather than silently weakening validation.

### Live-correction RED

Added `testReadAcceptsDriverReadResponseWithEmptyMetadata` first and ran only it. Result: 1 test executed, 1 expected failure with `inconsistentReadMetadata`.

The minimal correction accepts either:

1. key-info exactly equal to command 9, or
2. the all-zero command-5 key-info sentinel emitted by the live driver.

Any other returned metadata remains an `inconsistentReadMetadata` error.

### Final focused GREEN

Command:

```sh
swift test --package-path Core --filter SMCClientTests
```

Result: **14 tests, 0 failures**. Coverage includes exact command 9 → 5 ordering, selector 2, same key and metadata propagation, `ui8 ` and `flt ` logical bytes/decoding, result 132, other driver results, status, call failure, malformed length, size 33, nonprintable type, inconsistent metadata, command-8 index encoding, invalid returned key, no command 6, and `Sendable` fake/protocol suitability.

## Full repository validation

Command:

```sh
scripts/test.sh
```

Result: exit 0.

- Python scaffold contracts: **5 tests, 0 failures**.
- Core XCTest suite: **57 tests, 0 failures**.
- Unsigned native `CoolFanControl` build: succeeded.
- Unsigned native `helperd` build: succeeded.
- Both arm64 and x86_64 package/native compilation linked IOKit successfully.

Full output: `/tmp/smc-transport-full-validation.log`.

## Live unprivileged read-only evidence

A temporary `/tmp` Swift harness was compiled directly with the Core sources and IOKit. It instantiated `SMCClient()` without `sudo`, performed only command 9/5 reads and command 8 enumeration, and left no repository artifact.

Exact observed values:

```text
READ key=FNum type='ui8 ' size=1 attributes=128 bytes=01 value=1.0
READ key=F0Ac type='flt ' size=4 attributes=132 bytes=A4 1A D4 44 value=1696.83251953125
READ key=F0Mn type='flt ' size=4 attributes=132 bytes=00 80 D4 44 value=1700.0
READ key=F0Mx type='flt ' size=4 attributes=133 bytes=00 98 8C 45 value=4499.0
READ key=F0Md type='ui8 ' size=1 attributes=208 bytes=00 value=0.0
READ key=F0Tg type='flt ' size=4 attributes=212 bytes=00 80 D4 44 value=1700.0
READ key=#KEY type='ui32' size=4 attributes=128 bytes=00 00 03 F0 value=1008.0
INDEX index=0 key='#KEY'
INDEX index=1007 key='zSPp'
```

A separate temporary enumeration harness called `key(at:)` for every index reported by `#KEY`:

```text
ENUM reported=1008 successful=1008 first='#KEY' last='zSPp'
```

Live outputs: `/tmp/smc-live-read-output.txt` and `/tmp/smc-enumeration-output.txt`.

## Files

- Added `Core/Sources/FanControlCore/SMCClient.swift`.
- Added `Core/Tests/FanControlCoreTests/SMCClientTests.swift`.
- Updated `Core/Package.swift` with the macOS IOKit linker setting.
- Added this verification record.

All repository changes remain uncommitted.

## Spec-review correction: response-key integrity and read-only enforcement

A later review found two transport-spec gaps: successful named-key responses did not validate the returned key, and the public production executor accepted arbitrary command bytes. This correction was completed without `sudo`, writes, or any live command-6 call.

### Prerequisite raw response-key measurement

Before choosing a response-key policy, a temporary `/tmp` harness used the production `AppleSMCIOKitExecutor` directly and performed only command 9 followed by command 5 for `FNum` and `F0Ac`. Exact decoded output:

```text
key=FNum command=9 expected=0x464E756D response.key=0x00000000 decoded='<nonprintable-or-zero>' result=0 status=0
key=FNum command=5 expected=0x464E756D response.key=0x00000000 decoded='<nonprintable-or-zero>' result=0 status=0
key=F0Ac command=9 expected=0x46304163 response.key=0x00000000 decoded='<nonprintable-or-zero>' result=0 status=0
key=F0Ac command=5 expected=0x46304163 response.key=0x00000000 decoded='<nonprintable-or-zero>' result=0 status=0
```

The live driver therefore uses a zero returned-key sentinel for both named-key phases on this host. Successful command-9 and command-5 responses now accept only the exact requested key or that measured zero sentinel; every other returned value throws `unexpectedReturnedKey(expected:actual)`. Result 132 is still mapped to `keyNotFound` before successful-response key validation.

Raw output: `/tmp/smc-response-key-measurement.txt`.

### Correction RED

Typed error cases and behavioral tests were added first. The pure validator initially had a no-op body solely to obtain an executable behavioral RED; no command-6 request was sent to the production executor or IOKit.

Command:

```sh
swift test --package-path Core --filter SMCClientTests
```

Result: **21 tests executed, 7 expected assertion failures**. The failures showed that command-9 and command-5 key mismatches were not rejected and that selector, command 6/zero/unknown, and non-80-byte requests were not rejected. Full output: `/tmp/smc-spec-correction-red.log`.

### Correction GREEN

The minimal correction adds a pure internal request validator that requires selector 2, decodes an exact 80-byte request, and permits only commands 5, 8, and 9. `AppleSMCIOKitExecutor.execute` invokes it before `IOConnectCallStructMethod` and still hardcodes selector 2 for the actual IOKit call. Command 6 exists only as unit-test byte data and is rejected by the pure validator.

Focused command:

```sh
swift test --package-path Core --filter SMCClientTests
```

Result: **21 tests, 0 failures**. Full output: `/tmp/smc-spec-correction-focused-green.log`.

Full validation command:

```sh
scripts/test.sh
```

Result: exit 0: **5 Python contract tests and 64 Core XCTest tests passed**, and both unsigned universal macOS app/helper builds succeeded. Full output: `/tmp/smc-spec-correction-full-validation.log`.

Strict-concurrency build:

```sh
swift build --package-path Core -Xswiftc -strict-concurrency=complete
```

Result: exit 0. Output: `/tmp/smc-spec-correction-strict-concurrency.log`.

### Live read-only revalidation

A newly compiled `/tmp` harness used the corrected production client without `sudo` and performed only `FNum` and `F0Ac` command-9/5 reads plus command-8 index 0:

```text
READ key=FNum type='ui8 ' size=1 attributes=128 bytes=01 value=1.0
READ key=F0Ac type='flt ' size=4 attributes=132 bytes=82 4F D5 44 value=1706.484619140625
INDEX index=0 key='#KEY'
```

Output: `/tmp/smc-live-read-revalidation.txt`.
