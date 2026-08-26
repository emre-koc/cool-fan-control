import XCTest
@testable import FanControlCore

final class ThermalReaderTests: XCTestCase {
    // MARK: - Exact prefix classification

    func testClassifiesExactKnownPrefixes() {
        XCTAssertEqual(ThermalSensorFamily.classify(productName: "pACC MTR Temp Sensor2"), .pACC_CPU)
        XCTAssertEqual(ThermalSensorFamily.classify(productName: "pACC MTR Temp Sensor9"), .pACC_CPU)
        XCTAssertEqual(ThermalSensorFamily.classify(productName: "eACC MTR Temp Sensor0"), .eACC_CPU)
        XCTAssertEqual(ThermalSensorFamily.classify(productName: "eACC MTR Temp Sensor3"), .eACC_CPU)
        XCTAssertEqual(ThermalSensorFamily.classify(productName: "GPU MTR Temp Sensor1"), .GPU)
        XCTAssertEqual(ThermalSensorFamily.classify(productName: "SOC MTR Temp Sensor0"), .SOC)
        XCTAssertEqual(ThermalSensorFamily.classify(productName: "PMGR SOC Die Temp Sensor0"), .PMGR_SOC_DIE)
        XCTAssertEqual(ThermalSensorFamily.classify(productName: "PMGR SOC Die Temp"), .PMGR_SOC_DIE)
    }

    func testRejectsNearMissPrefixes() {
        for name in [
            "pacc MTR Temp Sensor0",            // lowercase
            "PACC MTR Temp Sensor0",            // uppercase
            "XpACC MTR Temp Sensor0",           // contains but not prefix
            "pACCMTRTempSensor0",               // wrong spacing
            "pACC MTR Temperature Sensor0",     // wrong word
            "eACC MTR Temperature Sensor0",
            "GPU MTR Temp",                     // truncated prefix
            "GPU MTR Temperature Sensor1",
            "SoC MTR Temp Sensor0",             // mixed case
            "SOC MTR TEMP SENSOR0",
            "PMU tdie",                         // never promoted
            "PMU tdev",
            "ANE MTR Temp Sensor0",
            "NAND MTR Temp Sensor0",
        ] {
            XCTAssertNil(ThermalSensorFamily.classify(productName: name), "expected nil for \(name)")
        }
    }

    // MARK: - Hottest selection

    func testHottestCPUIsMaxAcrossPACCAndEACC() {
        let snapshot = build([
            raw("pACC MTR Temp Sensor3", 37.578125),
            raw("eACC MTR Temp Sensor3", 39.0),
            raw("GPU MTR Temp Sensor1", 40.0),
        ])
        XCTAssertEqual(snapshot.hottestCPU?.productName, "eACC MTR Temp Sensor3")
        XCTAssertEqual(snapshot.hottestCPU?.celsius, 39.0)
    }

    func testHottestControlIncludesCPUGPUAndSOCButNotPMGR() {
        let snapshot = build([
            raw("pACC MTR Temp Sensor2", 37.5),
            raw("GPU MTR Temp Sensor4", 38.0),
            raw("SOC MTR Temp Sensor0", 41.0),
            raw("PMGR SOC Die Temp Sensor2", 50.0),
        ])
        XCTAssertEqual(snapshot.hottestControl?.productName, "SOC MTR Temp Sensor0")
        XCTAssertEqual(snapshot.hottestCPU?.productName, "pACC MTR Temp Sensor2")
    }

    func testPMGRNeverPromotedEvenWhenHottestOverall() {
        let snapshot = build([
            raw("PMGR SOC Die Temp Sensor0", 99.0),
            raw("pACC MTR Temp Sensor5", 50.0),
            raw("GPU MTR Temp Sensor1", 60.0),
        ])
        XCTAssertEqual(snapshot.readings.count, 3) // PMGR stays a trusted reading
        XCTAssertEqual(snapshot.hottestCPU?.productName, "pACC MTR Temp Sensor5")
        XCTAssertEqual(snapshot.hottestControl?.productName, "GPU MTR Temp Sensor1")
    }

