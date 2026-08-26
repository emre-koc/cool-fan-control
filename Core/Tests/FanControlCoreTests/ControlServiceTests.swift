import XCTest
@testable import FanControlCore

/// ControlService — one coherent tick combining fan/thermal/battery readers,
/// the pure engine, per-fan write throttling, and the write-target seam.
///
/// Fail-safe policy pinned here: any transport failure (fan read, thermal
/// source) or a fully-stale thermal snapshot → restore automatic for every
/// known fan; stale manual targets are never kept. A *valid* thermal snapshot
/// with no readings is NOT a failure — existing engine semantics apply
/// (guard releases on nil CPU, smart hysteresis holds its last target).
final class ControlServiceTests: XCTestCase {
    // MARK: - Fakes

    private final class ResultBox<Value>: @unchecked Sendable {
        private var values: [Value]
        init(_ values: [Value]) { self.values = values }
        func next() -> Value {
            defer { if values.count > 1 { values.removeFirst() } }
            return values[0]
        }
    }

    private struct FakeFanDiscovery: FanDiscovering, Sendable {
        let box: ResultBox<Result<FanSnapshot, any Error>>
        func snapshot() async throws -> FanSnapshot { try box.next().get() }
    }

    private struct FakeThermalSource: TrustedThermalReadingSource, Sendable {
        let box: ResultBox<Result<TrustedThermalSnapshot, any Error>>
        func trustedSnapshot() async throws -> TrustedThermalSnapshot { try box.next().get() }
    }

    private struct FakeBatteryStatus: BatteryStatusProviding, Sendable {
        let box: ResultBox<BatteryState>
        func snapshot() async -> BatteryState { box.next() }
    }

    private actor RecordingFanWriteTargets: FanWriteTargets {
        private(set) var applied: [[FanWriteAction]] = []
        func apply(actions: [FanWriteAction]) async { applied.append(actions) }
    }

    private final class ScriptedClock: @unchecked Sendable {
        private var values: [UInt64]
        private var index = 0
        init(_ values: [UInt64]) { self.values = values }
        func next() -> UInt64 {
            defer { index += 1 }
            return values[min(index, values.count - 1)]
        }
    }

    private enum FakeTransportError: Error, Equatable, Sendable {
        case failed
    }

    // MARK: - Fixtures

    private let fan0 = FanInfo(index: 0, minimumRPM: 1700, maximumRPM: 4499, currentRPM: 1700, mode: .automatic, targetRPM: 0)
    private let fan1 = FanInfo(index: 1, minimumRPM: 2000, maximumRPM: 4000, currentRPM: 2000, mode: .automatic, targetRPM: 0)

    private func fan(current: Double, min: Double = 1700, max: Double = 4499) -> FanInfo {
        FanInfo(index: 0, minimumRPM: min, maximumRPM: max, currentRPM: current, mode: .automatic, targetRPM: 0)
    }

    private func thermal(controlCelsius: Double? = nil, cpuCelsius: Double? = nil, sampledAt: UInt64 = 1_000_000) -> TrustedThermalSnapshot {
        var raw: [RawThermalReading] = []
        if let controlCelsius {
            raw.append(RawThermalReading(productName: "SOC MTR Temp Sensor", celsius: controlCelsius, sampledAt: sampledAt))
        }
        if let cpuCelsius {
            raw.append(RawThermalReading(productName: "pACC MTR Temp Sensor", celsius: cpuCelsius, sampledAt: sampledAt))
        }
        return TrustedThermalSnapshotBuilder().build(rawReadings: raw, now: sampledAt)
    }

    private func makeConfig(mode: FanMode = .smart, throttle: WriteThrottleConfig = .default) throws -> ControlService.Config {
        ControlService.Config(
            mode: mode,
            curve: try TemperatureCurve.default(minimumRPM: 1700, maximumRPM: 4499),
            engine: .default,
            batteryCooling: .default,
            cpuGuard: .default,
            throttle: throttle
        )
    }

