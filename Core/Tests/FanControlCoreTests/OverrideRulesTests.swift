import XCTest
@testable import FanControlCore

final class BatteryCoolingRuleTests: XCTestCase {
    // MARK: - Exact hysteresis sequence (must pass)

    func testExactRisingAndFallingSequence() {
        var rule = BatteryCoolingRule()
        // Rising: off until > 33, mid until > 35, then high.
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 32.9), .off)
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 33.1), .mid)
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 35.1), .high)
        // Falling: high holds at 33.1 (release < 33), falls to mid at 32.9.
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 33.1), .high)
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 32.9), .mid)
        // Mid holds at 31.1, falls to off below 31.
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 31.1), .mid)
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 30.9), .off)
    }

    func testUnplugWhileEngagedReleasesImmediately() {
        var rule = BatteryCoolingRule()
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 36), .high)
        XCTAssertEqual(rule.tier, .high)
        XCTAssertEqual(rule.tick(isCharging: false, batteryTempC: 36), .off)
        XCTAssertEqual(rule.tier, .off)
    }

    // MARK: - Not charging

    func testNotChargingNeverOverridesEvenAtHighTemperature() {
        var rule = BatteryCoolingRule()
        for temperature in [40.0, 45.0, 50.0, 60.0] {
            XCTAssertEqual(rule.tick(isCharging: false, batteryTempC: temperature), .off, "temp \(temperature)")
        }
        XCTAssertEqual(rule.tier, .off)
    }

    func testChargingStoppedMidEngagementReleases() {
        var rule = BatteryCoolingRule()
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 34), .mid)
        XCTAssertEqual(rule.tick(isCharging: false, batteryTempC: 34), .off)
    }

    // MARK: - Exact boundaries

    func testBoundaryAtMidEngageExactlyIsOff() {
        var rule = BatteryCoolingRule()
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 33.0), .off, "<= 33 is off")
    }

    func testBoundaryAtHighEngageExactlyIsMid() {
        var rule = BatteryCoolingRule()
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 35.0), .mid, "> 35 is high; exactly 35 is mid")
    }

    func testFallingFromHighAtExactlyReleaseHolds() {
        var rule = BatteryCoolingRule()
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 36), .high)
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 33.0), .high, "release requires < 33")
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 32.9), .mid)
    }

    func testFallingFromMidAtExactlyReleaseHolds() {
        var rule = BatteryCoolingRule()
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 34), .mid)
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 31.0), .mid, "release requires < 31")
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 30.9), .off)
    }

    func testMidHoldsWithinHysteresisBand() {
        var rule = BatteryCoolingRule()
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 34), .mid)
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 32.5), .mid)
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 33.8), .mid)
    }

    func testRisingDirectlyToHighFromOff() {
        var rule = BatteryCoolingRule()
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 36), .high)
    }

    func testMidRisingToHigh() {
        var rule = BatteryCoolingRule()
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 34), .mid)
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 35.1), .high)
    }

    // MARK: - Missing / nonfinite temperature

    func testMissingTemperatureNeverEngages() {
        var rule = BatteryCoolingRule()
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: nil), .off)
        XCTAssertEqual(rule.tier, .off)
    }

    func testNonfiniteTemperatureNeverEngages() {
        var rule = BatteryCoolingRule()
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: .nan), .off)
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: .infinity), .off)
        XCTAssertEqual(rule.tier, .off)
    }

    func testMissingTemperatureResetsEngagedState() {
        var rule = BatteryCoolingRule()
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 36), .high)
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: nil), .off, "missing data resets; never interpreted as hot")
        XCTAssertEqual(rule.tier, .off)
    }

    // MARK: - Decisions (RPM targets)

    func testDecisionDefaultsUseFloorMidpointAndFanMax() {
        // M1 mini reference: F0Mn=1700, F0Mx=4499.
        var rule = BatteryCoolingRule()
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 34), .mid)
        XCTAssertEqual(rule.decision(fanMinimumRPM: 1700, fanMaximumRPM: 4499), .forceRPM(3099))
        XCTAssertEqual(rule.decision(fanMinimumRPM: 2000, fanMaximumRPM: 4000), .forceRPM(3000))

        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 36), .high)
        XCTAssertEqual(rule.decision(fanMinimumRPM: 1700, fanMaximumRPM: 4499), .forceRPM(4499))

        // Release path: high → mid at < 33, mid → off at < 31.
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 32.9), .mid)
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 30.9), .off)
        XCTAssertEqual(rule.decision(fanMinimumRPM: 1700, fanMaximumRPM: 4499), .inactive)
    }

    func testMidpointFormulaExactPolicy() {
        // Policy is exact: F0Mn + (F0Mx - F0Mn) / 2, floored.
        XCTAssertEqual(BatteryCoolingRule.midPointRPM(minimum: 1700, maximum: 4499), 3099)
        XCTAssertEqual(BatteryCoolingRule.midPointRPM(minimum: 0, maximum: 100), 50)
        XCTAssertEqual(BatteryCoolingRule.midPointRPM(minimum: 100, maximum: 100), 100)
    }

    func testDecisionHonorsConfiguredRPMS() {
        var rule = BatteryCoolingRule(config: BatteryCoolingConfig(midRPM: 2200, highRPM: 3000))
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 34), .mid)
        XCTAssertEqual(rule.decision(fanMinimumRPM: 1700, fanMaximumRPM: 4499), .forceRPM(2200))
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 36), .high)
        XCTAssertEqual(rule.decision(fanMinimumRPM: 1700, fanMaximumRPM: 4499), .forceRPM(3000))
    }

    // MARK: - Configurable thresholds

    func testCustomThresholdsHonored() {
        var rule = BatteryCoolingRule(config: BatteryCoolingConfig(
            midEngageC: 27, highEngageC: 30, midReleaseC: 25, highReleaseC: 27
        ))
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 26.9), .off)
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 27.1), .mid)
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 30.1), .high)
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 27.5), .high, "high release < 27")
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 26.9), .mid)
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 25.1), .mid, "mid release < 25")
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 24.9), .off)
    }

    func testConfigDefaultsMatchSpec() {
        let config = BatteryCoolingConfig()
        XCTAssertEqual(config.midEngageC, 33)
        XCTAssertEqual(config.highEngageC, 35)
        XCTAssertEqual(config.midReleaseC, 31)
        XCTAssertEqual(config.highReleaseC, 33)
        XCTAssertNil(config.midRPM)
        XCTAssertNil(config.highRPM)
        XCTAssertEqual(BatteryCoolingConfig.default, config)
    }

    func testConfigCodableRoundTrip() throws {
        let config = BatteryCoolingConfig(midEngageC: 27, highEngageC: 30, midReleaseC: 25, highReleaseC: 27, midRPM: 2200, highRPM: 3000)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(BatteryCoolingConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    // MARK: - State determinism

    func testRuleStateIsEquatableAndResettable() {
        var rule = BatteryCoolingRule()
        XCTAssertEqual(rule, BatteryCoolingRule())
        XCTAssertEqual(rule.tick(isCharging: true, batteryTempC: 36), .high)
        XCTAssertNotEqual(rule, BatteryCoolingRule())
        rule.reset()
        XCTAssertEqual(rule, BatteryCoolingRule())
        XCTAssertEqual(rule.tier, .off)
    }

    func testDeterministicPureReplay() {
        var first = BatteryCoolingRule()
        var second = BatteryCoolingRule()
        let inputs: [(Bool, Double?)] = [(true, 32.9), (true, 33.1), (true, 35.1), (true, 33.1), (true, 32.9), (true, 30.9)]
        for (charging, temp) in inputs {
            let a = first.tick(isCharging: charging, batteryTempC: temp)
            let b = second.tick(isCharging: charging, batteryTempC: temp)
            XCTAssertEqual(a, b)
        }
        XCTAssertEqual(first, second)
    }

    func testRuleModelsAreSendable() {
        requireSendable(BatteryCoolingTier.mid)
        requireSendable(BatteryCoolingConfig())
        requireSendable(BatteryCoolingRule())
        requireSendable(OverrideDecision.forceRPM(100))
    }
}

final class CpuThrottleGuardTests: XCTestCase {
    // MARK: - Exact engage/release boundaries

    func testEngageAtNinetyAndReleaseBelowEightyEight() {
        var guardRule = CpuThrottleGuard()
        XCTAssertFalse(guardRule.tick(hottestCPUCelsius: 89.9), "89.9 does not engage")
        XCTAssertTrue(guardRule.tick(hottestCPUCelsius: 90.0), "90.0 engages")
        XCTAssertTrue(guardRule.engaged)
        XCTAssertTrue(guardRule.tick(hottestCPUCelsius: 88.1), "88.1 stays engaged")
        XCTAssertTrue(guardRule.tick(hottestCPUCelsius: 88.0), "88.0 stays engaged (release below 88)")
        XCTAssertFalse(guardRule.tick(hottestCPUCelsius: 87.9), "87.9 releases")
        XCTAssertFalse(guardRule.engaged)
    }

    func testReleaseSequenceReengages() {
        var guardRule = CpuThrottleGuard()
        XCTAssertTrue(guardRule.tick(hottestCPUCelsius: 91), "engages")
        XCTAssertFalse(guardRule.tick(hottestCPUCelsius: 80), "releases")
        XCTAssertTrue(guardRule.tick(hottestCPUCelsius: 95), "re-engages")
    }

    // MARK: - Missing / nonfinite

    func testNilHottestCPUReleasesGuard() {
        var guardRule = CpuThrottleGuard()
        XCTAssertTrue(guardRule.tick(hottestCPUCelsius: 95))
        XCTAssertTrue(guardRule.engaged)
        XCTAssertFalse(guardRule.tick(hottestCPUCelsius: nil), "missing data releases; never hot, never cold")
        XCTAssertFalse(guardRule.engaged)
    }

    func testNonfiniteHottestCPUReleasesGuard() {
        var guardRule = CpuThrottleGuard()
        XCTAssertTrue(guardRule.tick(hottestCPUCelsius: 95))
        XCTAssertFalse(guardRule.tick(hottestCPUCelsius: .nan))
        XCTAssertTrue(guardRule.tick(hottestCPUCelsius: 95))
        XCTAssertFalse(guardRule.tick(hottestCPUCelsius: .infinity))
        XCTAssertFalse(guardRule.engaged)
    }

    func testNilNeverEngages() {
        var guardRule = CpuThrottleGuard()
        XCTAssertFalse(guardRule.tick(hottestCPUCelsius: nil))
        XCTAssertFalse(guardRule.engaged)
    }

    // MARK: - Decisions

    func testDecisionForcesFanMaxWhenEngaged() {
        var guardRule = CpuThrottleGuard()
        XCTAssertEqual(guardRule.decision(fanMaximumRPM: 4499), .inactive)
        _ = guardRule.tick(hottestCPUCelsius: 90.0)
        XCTAssertEqual(guardRule.decision(fanMaximumRPM: 4499), .forceRPM(4499))
        XCTAssertEqual(guardRule.decision(fanMaximumRPM: 3000), .forceRPM(3000))
    }

    // MARK: - Configurable thresholds

    func testCustomThresholdsHonored() {
        var guardRule = CpuThrottleGuard(config: CpuThrottleGuardConfig(engageC: 85, releaseC: 80))
        XCTAssertFalse(guardRule.tick(hottestCPUCelsius: 84.9))
        XCTAssertTrue(guardRule.tick(hottestCPUCelsius: 85.0))
        XCTAssertTrue(guardRule.tick(hottestCPUCelsius: 80.0), "release below 80")
        XCTAssertFalse(guardRule.tick(hottestCPUCelsius: 79.9))
    }

    func testConfigDefaultsMatchSpec() {
        let config = CpuThrottleGuardConfig()
        XCTAssertEqual(config.engageC, 90)
        XCTAssertEqual(config.releaseC, 88)
        XCTAssertEqual(CpuThrottleGuardConfig.default, config)
    }

    func testConfigCodableRoundTrip() throws {
        let config = CpuThrottleGuardConfig(engageC: 85, releaseC: 80)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CpuThrottleGuardConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    // MARK: - State determinism

    func testGuardStateIsEquatableAndResettable() {
        var guardRule = CpuThrottleGuard()
        XCTAssertEqual(guardRule, CpuThrottleGuard())
        _ = guardRule.tick(hottestCPUCelsius: 95)
        XCTAssertTrue(guardRule.engaged)
        XCTAssertNotEqual(guardRule, CpuThrottleGuard())
        guardRule.reset()
        XCTAssertFalse(guardRule.engaged)
        XCTAssertEqual(guardRule, CpuThrottleGuard())
    }

    func testGuardIsSendable() {
        requireSendable(CpuThrottleGuardConfig())
        requireSendable(CpuThrottleGuard())
    }
}

final class EffectiveTargetRuleTests: XCTestCase {
    func testAllNilTargetsYieldNilForAutoMode() {
        let target = EffectiveTargetRule.effectiveTarget(
            modeTarget: nil, cpuGuardTarget: nil, batteryTarget: nil,
            fanMinimumRPM: 1700, fanMaximumRPM: 4499
        )
        XCTAssertNil(target, "all nil → auto mode, no write")
    }

    func testSingleTargetClampedToMinimum() {
        let target = EffectiveTargetRule.effectiveTarget(
            modeTarget: 500, cpuGuardTarget: nil, batteryTarget: nil,
            fanMinimumRPM: 1700, fanMaximumRPM: 4499
        )
        XCTAssertEqual(target, 1700)
    }

    func testSingleTargetClampedToMaximum() {
        let target = EffectiveTargetRule.effectiveTarget(
            modeTarget: 9000, cpuGuardTarget: nil, batteryTarget: nil,
            fanMinimumRPM: 1700, fanMaximumRPM: 4499
        )
        XCTAssertEqual(target, 4499)
    }

    func testSingleTargetInsideRangeUnclamped() {
        let target = EffectiveTargetRule.effectiveTarget(
            modeTarget: 2000, cpuGuardTarget: nil, batteryTarget: nil,
            fanMinimumRPM: 1700, fanMaximumRPM: 4499
        )
        XCTAssertEqual(target, 2000)
    }

    func testCpuGuardBeatsBatteryBeatsMode() {
        let target = EffectiveTargetRule.effectiveTarget(
            modeTarget: 1500, cpuGuardTarget: 4499, batteryTarget: 3099,
            fanMinimumRPM: 1700, fanMaximumRPM: 4499
        )
        XCTAssertEqual(target, 4499, "max of all non-nil targets wins")
    }

    func testBatteryBeatsMode() {
        let target = EffectiveTargetRule.effectiveTarget(
            modeTarget: 1500, cpuGuardTarget: nil, batteryTarget: 3099,
            fanMinimumRPM: 1700, fanMaximumRPM: 4499
        )
        XCTAssertEqual(target, 3099)
    }

    func testModeAloneWhenOverridesInactive() {
        let target = EffectiveTargetRule.effectiveTarget(
            modeTarget: 2500, cpuGuardTarget: nil, batteryTarget: nil,
            fanMinimumRPM: 1700, fanMaximumRPM: 4499
        )
        XCTAssertEqual(target, 2500)
    }

    func testCpuGuardClampedWhenAboveMax() {
        let target = EffectiveTargetRule.effectiveTarget(
            modeTarget: nil, cpuGuardTarget: 5000, batteryTarget: nil,
            fanMinimumRPM: 1700, fanMaximumRPM: 4499
        )
        XCTAssertEqual(target, 4499)
    }

    func testEqualMinMaxAllowed() {
        let target = EffectiveTargetRule.effectiveTarget(
            modeTarget: 2000, cpuGuardTarget: nil, batteryTarget: nil,
            fanMinimumRPM: 2000, fanMaximumRPM: 2000
        )
        XCTAssertEqual(target, 2000)
    }

    func testNonFiniteTargetsAreIgnoredNotPropagated() {
        // A NaN config/mode target must never reach a write path; valid
        // safety targets still win after the garbage is filtered.
        let allNaN = EffectiveTargetRule.effectiveTarget(
            modeTarget: .nan, cpuGuardTarget: .nan, batteryTarget: .nan,
            fanMinimumRPM: 1700, fanMaximumRPM: 4499
        )
        XCTAssertNil(allNaN, "all non-finite → auto mode, no write")

        let guardStillWins = EffectiveTargetRule.effectiveTarget(
            modeTarget: .nan, cpuGuardTarget: 4499, batteryTarget: .nan,
            fanMinimumRPM: 1700, fanMaximumRPM: 4499
        )
        XCTAssertEqual(guardStillWins, 4499)

        let infinityIgnored = EffectiveTargetRule.effectiveTarget(
            modeTarget: .infinity, cpuGuardTarget: nil, batteryTarget: nil,
            fanMinimumRPM: 1700, fanMaximumRPM: 4499
        )
        XCTAssertNil(infinityIgnored)
    }

    func testTargetExactlyAtMinAndMax() {
        let atMin = EffectiveTargetRule.effectiveTarget(
            modeTarget: 1700, cpuGuardTarget: nil, batteryTarget: nil,
            fanMinimumRPM: 1700, fanMaximumRPM: 4499
        )
        XCTAssertEqual(atMin, 1700)
        let atMax = EffectiveTargetRule.effectiveTarget(
            modeTarget: 4499, cpuGuardTarget: nil, batteryTarget: nil,
            fanMinimumRPM: 1700, fanMaximumRPM: 4499
        )
        XCTAssertEqual(atMax, 4499)
    }

    func testRuleIsSendable() {
        requireSendable(EffectiveTargetRule.self)
    }
}

// MARK: - Helpers

private func requireSendable<T: Sendable>(_: T) {}