    func testHottestTieResolvedByDeterministicProductOrder() {
        let snapshot = build([
            raw("pACC MTR Temp Sensor9", 40.0),
            raw("pACC MTR Temp Sensor2", 40.0),
        ])
        XCTAssertEqual(snapshot.hottestCPU?.productName, "pACC MTR Temp Sensor2")
    }

    // MARK: - Value validation

    func testInvalidValuesSkippedWithDiagnosticsWhileValidSiblingsRemain() {
        let snapshot = build([
            raw("pACC MTR Temp Sensor2", .nan),
            raw("pACC MTR Temp Sensor3", .infinity),
            raw("pACC MTR Temp Sensor4", 10.0),
            raw("pACC MTR Temp Sensor5", 5.0),
            raw("pACC MTR Temp Sensor7", 121.0),
            raw("pACC MTR Temp Sensor8", 37.578125),
            raw("pACC MTR Temp Sensor9", 120.0),
        ])
        XCTAssertEqual(snapshot.readings.map(\.productName), ["pACC MTR Temp Sensor8", "pACC MTR Temp Sensor9"])
        XCTAssertEqual(snapshot.hottestCPU?.celsius, 120.0)

        let nonFiniteNames = snapshot.diagnostics.compactMap { diagnostic -> String? in
            if case .nonFiniteValue(let productName, _) = diagnostic { return productName }
            return nil
        }
        XCTAssertEqual(nonFiniteNames, ["pACC MTR Temp Sensor2", "pACC MTR Temp Sensor3"])

        let outOfRangeValues = snapshot.diagnostics.compactMap { diagnostic -> Double? in
            if case .outOfPlausibleRange(_, let value) = diagnostic { return value }
            return nil
        }
        XCTAssertEqual(outOfRangeValues, [10.0, 5.0, 121.0])
        XCTAssertEqual(snapshot.diagnostics.count, 5)
    }

    func testMissingProductAndEventAreTypedDiagnostics() {
        let snapshot = build([
            raw(nil, 37.5),
            raw("", 37.5),
            raw("pACC MTR Temp Sensor2", nil),
            raw("pACC MTR Temp Sensor3", 37.0),
        ])
        XCTAssertEqual(snapshot.diagnostics, [
            .missingProduct,
            .missingProduct,
            .missingEvent(productName: "pACC MTR Temp Sensor2"),
        ])
        XCTAssertEqual(snapshot.readings.count, 1)
    }

    func testUnclassifiedValidReadingsAreDiagnosedNotPromoted() {
        let snapshot = build([
            raw("PMU tdie", 45.0),
            raw("pACC MTR Temp Sensor2", 37.0),
        ])
        XCTAssertEqual(snapshot.readings.map(\.productName), ["pACC MTR Temp Sensor2"])
        XCTAssertEqual(snapshot.diagnostics, [.unclassified(productName: "PMU tdie", celsius: 45.0)])
        XCTAssertEqual(snapshot.hottestCPU?.productName, "pACC MTR Temp Sensor2")
        XCTAssertEqual(snapshot.hottestControl?.productName, "pACC MTR Temp Sensor2")
    }

    // MARK: - Freshness

    func testFreshnessExactMaxAgeAcceptedJustOverStale() {
        let now: UInt64 = 100_000_000_000
        let maxAge: UInt64 = 5_000_000_000
        let snapshot = TrustedThermalSnapshotBuilder(maxAgeNanos: maxAge).build(rawReadings: [
            raw("pACC MTR Temp Sensor2", 37.0, sampledAt: now - maxAge),
            raw("pACC MTR Temp Sensor3", 38.0, sampledAt: now - maxAge - 1),
        ], now: now)
        XCTAssertEqual(snapshot.readings.map(\.productName), ["pACC MTR Temp Sensor2"])
        XCTAssertEqual(snapshot.diagnostics, [.stale(productName: "pACC MTR Temp Sensor3", ageNanos: maxAge + 1)])
    }