    private func makeService(
        fans: [Result<FanSnapshot, any Error>],
        thermal: [Result<TrustedThermalSnapshot, any Error>],
        battery: [BatteryState] = [.notPresent],
        mode: FanMode = .smart,
        clockValues: [UInt64] = [0],
        throttle: WriteThrottleConfig = .default
    ) throws -> (ControlService, RecordingFanWriteTargets) {
        let targets = RecordingFanWriteTargets()
        let clock = ScriptedClock(clockValues)
        let service = ControlService(
            fanDiscovery: FakeFanDiscovery(box: ResultBox(fans)),
            thermalSource: FakeThermalSource(box: ResultBox(thermal)),
            batteryStatus: FakeBatteryStatus(box: ResultBox(battery)),
            writeTargets: targets,
            config: try makeConfig(mode: mode, throttle: throttle),
            clock: { clock.next() }
        )
        return (service, targets)
    }

    private func manual(_ rpm: Double, fanIndex: Int = 0, min: Double = 1700, max: Double = 4499) throws -> FanWriteCommand {
        try FanWriteCommand(fanIndex: fanIndex, mode: .manual, targetRPM: rpm, minimumRPM: min, maximumRPM: max)
    }

    // MARK: - Happy path

    func testHappyPathOneFanM1Vectors() async throws {
        let (service, targets) = try makeService(
            fans: [.success(FanSnapshot(fans: [fan0]))],
            thermal: [.success(thermal(controlCelsius: 62.5))],
            mode: .smart,
            clockValues: [0]
        )
        let state = await service.tick()

        XCTAssertEqual(state.timestampNanos, 0)
        XCTAssertEqual(state.fans, [fan0], "fan snapshot passthrough")
        XCTAssertEqual(state.hottestControl?.celsius, 62.5)
        XCTAssertNil(state.hottestCPU)
        XCTAssertEqual(state.battery, .notPresent)
        XCTAssertEqual(state.mode, .smart)
        XCTAssertEqual(state.failSafe, [])
        XCTAssertEqual(state.perFan.count, 1)
        XCTAssertEqual(state.perFan[0].fanIndex, 0)
        XCTAssertEqual(state.perFan[0].effectiveRPM, 3099.5, "M1 reference: 62.5 °C → 3099.5 RPM")
        XCTAssertEqual(state.perFan[0].action, .write(try manual(3099.5)))

        let applied = await targets.applied
        XCTAssertEqual(applied, [[.write(try manual(3099.5))]], "first tick sends immediately")
    }

    func testTwoFansDifferentBounds() async throws {
        let (service, targets) = try makeService(
            fans: [.success(FanSnapshot(fans: [fan0, fan1]))],
            thermal: [.success(thermal(controlCelsius: 40))],
            mode: .max,
            clockValues: [0]
        )
        let state = await service.tick()
        XCTAssertEqual(state.perFan.map(\.effectiveRPM), [4499, 4000], "per-fan clamping")
        let applied = await targets.applied
        XCTAssertEqual(applied, [[
            .write(try manual(4499, fanIndex: 0, min: 1700, max: 4499)),
            .write(try manual(4000, fanIndex: 1, min: 2000, max: 4000)),
        ]])
    }

    // MARK: - Fanless

    func testFanlessProducesNoCommands() async throws {
        let (service, targets) = try makeService(
            fans: [.success(FanSnapshot(fans: []))],
            thermal: [.success(thermal(controlCelsius: 40))],
            mode: .max,
            clockValues: [0]
        )
        let state = await service.tick()
        XCTAssertEqual(state.fans, [])
        XCTAssertEqual(state.perFan, [])
        XCTAssertEqual(state.failSafe, [])
        let applied = await targets.applied
        XCTAssertEqual(applied, [[]], "fanless → no fan commands at all")
    }

    // MARK: - Fail-safe: fan read failure

