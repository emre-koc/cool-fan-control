# Milestone 2 Fan Discovery — TDD Verification

Date: 2026-08-26  
Scope: Task 2.4 fan discovery and snapshot models only. All hardware validation was read-only and unprivileged.

## Policy decisions

- `FNum` must report exactly `ui8 ` / 1 byte. Its byte is decoded directly, so non-integral values are unconstructible under valid metadata.
- Fan keys use one decimal index character. Counts `0...10` are supported (`F0*...F9*`); count 11 or greater fails before any per-fan read.
- Fan RPM keys accept only exact `flt ` / 4-byte or `fpe2` / 2-byte metadata. Other numeric SMC types are rejected.
- Mode must be exact `ui8 ` / 1 byte. Bytes 0 and 1 map to automatic/manual; every other byte is preserved as `unknown(byte)`.
- Minimum, maximum, current, and target RPM must decode as finite and nonnegative. Minimum must not exceed maximum. Current and target are reported as read: they are not clamped to live limits, because actual RPM can transiently fall just below minimum and a snapshot must not silently alter hardware state.
- Discovery is serial and deterministic (`FNum`, then `Ac/Mn/Mx/Md/Tg` per fan) and returns only a complete snapshot. Read failures carry the exact key and optional fan index while preserving the underlying error.

## RED

Tests were authored before `FanDiscovery.swift`. After correcting test-only async XCTest autoclosure/name-resolution issues, the focused command was:

```sh
swift test --package-path Core --filter FanDiscoveryTests
```

It exited 1 because the requested production API did not exist. The compiler reported missing `FanDiscovery`, `FanSnapshot`, `FanInfo`, `FanControlMode`, `FanDiscovering`, `FanDiscoveryError`, and `FanDiscoveryReadError` symbols. The durable RED log was captured at `/tmp/fan-discovery-red.log` during implementation.

## GREEN

Focused command:

```sh
swift test --package-path Core --filter FanDiscoveryTests
```

Result: **14 tests executed, 0 failures**. Coverage includes the real M1 byte vector, mixed per-key `flt `/`fpe2`, deterministic exact keys/order, fanless behavior, decimal index boundary, metadata rejection, NaN/infinity, negative RPM, minimum greater than maximum, transient actual below minimum, unknown mode preservation, contextual/atomic read failure, and Sendable API use.

Strict concurrency command:

```sh
swift test --package-path Core -Xswiftc -strict-concurrency=complete
```

Result: **78 tests executed, 0 failures** with Swift 6 complete concurrency checking.

Full repository validation:

```sh
scripts/test.sh
```

Result:

- Python contracts: **5 tests, OK**
- Core: **78 tests, 0 failures**
- `CoolFanControl` native macOS build: **BUILD SUCCEEDED**
- `helperd` native macOS build: **BUILD SUCCEEDED**

## Live read-only validation

A temporary `/tmp/live-fan-discovery.swift` entry point instantiated production `SMCClient()` and `FanDiscovery(reader:)`. It was compiled with Swift 6 complete concurrency checking and IOKit, then run without `sudo`:

```sh
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  Core/Sources/FanControlCore/*.swift /tmp/live-fan-discovery.swift \
  -framework IOKit -o /tmp/live-fan-discovery
/tmp/live-fan-discovery
```

Observed output:

```text
fanCount=1
fan index=0 minRPM=1700.0 maxRPM=4499.0 currentRPM=1704.54541015625 mode=automatic modeByte=0 targetRPM=1700.0
```

This path used only `SMCReading.read` through the existing read-only executor. No command 6, write, root helper, XPC, or `sudo` was involved.