    func testFutureSampleIsRejectedAsClockAnomaly() {
        let now: UInt64 = 100_000_000_000
        let snapshot = TrustedThermalSnapshotBuilder().build(rawReadings: [
            raw("pACC MTR Temp Sensor2", 37.0, sampledAt: now + 5),
        ], now: now)
        XCTAssertEqual(snapshot.diagnostics, [.futureSample(productName: "pACC MTR Temp Sensor2", skewNanos: 5)])
        XCTAssertTrue(snapshot.readings.isEmpty)
    }

    func testAllStaleYieldsNilHottestNotZero() {
        let now: UInt64 = 100_000_000_000
        let snapshot = TrustedThermalSnapshotBuilder().build(rawReadings: [
            raw("pACC MTR Temp Sensor2", 37.0, sampledAt: 0),
            raw("GPU MTR Temp Sensor1", 40.0, sampledAt: 0),
        ], now: now)
        XCTAssertTrue(snapshot.readings.isEmpty)
        XCTAssertNil(snapshot.hottestCPU)
        XCTAssertNil(snapshot.hottestControl)
        XCTAssertEqual(snapshot.diagnostics.count, 2)
    }

    func testCustomMaxAgeHonoredAndDefaultIsFiveSeconds() {
        XCTAssertEqual(TrustedThermalSnapshotBuilder.defaultMaxAgeNanos, 5_000_000_000)
        let now: UInt64 = 100_000_000_000
        let snapshot = TrustedThermalSnapshotBuilder(maxAgeNanos: 1_000_000_000).build(rawReadings: [
            raw("pACC MTR Temp Sensor2", 37.0, sampledAt: now - 1_000_000_000),
            raw("pACC MTR Temp Sensor3", 38.0, sampledAt: now - 1_000_000_001),
        ], now: now)
        XCTAssertEqual(snapshot.readings.map(\.productName), ["pACC MTR Temp Sensor2"])
        XCTAssertEqual(snapshot.diagnostics, [.stale(productName: "pACC MTR Temp Sensor3", ageNanos: 1_000_000_001)])
    }

    // MARK: - One clock value per scan

    func testOneScanUsesOneClockValue() async throws {
        let clock = ClockBox(42)
        let sampler = IdentitySampler(template: raw("pACC MTR Temp Sensor2", 37.578125))
        let reader = IOHIDTrustedThermalReader(
            sampler: sampler,
            maxAgeNanos: 5_000_000_000,
            clock: { clock.call() }
        )
        let snapshot = try await reader.trustedSnapshot()
        XCTAssertEqual(clock.callCount(), 1)
        XCTAssertEqual(snapshot.readings.count, 1)
        XCTAssertEqual(snapshot.readings[0].sampledAt, 42)
        XCTAssertEqual(snapshot.readings[0].celsius, 37.578125)
        XCTAssertTrue(snapshot.diagnostics.isEmpty)
    }

    // MARK: - Real M1 inventory vector