    func testFanReadFailureFirstEverIsFailSafe() async throws {
        let error = FanDiscoveryError.unsupportedFanCount(3)
        let (service, targets) = try makeService(
            fans: [.failure(error)],
            thermal: [.success(thermal(controlCelsius: 40))],
            mode: .manual(rpm: 2500),
            clockValues: [0]
        )
        let state = await service.tick()
        XCTAssertEqual(state.failSafe, [.fanReadFailed(reason: String(describing: error))], "typed failure surfaced")
        XCTAssertEqual(state.fans, [])
        XCTAssertEqual(state.perFan, [])
        let applied = await targets.applied
        XCTAssertEqual(applied, [[]], "no fans ever known → nothing to restore, no writes")
    }

    func testFanReadFailureAfterManualRestoresAutomatic() async throws {
        let error = FanDiscoveryError.unsupportedFanCount(3)
        let (service, targets) = try makeService(
            fans: [.success(FanSnapshot(fans: [fan0])), .failure(error)],
            thermal: [.success(thermal(controlCelsius: 40))],
            mode: .manual(rpm: 2500),
            clockValues: [0, 1_000_000_000]
        )
        let first = await service.tick()
        XCTAssertEqual(first.failSafe, [])
        XCTAssertEqual(first.perFan[0].action, .write(try manual(2500)))

        let second = await service.tick()
        XCTAssertEqual(second.failSafe, [.fanReadFailed(reason: String(describing: error))])
        XCTAssertEqual(second.perFan, [FanControlState(fanIndex: 0, effectiveRPM: nil, action: .restoreAutomatic)],
                       "known fan is restored to automatic, never left on a stale manual target")
        let applied = await targets.applied
        XCTAssertEqual(applied, [[.write(try manual(2500))], [.restoreAutomatic]])
    }

    func testRecoveryAfterFanFailureReassertsManual() async throws {
        let error = FanDiscoveryError.unsupportedFanCount(3)
        let (service, targets) = try makeService(
            fans: [.success(FanSnapshot(fans: [fan(current: 1700)])), .failure(error), .success(FanSnapshot(fans: [fan(current: 2000)]))],
            thermal: [.success(thermal(controlCelsius: 40))],
            mode: .manual(rpm: 2500),
            clockValues: [0, 1_000_000_000, 3_000_000_000]
        )
        _ = await service.tick()
        _ = await service.tick()
        let recovered = await service.tick()
        XCTAssertEqual(recovered.failSafe, [])
        XCTAssertEqual(recovered.perFan[0].action, .write(try manual(2500)),
                       "after the fail-safe restore the manual target is re-asserted (change vs actual RPM is meaningful)")
        let applied = await targets.applied
        XCTAssertEqual(applied, [[.write(try manual(2500))], [.restoreAutomatic], [.write(try manual(2500))]])
    }

    // MARK: - Fail-safe: thermal source failure

    func testThermalSourceFailureRestoresAutomatic() async throws {
        let (service, targets) = try makeService(
            fans: [.success(FanSnapshot(fans: [fan0]))],
            thermal: [.failure(FakeTransportError.failed)],
            mode: .manual(rpm: 2500),
            clockValues: [0]
        )
        let state = await service.tick()
        XCTAssertEqual(state.failSafe, [.thermalSourceFailed(reason: "failed")])
        XCTAssertEqual(state.fans, [fan0], "fan snapshot still surfaced")
        XCTAssertEqual(state.perFan, [FanControlState(fanIndex: 0, effectiveRPM: nil, action: .restoreAutomatic)])
        let applied = await targets.applied
        XCTAssertEqual(applied, [[.restoreAutomatic]], "transport failure → restore auto, never keep stale manual")
    }

    // MARK: - Fail-safe: stale-all thermal

    func testStaleAllThermalRestoresAutomatic() async throws {
        let stale = TrustedThermalSnapshotBuilder().build(
            rawReadings: [RawThermalReading(productName: "pACC MTR Temp Sensor", celsius: 50, sampledAt: 0)],
            now: 10_000_000_000 // 10 s > 5 s max age → stale
        )
        let (service, targets) = try makeService(
            fans: [.success(FanSnapshot(fans: [fan0]))],
            thermal: [.success(stale)],
            mode: .smart,
            clockValues: [10_000_000_000]
        )
        let state = await service.tick()
        XCTAssertEqual(state.failSafe, [.staleAllThermal])
        XCTAssertEqual(state.perFan, [FanControlState(fanIndex: 0, effectiveRPM: nil, action: .restoreAutomatic)])
        let applied = await targets.applied
        XCTAssertEqual(applied, [[.restoreAutomatic]])
    }

