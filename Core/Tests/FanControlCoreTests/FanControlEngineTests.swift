import XCTest
@testable import FanControlCore

final class FanControlEngineTests: XCTestCase {
    private let fan0 = FanBounds(minimumRPM: 1700, maximumRPM: 4499) // M1 mini reference
    private let fan1 = FanBounds(minimumRPM: 2000, maximumRPM: 4000)

    private func defaultCurve() throws -> TemperatureCurve {
        try TemperatureCurve.default(minimumRPM: 1700, maximumRPM: 4499)
    }

    // MARK: - Auto mode

    func testAutoModeYieldsNilTargetsWhenNoOverrides() throws {
        var engine = FanControlEngine()
        var batteryRule = BatteryCoolingRule()
        var cpuGuard = CpuThrottleGuard()
        let targets = engine.tick(
            mode: .auto,
            curve: try defaultCurve(),
            hottestControlCelsius: 40,
            hottestCPUCelsius: 40,
            isCharging: false,
            batteryTemperatureC: nil,
            fanBounds: [fan0],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        XCTAssertEqual(targets, [FanTarget(fanIndex: 0, effectiveRPM: nil)], "auto → nil target → no write")
    }

    func testAutoModeStillHonorsCpuGuard() throws {
        var engine = FanControlEngine()
        var batteryRule = BatteryCoolingRule()
        var cpuGuard = CpuThrottleGuard()
        let targets = engine.tick(
            mode: .auto,
            curve: try defaultCurve(),
            hottestControlCelsius: 40,
            hottestCPUCelsius: 95,
            isCharging: false,
            batteryTemperatureC: nil,
            fanBounds: [fan0],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        XCTAssertEqual(targets, [FanTarget(fanIndex: 0, effectiveRPM: 4499)], "CPU guard overrides any mode, incl. auto")
    }

    func testEmptyFanListYieldsEmptyTargets() throws {
        var engine = FanControlEngine()
        var batteryRule = BatteryCoolingRule()
        var cpuGuard = CpuThrottleGuard()
        let targets = engine.tick(
            mode: .max,
            curve: try defaultCurve(),
            hottestControlCelsius: nil,
            hottestCPUCelsius: nil,
            isCharging: false,
            batteryTemperatureC: nil,
            fanBounds: [],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        XCTAssertEqual(targets, [], "fanless machine → no targets")
    }

    // MARK: - Fixed modes (quiet / max / manual)

    func testQuietMapsToFanMinimum() throws {
        var engine = FanControlEngine()
        var batteryRule = BatteryCoolingRule()
        var cpuGuard = CpuThrottleGuard()
        let targets = engine.tick(
            mode: .quiet,
            curve: try defaultCurve(),
            hottestControlCelsius: nil,
            hottestCPUCelsius: 40,
            isCharging: false,
            batteryTemperatureC: nil,
            fanBounds: [fan0],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        XCTAssertEqual(targets, [FanTarget(fanIndex: 0, effectiveRPM: 1700)])
    }

    func testMaxMapsToFanMaximum() throws {
        var engine = FanControlEngine()
        var batteryRule = BatteryCoolingRule()
        var cpuGuard = CpuThrottleGuard()
        let targets = engine.tick(
            mode: .max,
            curve: try defaultCurve(),
            hottestControlCelsius: nil,
            hottestCPUCelsius: 40,
            isCharging: false,
            batteryTemperatureC: nil,
            fanBounds: [fan0],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        XCTAssertEqual(targets, [FanTarget(fanIndex: 0, effectiveRPM: 4499)])
    }

    func testManualInsideRangeUnclamped() throws {
        var engine = FanControlEngine()
        var batteryRule = BatteryCoolingRule()
        var cpuGuard = CpuThrottleGuard()
        let targets = engine.tick(
            mode: .manual(rpm: 2500),
            curve: try defaultCurve(),
            hottestControlCelsius: nil,
            hottestCPUCelsius: 40,
            isCharging: false,
            batteryTemperatureC: nil,
            fanBounds: [fan0],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        XCTAssertEqual(targets, [FanTarget(fanIndex: 0, effectiveRPM: 2500)])
    }

    func testManualBelowMinimumClamped() throws {
        var engine = FanControlEngine()
        var batteryRule = BatteryCoolingRule()
        var cpuGuard = CpuThrottleGuard()
        let targets = engine.tick(
            mode: .manual(rpm: 500),
            curve: try defaultCurve(),
            hottestControlCelsius: nil,
            hottestCPUCelsius: 40,
            isCharging: false,
            batteryTemperatureC: nil,
            fanBounds: [fan0],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        XCTAssertEqual(targets, [FanTarget(fanIndex: 0, effectiveRPM: 1700)])
    }

    func testManualAboveMaximumClamped() throws {
        var engine = FanControlEngine()
        var batteryRule = BatteryCoolingRule()
        var cpuGuard = CpuThrottleGuard()
        let targets = engine.tick(
            mode: .manual(rpm: 9000),
            curve: try defaultCurve(),
            hottestControlCelsius: nil,
            hottestCPUCelsius: 40,
            isCharging: false,
            batteryTemperatureC: nil,
            fanBounds: [fan0],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        XCTAssertEqual(targets, [FanTarget(fanIndex: 0, effectiveRPM: 4499)])
    }

    func testPerFanClampingWithTwoFansDifferingRanges() throws {
        func targets(mode: FanMode) throws -> [FanTarget] {
            var engine = FanControlEngine()
            var batteryRule = BatteryCoolingRule()
            var cpuGuard = CpuThrottleGuard()
            return engine.tick(
                mode: mode,
                curve: try defaultCurve(),
                hottestControlCelsius: nil,
                hottestCPUCelsius: 40,
                isCharging: false,
                batteryTemperatureC: nil,
                fanBounds: [fan0, fan1],
                batteryRule: &batteryRule,
                cpuGuard: &cpuGuard
            )
        }
        XCTAssertEqual(try targets(mode: .manual(rpm: 1000)), [
            FanTarget(fanIndex: 0, effectiveRPM: 1700),
            FanTarget(fanIndex: 1, effectiveRPM: 2000),
        ])
        XCTAssertEqual(try targets(mode: .manual(rpm: 5000)), [
            FanTarget(fanIndex: 0, effectiveRPM: 4499),
            FanTarget(fanIndex: 1, effectiveRPM: 4000),
        ])
        XCTAssertEqual(try targets(mode: .manual(rpm: 3000)), [
            FanTarget(fanIndex: 0, effectiveRPM: 3000),
            FanTarget(fanIndex: 1, effectiveRPM: 3000),
        ])
        XCTAssertEqual(try targets(mode: .quiet), [
            FanTarget(fanIndex: 0, effectiveRPM: 1700),
            FanTarget(fanIndex: 1, effectiveRPM: 2000),
        ])
        XCTAssertEqual(try targets(mode: .max), [
            FanTarget(fanIndex: 0, effectiveRPM: 4499),
            FanTarget(fanIndex: 1, effectiveRPM: 4000),
        ])
    }

    // MARK: - Smart mode via curve + hysteresis

    func testSmartCurveEndpoints() throws {
        var engine = FanControlEngine()
        var batteryRule = BatteryCoolingRule()
        var cpuGuard = CpuThrottleGuard()
        let cold = engine.tick(
            mode: .smart,
            curve: try defaultCurve(),
            hottestControlCelsius: 40,
            hottestCPUCelsius: 40,
            isCharging: false,
            batteryTemperatureC: nil,
            fanBounds: [fan0],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        XCTAssertEqual(cold, [FanTarget(fanIndex: 0, effectiveRPM: 1700)])
        let hot = engine.tick(
            mode: .smart,
            curve: try defaultCurve(),
            hottestControlCelsius: 85,
            hottestCPUCelsius: 40,
            isCharging: false,
            batteryTemperatureC: nil,
            fanBounds: [fan0],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        XCTAssertEqual(hot, [FanTarget(fanIndex: 0, effectiveRPM: 4499)])
    }

    func testSmartCurveMidpointExact() throws {
        var engine = FanControlEngine()
        var batteryRule = BatteryCoolingRule()
        var cpuGuard = CpuThrottleGuard()
        let targets = engine.tick(
            mode: .smart,
            curve: try defaultCurve(),
            hottestControlCelsius: 62.5,
            hottestCPUCelsius: 40,
            isCharging: false,
            batteryTemperatureC: nil,
            fanBounds: [fan0],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        XCTAssertEqual(targets, [FanTarget(fanIndex: 0, effectiveRPM: 3099.5)])
    }

    func testSmartAntiHuntHoldsWithinBandAndStepsBelowIt() throws {
        var engine = FanControlEngine()
        var batteryRule = BatteryCoolingRule()
        var cpuGuard = CpuThrottleGuard()
        func tick(_ celsius: Double?) -> [FanTarget] {
            engine.tick(
                mode: .smart,
                curve: try! defaultCurve(),
                hottestControlCelsius: celsius,
                hottestCPUCelsius: 40,
                isCharging: false,
                batteryTemperatureC: nil,
                fanBounds: [fan0],
                batteryRule: &batteryRule,
                cpuGuard: &cpuGuard
            )
        }
        XCTAssertEqual(tick(85), [FanTarget(fanIndex: 0, effectiveRPM: 4499)])
        // At 84 °C desired ≈ 4436.8; band = 5 % of 4499 = 224.95 → boundary ≈ 4274.05 → holds.
        XCTAssertEqual(tick(84), [FanTarget(fanIndex: 0, effectiveRPM: 4499)], "within band holds")
        // At 80 °C desired = 4188 < 4274.05 → steps down.
        XCTAssertEqual(tick(80), [FanTarget(fanIndex: 0, effectiveRPM: 4188)])
    }

    func testSmartOscillationDoesNotHunt() throws {
        var engine = FanControlEngine()
        var batteryRule = BatteryCoolingRule()
        var cpuGuard = CpuThrottleGuard()
        func tick(_ celsius: Double?) -> [FanTarget] {
            engine.tick(
                mode: .smart,
                curve: try! defaultCurve(),
                hottestControlCelsius: celsius,
                hottestCPUCelsius: 40,
                isCharging: false,
                batteryTemperatureC: nil,
                fanBounds: [fan0],
                batteryRule: &batteryRule,
                cpuGuard: &cpuGuard
            )
        }
        XCTAssertEqual(tick(85), [FanTarget(fanIndex: 0, effectiveRPM: 4499)])
        // Oscillate ±1 °C around the top for 20 ticks: target must never leave max.
        for _ in 0..<10 {
            XCTAssertEqual(tick(84), [FanTarget(fanIndex: 0, effectiveRPM: 4499)])
            XCTAssertEqual(tick(85), [FanTarget(fanIndex: 0, effectiveRPM: 4499)])
        }
    }

    // MARK: - Missing / nonfinite control temperature in smart mode

    func testSmartNilControlKeepsLastTarget() throws {
        var engine = FanControlEngine()
        var batteryRule = BatteryCoolingRule()
        var cpuGuard = CpuThrottleGuard()
        let ramp = engine.tick(
            mode: .smart,
            curve: try defaultCurve(),
            hottestControlCelsius: 60,
            hottestCPUCelsius: 40,
            isCharging: false,
            batteryTemperatureC: nil,
            fanBounds: [fan0],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        XCTAssertEqual(ramp, [FanTarget(fanIndex: 0, effectiveRPM: 2944)]) // 1700 + 2799 × 20/45
        let missing = engine.tick(
            mode: .smart,
            curve: try defaultCurve(),
            hottestControlCelsius: nil,
            hottestCPUCelsius: 40,
            isCharging: false,
            batteryTemperatureC: nil,
            fanBounds: [fan0],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        XCTAssertEqual(missing, [FanTarget(fanIndex: 0, effectiveRPM: 2944)], "missing data never interpreted as cold")
    }

    func testSmartNonFiniteControlKeepsLastTarget() throws {
        var engine = FanControlEngine()
        var batteryRule = BatteryCoolingRule()
        var cpuGuard = CpuThrottleGuard()
        _ = engine.tick(
            mode: .smart,
            curve: try defaultCurve(),
            hottestControlCelsius: 60,
            hottestCPUCelsius: 40,
            isCharging: false,
            batteryTemperatureC: nil,
            fanBounds: [fan0],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        for bad in [Double.nan, Double.infinity] {
            let targets = engine.tick(
                mode: .smart,
                curve: try defaultCurve(),
                hottestControlCelsius: bad,
                hottestCPUCelsius: 40,
                isCharging: false,
                batteryTemperatureC: nil,
                fanBounds: [fan0],
                batteryRule: &batteryRule,
                cpuGuard: &cpuGuard
            )
            XCTAssertEqual(targets, [FanTarget(fanIndex: 0, effectiveRPM: 2944)])
        }
    }

    func testSmartFirstTickNilControlYieldsNilTarget() throws {
        var engine = FanControlEngine()
        var batteryRule = BatteryCoolingRule()
        var cpuGuard = CpuThrottleGuard()
        let targets = engine.tick(
            mode: .smart,
            curve: try defaultCurve(),
            hottestControlCelsius: nil,
            hottestCPUCelsius: 40,
            isCharging: false,
            batteryTemperatureC: nil,
            fanBounds: [fan0],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        XCTAssertEqual(targets, [FanTarget(fanIndex: 0, effectiveRPM: nil)], "never initialized → no write (Apple auto)")
    }

    func testModeSwitchPreservesHysteresisState() throws {
        var engine = FanControlEngine()
        var batteryRule = BatteryCoolingRule()
        var cpuGuard = CpuThrottleGuard()
        _ = engine.tick(
            mode: .smart,
            curve: try defaultCurve(),
            hottestControlCelsius: 60,
            hottestCPUCelsius: 40,
            isCharging: false,
            batteryTemperatureC: nil,
            fanBounds: [fan0],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        _ = engine.tick(
            mode: .quiet,
            curve: try defaultCurve(),
            hottestControlCelsius: 60,
            hottestCPUCelsius: 40,
            isCharging: false,
            batteryTemperatureC: nil,
            fanBounds: [fan0],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        let backToSmart = engine.tick(
            mode: .smart,
            curve: try defaultCurve(),
            hottestControlCelsius: 60,
            hottestCPUCelsius: 40,
            isCharging: false,
            batteryTemperatureC: nil,
            fanBounds: [fan0],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        XCTAssertEqual(backToSmart, [FanTarget(fanIndex: 0, effectiveRPM: 2944)], "hysteresis state survives mode switches")
    }

    // MARK: - Per-fan bounds in smart mode

    func testSmartClampsPerFanBounds() throws {
        var engine = FanControlEngine()
        var batteryRule = BatteryCoolingRule()
        var cpuGuard = CpuThrottleGuard()
        // One curve (built for fan0) drives both fans; caller-provided bounds clamp per fan.
        let cold = engine.tick(
            mode: .smart,
            curve: try defaultCurve(),
            hottestControlCelsius: 40,
            hottestCPUCelsius: 40,
            isCharging: false,
            batteryTemperatureC: nil,
            fanBounds: [fan0, fan1],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        XCTAssertEqual(cold, [
            FanTarget(fanIndex: 0, effectiveRPM: 1700),
            FanTarget(fanIndex: 1, effectiveRPM: 2000),
        ])
        let hot = engine.tick(
            mode: .smart,
            curve: try defaultCurve(),
            hottestControlCelsius: 85,
            hottestCPUCelsius: 40,
            isCharging: false,
            batteryTemperatureC: nil,
            fanBounds: [fan0, fan1],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        XCTAssertEqual(hot, [
            FanTarget(fanIndex: 0, effectiveRPM: 4499),
            FanTarget(fanIndex: 1, effectiveRPM: 4000),
        ])
    }

    // MARK: - Override composition (EffectiveTargetRule)

    func testCpuGuardOverridesSmartTarget() throws {
        var engine = FanControlEngine()
        var batteryRule = BatteryCoolingRule()
        var cpuGuard = CpuThrottleGuard()
        let cool = engine.tick(
            mode: .smart,
            curve: try defaultCurve(),
            hottestControlCelsius: 40,
            hottestCPUCelsius: 40,
            isCharging: false,
            batteryTemperatureC: nil,
            fanBounds: [fan0],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        XCTAssertEqual(cool, [FanTarget(fanIndex: 0, effectiveRPM: 1700)])
        let engaged = engine.tick(
            mode: .smart,
            curve: try defaultCurve(),
            hottestControlCelsius: 40,
            hottestCPUCelsius: 90,
            isCharging: false,
            batteryTemperatureC: nil,
            fanBounds: [fan0],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        XCTAssertEqual(engaged, [FanTarget(fanIndex: 0, effectiveRPM: 4499)], "guard wins over smart")
        XCTAssertTrue(cpuGuard.engaged)
    }

    func testCpuGuardReleaseRestoresModeTarget() throws {
        var engine = FanControlEngine()
        var batteryRule = BatteryCoolingRule()
        var cpuGuard = CpuThrottleGuard()
        _ = engine.tick(
            mode: .smart,
            curve: try defaultCurve(),
            hottestControlCelsius: 40,
            hottestCPUCelsius: 95,
            isCharging: false,
            batteryTemperatureC: nil,
            fanBounds: [fan0],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        let released = engine.tick(
            mode: .smart,
            curve: try defaultCurve(),
            hottestControlCelsius: 40,
            hottestCPUCelsius: 80,
            isCharging: false,
            batteryTemperatureC: nil,
            fanBounds: [fan0],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        XCTAssertEqual(released, [FanTarget(fanIndex: 0, effectiveRPM: 1700)])
        XCTAssertFalse(cpuGuard.engaged)
    }

    func testBatteryMidOverridesQuiet() throws {
        var engine = FanControlEngine()
        var batteryRule = BatteryCoolingRule()
        var cpuGuard = CpuThrottleGuard()
        let targets = engine.tick(
            mode: .quiet,
            curve: try defaultCurve(),
            hottestControlCelsius: nil,
            hottestCPUCelsius: 40,
            isCharging: true,
            batteryTemperatureC: 34,
            fanBounds: [fan0],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        XCTAssertEqual(targets, [FanTarget(fanIndex: 0, effectiveRPM: 3099)], "battery mid (3099) beats quiet (1700)")
        XCTAssertEqual(batteryRule.tier, .mid, "engine advanced the battery rule")
    }

    func testMaxModeBeatsBatteryMid() throws {
        var engine = FanControlEngine()
        var batteryRule = BatteryCoolingRule()
        var cpuGuard = CpuThrottleGuard()
        let targets = engine.tick(
            mode: .max,
            curve: try defaultCurve(),
            hottestControlCelsius: nil,
            hottestCPUCelsius: 40,
            isCharging: true,
            batteryTemperatureC: 34,
            fanBounds: [fan0],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        XCTAssertEqual(targets, [FanTarget(fanIndex: 0, effectiveRPM: 4499)], "max mode equals/exceeds battery mid")
    }

    func testMaxModeVersusBatteryHighIsEqual() throws {
        var engine = FanControlEngine()
        var batteryRule = BatteryCoolingRule()
        var cpuGuard = CpuThrottleGuard()
        let targets = engine.tick(
            mode: .max,
            curve: try defaultCurve(),
            hottestControlCelsius: nil,
            hottestCPUCelsius: 40,
            isCharging: true,
            batteryTemperatureC: 36,
            fanBounds: [fan0],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        XCTAssertEqual(targets, [FanTarget(fanIndex: 0, effectiveRPM: 4499)], "max mode and battery high agree at fan max")
        XCTAssertEqual(batteryRule.tier, .high)
    }

    func testBatteryRuleReleasesAndTargetFallsBack() throws {
        var engine = FanControlEngine()
        var batteryRule = BatteryCoolingRule()
        var cpuGuard = CpuThrottleGuard()
        let engaged = engine.tick(
            mode: .quiet,
            curve: try defaultCurve(),
            hottestControlCelsius: nil,
            hottestCPUCelsius: 40,
            isCharging: true,
            batteryTemperatureC: 34,
            fanBounds: [fan0],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        XCTAssertEqual(engaged, [FanTarget(fanIndex: 0, effectiveRPM: 3099)])
        let unplugged = engine.tick(
            mode: .quiet,
            curve: try defaultCurve(),
            hottestControlCelsius: nil,
            hottestCPUCelsius: 40,
            isCharging: false,
            batteryTemperatureC: 34,
            fanBounds: [fan0],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        XCTAssertEqual(unplugged, [FanTarget(fanIndex: 0, effectiveRPM: 1700)], "unplug releases battery rule → quiet min returns")
    }

    func testEngineTicksCpuGuardState() throws {
        var engine = FanControlEngine()
        var batteryRule = BatteryCoolingRule()
        var cpuGuard = CpuThrottleGuard()
        XCTAssertFalse(cpuGuard.engaged)
        _ = engine.tick(
            mode: .auto,
            curve: try defaultCurve(),
            hottestControlCelsius: 40,
            hottestCPUCelsius: 95,
            isCharging: false,
            batteryTemperatureC: nil,
            fanBounds: [fan0],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        XCTAssertTrue(cpuGuard.engaged, "engine advanced the CPU guard")
    }

    // MARK: - Custom hysteresis band config

    func testCustomHysteresisBandChangesStepDownPoint() throws {
        var narrow = FanControlEngine()
        var wide = FanControlEngine(config: FanControlEngine.Config(hysteresisBandFraction: 0.2))
        var narrowBattery = BatteryCoolingRule()
        var wideBattery = BatteryCoolingRule()
        var narrowGuard = CpuThrottleGuard()
        var wideGuard = CpuThrottleGuard()
        let curve = try defaultCurve()
        func tick(_ engine: inout FanControlEngine, _ battery: inout BatteryCoolingRule, _ guardRule: inout CpuThrottleGuard, _ celsius: Double?) -> [FanTarget] {
            engine.tick(
                mode: .smart,
                curve: curve,
                hottestControlCelsius: celsius,
                hottestCPUCelsius: 40,
                isCharging: false,
                batteryTemperatureC: nil,
                fanBounds: [fan0],
                batteryRule: &battery,
                cpuGuard: &guardRule
            )
        }
        _ = tick(&narrow, &narrowBattery, &narrowGuard, 85)
        _ = tick(&wide, &wideBattery, &wideGuard, 85)
        // At 80 °C desired = 4188. Narrow band (5 % → boundary 4274.05) steps down;
        // wide band (20 % → boundary 3599.2) holds.
        let narrowResult = tick(&narrow, &narrowBattery, &narrowGuard, 80)
        let wideResult = tick(&wide, &wideBattery, &wideGuard, 80)
        XCTAssertEqual(narrowResult, [FanTarget(fanIndex: 0, effectiveRPM: 4188)])
        XCTAssertEqual(wideResult, [FanTarget(fanIndex: 0, effectiveRPM: 4499)])
    }

    // MARK: - State, determinism, types

    func testEngineStateIsEquatableAndResettable() throws {
        var engine = FanControlEngine()
        XCTAssertEqual(engine, FanControlEngine())
        var batteryRule = BatteryCoolingRule()
        var cpuGuard = CpuThrottleGuard()
        _ = engine.tick(
            mode: .smart,
            curve: try defaultCurve(),
            hottestControlCelsius: 60,
            hottestCPUCelsius: 40,
            isCharging: false,
            batteryTemperatureC: nil,
            fanBounds: [fan0],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        XCTAssertNotEqual(engine, FanControlEngine())
        XCTAssertEqual(engine.currentTarget(fanIndex: 0), 2944)
        XCTAssertNil(engine.currentTarget(fanIndex: 1))
        engine.reset()
        XCTAssertEqual(engine, FanControlEngine())
        XCTAssertNil(engine.currentTarget(fanIndex: 0))
    }

    func testDeterministicReplay() throws {
        var first = FanControlEngine()
        var second = FanControlEngine()
        var firstBattery = BatteryCoolingRule()
        var secondBattery = BatteryCoolingRule()
        var firstGuard = CpuThrottleGuard()
        var secondGuard = CpuThrottleGuard()
        let curve = try defaultCurve()
        let inputs: [(Double?, Double?, Bool, Double?)] = [
            (40, 40, false, nil),
            (60, 40, false, nil),
            (70, 90, false, nil),
            (70, 95, true, 34),
            (62.5, 80, true, 36),
            (nil, 40, false, nil),
            (85, 40, false, nil),
        ]
        for (control, cpu, charging, batteryTemp) in inputs {
            let a = first.tick(
                mode: .smart,
                curve: curve,
                hottestControlCelsius: control,
                hottestCPUCelsius: cpu,
                isCharging: charging,
                batteryTemperatureC: batteryTemp,
                fanBounds: [fan0, fan1],
                batteryRule: &firstBattery,
                cpuGuard: &firstGuard
            )
            let b = second.tick(
                mode: .smart,
                curve: curve,
                hottestControlCelsius: control,
                hottestCPUCelsius: cpu,
                isCharging: charging,
                batteryTemperatureC: batteryTemp,
                fanBounds: [fan0, fan1],
                batteryRule: &secondBattery,
                cpuGuard: &secondGuard
            )
            XCTAssertEqual(a, b)
        }
        XCTAssertEqual(first, second)
        XCTAssertEqual(firstBattery, secondBattery)
        XCTAssertEqual(firstGuard, secondGuard)
    }

    func testConfigDefaultAndCodableRoundTrip() throws {
        let config = FanControlEngine.Config()
        XCTAssertEqual(config.hysteresisBandFraction, 0.05)
        XCTAssertEqual(FanControlEngine.Config.default, config)
        let custom = FanControlEngine.Config(hysteresisBandFraction: 0.1)
        let data = try JSONEncoder().encode(custom)
        let decoded = try JSONDecoder().decode(FanControlEngine.Config.self, from: data)
        XCTAssertEqual(decoded, custom)
    }

    func testConfigDecodeRejectsOutOfRangeBandFraction() {
        for json in [#"{"hysteresisBandFraction":2}"#, #"{"hysteresisBandFraction":-0.5}"#] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(FanControlEngine.Config.self, from: Data(json.utf8))
            )
        }
    }

    func testFanBoundsDecodeRejectsInvalidRanges() {
        for json in [#"{"minimumRPM":5000,"maximumRPM":1000}"#, #"{"minimumRPM":-1,"maximumRPM":1000}"#] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(FanBounds.self, from: Data(json.utf8))
            )
        }
    }

    func testFanCountShrinkAndReexpandRetainsHysteresisState() throws {
        // Apple Silicon fan topology is static, but if discovery ever reports a
        // transient count change, per-fan state keyed by index is retained and
        // the band corrects stale heat within one tick.
        var engine = FanControlEngine()
        var batteryRule = BatteryCoolingRule()
        var cpuGuard = CpuThrottleGuard()
        _ = engine.tick(
            mode: .smart,
            curve: try defaultCurve(),
            hottestControlCelsius: 60,
            hottestCPUCelsius: 40,
            isCharging: false,
            batteryTemperatureC: nil,
            fanBounds: [fan0, fan1],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        let held = engine.currentTarget(fanIndex: 0)
        XCTAssertNotNil(held)

        // Shrink to one fan: fan 1 state is retained but not used.
        _ = engine.tick(
            mode: .smart,
            curve: try defaultCurve(),
            hottestControlCelsius: 60,
            hottestCPUCelsius: 40,
            isCharging: false,
            batteryTemperatureC: nil,
            fanBounds: [fan0],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        // Re-expand at 59 °C: desired = 1700 + 2799·(19/45) ≈ 2881.9, which lies
        // INSIDE the band of the retained 2944 target (band 147.2, boundary
        // 2796.8) → the held target must survive. A fresh controller would have
        // initialized to ≈2881.9 instead — this proves state was retained.
        let reexpanded = engine.tick(
            mode: .smart,
            curve: try defaultCurve(),
            hottestControlCelsius: 59,
            hottestCPUCelsius: 40,
            isCharging: false,
            batteryTemperatureC: nil,
            fanBounds: [fan0, fan1],
            batteryRule: &batteryRule,
            cpuGuard: &cpuGuard
        )
        XCTAssertEqual(reexpanded[1].effectiveRPM, engine.currentTarget(fanIndex: 1))
        XCTAssertEqual(reexpanded[1].effectiveRPM, 2944, "retained heat state held within band, not cold re-init")
    }

    func testModelsAreSendable() throws {
        requireSendable(FanControlEngine())
        requireSendable(FanControlEngine.Config())
        requireSendable(fan0)
        requireSendable(FanTarget(fanIndex: 0, effectiveRPM: 1700))
    }
}

private func requireSendable<T: Sendable>(_: T) {}