    func testRealM1InventoryVectorNoScalingAndCorrectHottest() {
        let snapshot = build([
            raw("pACC MTR Temp Sensor2", 36.5),
            raw("pACC MTR Temp Sensor3", 37.578125),
            raw("pACC MTR Temp Sensor4", 35.0),
            raw("pACC MTR Temp Sensor5", 34.0),
            raw("pACC MTR Temp Sensor7", 33.0),
            raw("pACC MTR Temp Sensor8", 32.0),
            raw("pACC MTR Temp Sensor9", 31.0),
            raw("eACC MTR Temp Sensor0", 32.390625),
            raw("eACC MTR Temp Sensor3", 33.859375),
            raw("GPU MTR Temp Sensor1", 30.0),
            raw("GPU MTR Temp Sensor4", 29.0),
            raw("SOC MTR Temp Sensor0", 35.453125),
            raw("SOC MTR Temp Sensor1", 34.0),
            raw("SOC MTR Temp Sensor2", 33.0),
            raw("PMGR SOC Die Temp Sensor0", 35.515625),
            raw("PMGR SOC Die Temp Sensor1", 34.5),
            raw("PMGR SOC Die Temp Sensor2", 33.5),
        ])
        XCTAssertEqual(snapshot.readings.count, 17)
        XCTAssertTrue(snapshot.diagnostics.isEmpty)
        // Deterministic product-name ordering (ASCII: uppercase before lowercase).
        XCTAssertEqual(snapshot.readings.first?.productName, "GPU MTR Temp Sensor1")
        XCTAssertEqual(snapshot.readings.last?.productName, "pACC MTR Temp Sensor9")
        // Hottest CPU is the pACC/eACC max; hottest control the CPU/GPU/SOC max.
        XCTAssertEqual(snapshot.hottestCPU?.productName, "pACC MTR Temp Sensor3")
        XCTAssertEqual(snapshot.hottestControl?.productName, "pACC MTR Temp Sensor3")
        // No scaling: the exact live float precision survives untouched.
        let pacc3 = snapshot.readings.first { $0.productName == "pACC MTR Temp Sensor3" }
        XCTAssertEqual(pacc3?.celsius, 37.578125)
        XCTAssertEqual(pacc3?.family, .pACC_CPU)
        let counts = Dictionary(grouping: snapshot.readings, by: \.family).mapValues(\.count)
        XCTAssertEqual(counts[.pACC_CPU], 7)
        XCTAssertEqual(counts[.eACC_CPU], 2)
        XCTAssertEqual(counts[.GPU], 2)
        XCTAssertEqual(counts[.SOC], 3)
        XCTAssertEqual(counts[.PMGR_SOC_DIE], 3)
    }

    // MARK: - Sendable

    func testPublicModelsBuilderAndSourceAreSendable() {
        requireSendable(ThermalSensorFamily.pACC_CPU)
        requireSendable(ThermalReadingDiagnostic.missingProduct)
        requireSendable(RawThermalReading(productName: "x", celsius: 30, sampledAt: 1))
        requireSendable(TrustedThermalReading(productName: "x", family: .GPU, celsius: 30, sampledAt: 1))
        requireSendable(TrustedThermalSnapshot(readings: [], hottestCPU: nil, hottestControl: nil, diagnostics: []))
        requireSendable(TrustedThermalSnapshotBuilder())
        let source: any TrustedThermalReadingSource = IOHIDTrustedThermalReader(
            sampler: IdentitySampler(template: raw("pACC MTR Temp Sensor2", 37.0))
        )
        requireSendable(source)
    }
}

// MARK: - Helpers

private func raw(_ productName: String?, _ celsius: Double?, sampledAt: UInt64 = 100_000_000_000) -> RawThermalReading {
    RawThermalReading(productName: productName, celsius: celsius, sampledAt: sampledAt)
}

private func build(
    _ rawReadings: [RawThermalReading],
    now: UInt64 = 100_000_000_000,
    maxAge: UInt64 = TrustedThermalSnapshotBuilder.defaultMaxAgeNanos
) -> TrustedThermalSnapshot {
    TrustedThermalSnapshotBuilder(maxAgeNanos: maxAge).build(rawReadings: rawReadings, now: now)
}

private struct IdentitySampler: RawThermalSampling {
    let template: RawThermalReading
    func copyRawThermalReadings(at now: UInt64) -> [RawThermalReading] {
        [RawThermalReading(productName: template.productName, celsius: template.celsius, sampledAt: now)]
    }
}

private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    let value: UInt64

    init(_ value: UInt64) {
        self.value = value
    }

    func call() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return value
    }

    func callCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private func requireSendable<T: Sendable>(_: T) {}