    // MARK: - Smart-curve input: CPU-inclusive hottestControl

    func testCPUHeatDrivesCurveBelowGuardThreshold() async throws {
        let (service, targets) = try makeService(
            fans: [.success(FanSnapshot(fans: [fan0]))],
            thermal: [.success(thermal(controlCelsius: 40, cpuCelsius: 85))],
            mode: .smart,
            clockValues: [0]
        )
        let state = await service.tick()
        XCTAssertEqual(state.failSafe, [])
        XCTAssertEqual(state.hottestControl?.celsius, 85,
                       "hottestControl is CPU-inclusive: pACC 85 beats SOC 40")
        XCTAssertEqual(state.hottestCPU?.celsius, 85)
        XCTAssertEqual(state.perFan[0].effectiveRPM, 4499,
                       "CPU below the 90 °C guard still drives the curve: 85 °C is the default curve's max point and the guard is NOT engaged")
        XCTAssertEqual(state.perFan[0].action, .write(try manual(4499)))
        let applied = await targets.applied
        XCTAssertEqual(applied, [[.write(try manual(4499))]])
    }

    // MARK: - Valid-but-empty thermal: existing engine semantics (NOT fail-safe)

    func testThermalNilGuardReleasesAndSmartHolds() async throws {
        let (service, targets) = try makeService(
            fans: [.success(FanSnapshot(fans: [fan0]))],
            thermal: [.success(thermal(controlCelsius: 60, cpuCelsius: 95)), .success(thermal())],
            mode: .smart,
            clockValues: [0, 3_000_000_000]
        )
        let engaged = await service.tick()
        XCTAssertEqual(engaged.failSafe, [])
        XCTAssertEqual(engaged.hottestControl?.celsius, 95,
                       "hottestControl is CPU-inclusive: pACC 95 beats SOC 60")
        XCTAssertEqual(engaged.hottestCPU?.celsius, 95)
        XCTAssertEqual(engaged.perFan[0].effectiveRPM, 4499,
                       "CPU-inclusive curve input 95 °C saturates the curve at fan max AND the guard is engaged → effective max")

        let held = await service.tick()
        XCTAssertEqual(held.failSafe, [], "empty-but-valid thermal snapshot is NOT a failure")
        XCTAssertNil(held.hottestControl)
        XCTAssertNil(held.hottestCPU)
        XCTAssertEqual(held.perFan[0].effectiveRPM, 4499,
                       "guard released on nil CPU; smart hysteresis holds the last (CPU-driven) target")
        XCTAssertEqual(held.perFan[0].action, .none,
                       "held target equals the last written target → throttle collapses the redundant write")
        let applied = await targets.applied
        XCTAssertEqual(applied, [[.write(try manual(4499))], [.none]])
    }

    // MARK: - Battery override

    func testBatteryChargingMidOverrideEngagesAndReleases() async throws {
        let charging = BatteryState(isPresent: true, isCharging: true, chargePercent: 50, temperatureC: 34)
        let cooling = BatteryState(isPresent: true, isCharging: true, chargePercent: 55, temperatureC: 30.9)
        let (service, targets) = try makeService(
            fans: [.success(FanSnapshot(fans: [fan0]))],
            thermal: [.success(thermal(controlCelsius: 40))],
            battery: [charging, cooling],
            mode: .quiet,
            clockValues: [0, 2_000_000_000]
        )
        let engaged = await service.tick()
        XCTAssertEqual(engaged.perFan[0].effectiveRPM, 3099, "mid tier = floored midpoint (1700+4499)/2")
        XCTAssertEqual(engaged.battery, charging)

        let released = await service.tick()
        XCTAssertEqual(released.perFan[0].effectiveRPM, 1700, "30.9 < 31 release → quiet target restored")
        let applied = await targets.applied
        XCTAssertEqual(applied, [[.write(try manual(3099))], [.write(try manual(1700))]])
    }

