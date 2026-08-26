# Milestone 3 IOHID Trusted Thermal Reader — TDD Verification

Date: 2026-08-26
Scope: Trusted IOHID thermal reading only — classification, validation, freshness, hottest selection, and the production IOHID event-system reader. No fan writes, SMC thermal guesses, battery, overrides, helper/XPC, or UI.

## Policy decisions

- **Allowlist by exact prefix only.** `ThermalSensorFamily.classify(productName:)` matches the verified prefixes `pACC MTR Temp Sensor`, `eACC MTR Temp Sensor`, `GPU MTR Temp Sensor`, `SOC MTR Temp Sensor`, `PMGR SOC Die Temp`. Near-misses (case, spacing, contains-but-not-prefix, `PMU`/`PMU2`, `ANE`, `ISP`, `NAND`) return nil and are reported as `.unclassified` diagnostics — they can never be promoted.
- **`hottestCPU`** is the max across pACC+eACC only. **`hottestControl`** is the max across CPU/GPU/SOC only. **PMGR SOC Die is corroboration-only and never promoted** (explicit test). Ties resolve to the first reading in deterministic product-name order (strict greater-than).
- **Value gate:** `celsius.isFinite` then `10 < celsius <= 120`. NaN/infinity, implausible values, missing products, and missing events produce typed diagnostics while valid siblings remain in the snapshot.
- **Freshness:** one injected monotonic `now` (UInt64 nanos) per scan — read once by the reader, stamped onto every raw reading, and used as the freshness base. `sampledAt > now` is a `.futureSample` clock anomaly; `now - sampledAt > maxAge` is `.stale`. All-missing/stale yields `nil` hottest values, never 0. Default `maxAgeNanos` = 5 s, positive-only (precondition).
- **No scaling.** The float field (`15 << 16`) is already Celsius; the exact live float precision (e.g. `37.578125`) must survive untouched (explicit vector test).
- **Deterministic ordering:** readings sorted by product name (then sample time, then value) — a total order.
- **IOHID contract:** `IOHIDEventSystemClientCreate` / `SetMatching` (`PrimaryUsagePage` 0xff00, `PrimaryUsage` 0x0005) / `CopyServices`; `IOHIDServiceClientCopyProperty(service, "Product")`; `IOHIDServiceClientCopyEvent(service, 15, 0, 0)`; `IOHIDEventGetFloatValue(event, 15 << 16)`. Private-but-exported symbols are declared directly with `@_silgen_name` (no dlsym, no force-unwrapped pointers). Swift ARC manages CF ownership for Create/Copy results (`CFRelease` is unavailable in Swift). CF values never cross an isolation boundary — each is created, used, and released inside one synchronous scope.

## RED

Tests were authored before `ThermalReader.swift`. Focused command:

```sh
swift test --package-path Core --filter ThermalReaderTests
```

It exited 1 because the requested production API did not exist. The compiler reported missing symbols: `ThermalSensorFamily`, `TrustedThermalReading`, `TrustedThermalSnapshot`, `ThermalReadingDiagnostic`, `RawThermalReading`, `RawThermalSampling`, `TrustedThermalSnapshotBuilder`, `TrustedThermalReadingSource`, `IOHIDTrustedThermalReader`. The RED log was captured at `/tmp/thermal-red.log`.

## GREEN

Focused command:

```sh
swift test --package-path Core --filter ThermalReaderTests
```

Result: **16 tests executed, 0 failures**. Coverage: exact prefix classification + near-miss rejection (lowercase/uppercase/wrong spacing/truncated/`PMU`/`ANE`/`NAND`), hottest CPU = max across pACC+eACC, hottest control = CPU/GPU/SOC only, PMGR never promoted (explicit, even when hottest overall), deterministic tie-break, NaN/inf/≤10/>120 skipped with diagnostics while valid siblings remain, missing product/event typed diagnostics, unclassified never promoted, freshness (exact maxAge accepted, just-over stale, future anomaly, all-stale → nil not 0), custom maxAge honored + default 5 s, one scan uses one clock value, the real M1 17-reading inventory vector (no scaling, exact `37.578125`), and Sendable models/protocol/source.

Strict concurrency command:

```sh
swift test --package-path Core -Xswiftc -strict-concurrency=complete
```

Result: **94 tests executed, 0 failures** with Swift 6 complete concurrency checking.

Full repository validation:

```sh
scripts/test.sh
```

Result:

- Python contracts: **5 tests, OK**
- Core: **94 tests, 0 failures**
- `CoolFanControl` native macOS build: **BUILD SUCCEEDED**
- `helperd` native macOS build: **BUILD SUCCEEDED**

`git diff --check` reports no whitespace errors.

## Live read-only validation (unprivileged, twice)

A temporary `/tmp/live-iohid-thermal.swift` entry point instantiated production `IOHIDTrustedThermalReader()`, compiled with Swift 6 complete concurrency checking and IOKit, then run without `sudo` (euid 501):

```sh
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  Core/Sources/FanControlCore/*.swift /tmp/live-iohid-thermal.swift \
  -framework IOKit -o /tmp/live-iohid-thermal
/tmp/live-iohid-thermal
```

Run 1 (`/tmp/thermal-live-run1.txt`) and Run 2 (`/tmp/thermal-live-run2.txt`, ~1 s later) both reported:

```text
HARNESS euid=501 readings=17 diagnostics=34 servicesSeen=51
```

Both runs returned the exact same trusted inventory — 17 readings, 7 pACC (suffixes 2,3,4,5,7,8,9), 2 eACC (0,3), 2 GPU (1,4), 3 SOC (0,1,2), 3 PMGR SOC Die (0,1,2) — matching the reference inventory:

```text
FAMILY family=pACC_CPU count=7 hottest=pACC MTR Temp Sensor3 celsius=41.484375
FAMILY family=eACC_CPU count=2 hottest=eACC MTR Temp Sensor3 celsius=38.281250
FAMILY family=GPU count=2 hottest=GPU MTR Temp Sensor1 celsius=30.000000
FAMILY family=SOC count=3 hottest=SOC MTR Temp Sensor1 celsius=39.765625
FAMILY family=PMGR_SOC_DIE count=3 hottest=PMGR SOC Die Temp Sensor2 celsius=39.000000
HOTTEST_CPU product="pACC MTR Temp Sensor3" celsius=41.484375
HOTTEST_CONTROL product="pACC MTR Temp Sensor3" celsius=41.484375
```

No allowlisted family was missing. Every trusted pACC/eACC reading satisfied `10 < T <= 120` (float precision values like `41.484375` prove the no-scaling contract). Diagnostics were identical across runs: 32 `.unclassified` (PMU/PMU2/ANE/ISP/NAND services — never promoted, matching the near-miss policy) and 2 `.outOfPlausibleRange` (`PMU tdev4`/`PMU tdev5` at ≈ −21.6 °C, rejected by the plausibility gate while all valid siblings remained).

## Files

- `Core/Sources/FanControlCore/ThermalReader.swift` (new) — models, diagnostics, pure `TrustedThermalSnapshotBuilder`, `TrustedThermalReadingSource`, actor `IOHIDTrustedThermalReader`, `IOHIDRawThermalSampler`, and the `@_silgen_name` IOHID declarations.
- `Core/Tests/FanControlCoreTests/ThermalReaderTests.swift` (new) — 16 focused tests.
- `Docs/milestone-3-iohid-thermal-tdd-verification.md` (new) — this document.
- `Package.swift` unchanged (IOKit already linked). No repo artifacts; changes left uncommitted.