    // MARK: - Auto mode

    func testAutoModeEmitsAutomaticRestoreThenSkips() async throws {
        let (service, targets) = try makeService(
            fans: [.success(FanSnapshot(fans: [fan0]))],
            thermal: [.success(thermal(controlCelsius: 40))],
            mode: .auto,
            clockValues: [0, 1_000_000_000]
        )
        let first = await service.tick()
        XCTAssertEqual(first.perFan[0].effectiveRPM, nil)
        XCTAssertEqual(first.perFan[0].action, .restoreAutomatic, "auto mode → automatic command on first tick")
        XCTAssertEqual(first.failSafe, [])

        let second = await service.tick()
        XCTAssertEqual(second.perFan[0].action, .none, "repeated automatic command is throttled (auto-only-once)")
        let applied = await targets.applied
        XCTAssertEqual(applied, [[.restoreAutomatic], [.none]])
    }

    // MARK: - Throttling through the service

    func testRepeatedIdenticalTickIsThrottled() async throws {
        let (service, targets) = try makeService(
            fans: [.success(FanSnapshot(fans: [fan0]))],
            thermal: [.success(thermal(controlCelsius: 40))],
            mode: .manual(rpm: 2500),
            clockValues: [0, 1_000_000_000, 3_000_000_000]
        )
        let first = await service.tick()
        XCTAssertEqual(first.perFan[0].action, .write(try manual(2500)))
        let second = await service.tick()
        XCTAssertEqual(second.perFan[0].action, .none, "same target inside interval → skip")
        let third = await service.tick()
        XCTAssertEqual(third.perFan[0].action, .none, "same target after interval → equal → skip (no redundant writes)")
        let applied = await targets.applied
        XCTAssertEqual(applied, [[.write(try manual(2500))], [.none], [.none]])
    }

    // MARK: - setMode

    func testSetModeChangesCommands() async throws {
        let (service, targets) = try makeService(
            fans: [.success(FanSnapshot(fans: [fan0]))],
            thermal: [.success(thermal(controlCelsius: 40))],
            mode: .quiet,
            clockValues: [0, 3_000_000_000]
        )
        let quiet = await service.tick()
        XCTAssertEqual(quiet.perFan[0].effectiveRPM, 1700)
        await service.setMode(.max)
        let max = await service.tick()
        XCTAssertEqual(max.mode, .max)
        XCTAssertEqual(max.perFan[0].effectiveRPM, 4499)
        let applied = await targets.applied
        XCTAssertEqual(applied, [[.write(try manual(1700))], [.write(try manual(4499))]])
    }

    // MARK: - Determinism / Sendable

    func testInjectedClockDeterminism() async throws {
        func run() async throws -> ControlState {
            let (service, _) = try makeService(
                fans: [.success(FanSnapshot(fans: [fan0]))],
                thermal: [.success(thermal(controlCelsius: 62.5))],
                mode: .smart,
                clockValues: [42]
            )
            return await service.tick()
        }
        let first = try await run()
        let second = try await run()
        XCTAssertEqual(first, second, "same injected clock + same inputs → identical ControlState")
        XCTAssertEqual(first.timestampNanos, 42)
    }

    func testSendableFakesAndService() async throws {
        let (service, targets) = try makeService(
            fans: [.success(FanSnapshot(fans: [fan0]))],
            thermal: [.success(thermal(controlCelsius: 40))],
            mode: .smart,
            clockValues: [0]
        )
        requireSendable(service)
        requireSendable(targets)
        requireSendable(try makeConfig())
        let state = await service.tick()
        requireSendable(state)
        requireSendable(state.perFan[0])
        requireSendable(ControlFailure.staleAllThermal)
        requireSendable(FanWriteAction.none)
        requireSendable(FanWriteAction.restoreAutomatic)
    }
}

private func requireSendable<T: Sendable>(_: T) {}
