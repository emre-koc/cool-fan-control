import XCTest
@testable import FanControlCore

/// WriteThrottle — pure, deterministic, stateful write-rate limiter.
///
/// Exact semantics pinned here (see the milestone doc for the full policy):
/// - First command of any kind → `.send` immediately (no interval/change gate).
/// - `proposed == nil` (automatic restore): sent when nothing was ever sent or
///   when the last *sent* command was manual (restore is safety-critical and
///   never rate-limited); skipped when the last sent command was already
///   automatic (auto-only-once policy).
/// - Manual proposal: interval gate (`now - lastSentAt >= minimumIntervalNanos`)
///   applies after the first send; then either
///   - mode changed (last sent was automatic) → change gate against the
///     caller-supplied `previousRPM` (actual RPM — the best reference after
///     Apple takes over); `|Δ| >= minimumChangeRPM` sends, else skip, or
///   - same mode (manual → manual) → change gate against the last written
///     target; `|Δ| >= minimumChangeRPM` sends (equality at the boundary
///     SENDS), else skip.
/// - Clock regression (`now < lastSentAtNanos`) is an anomaly → `.skip`,
///   never a write.
/// - `minimumChangeRPM == 0` disables the change gate (every same-mode
///   proposal sends once the interval has elapsed, even with equal targets).
final class WriteThrottleTests: XCTestCase {
    private let defaultInterval: UInt64 = 2_000_000_000

    private func command(_ rpm: Double, fanIndex: Int = 0, min: Double = 1700, max: Double = 4499) throws -> FanWriteCommand {
        try FanWriteCommand(fanIndex: fanIndex, mode: .manual, targetRPM: rpm, minimumRPM: min, maximumRPM: max)
    }

    private func throttle(interval: UInt64 = 2_000_000_000, change: Double = 100) -> WriteThrottle {
        WriteThrottle(config: WriteThrottleConfig(minimumIntervalNanos: interval, minimumChangeRPM: change))
    }

    // MARK: - First command

    func testFirstManualCommandSendsImmediately() throws {
        var throttle = self.throttle()
        XCTAssertEqual(
            throttle.tick(now: 0, proposed: try command(2500), previousRPM: 1700),
            .send(try command(2500))
        )
    }

    func testFirstAutomaticCommandSendsImmediately() {
        var throttle = self.throttle()
        XCTAssertEqual(throttle.tick(now: 0, proposed: nil, previousRPM: nil), .send(nil))
    }

    // MARK: - Equal target / mode → skip

    func testEqualManualTargetSkipsAfterInterval() throws {
        var throttle = self.throttle()
        _ = throttle.tick(now: 0, proposed: try command(2500), previousRPM: 1700)
        XCTAssertEqual(
            throttle.tick(now: 5_000_000_000, proposed: try command(2500), previousRPM: 2500),
            .skip,
            "equal target and mode → no redundant write"
        )
    }

    func testEqualTargetSkipsBeforeInterval() throws {
        var throttle = self.throttle()
        _ = throttle.tick(now: 0, proposed: try command(2500), previousRPM: 1700)
        XCTAssertEqual(
            throttle.tick(now: 1_000_000_000, proposed: try command(2500), previousRPM: 2500),
            .skip
        )
    }

    // MARK: - Interval gate

    func testIntervalGateBoundaryExactElapsedSends() throws {
        var throttle = self.throttle()
        _ = throttle.tick(now: 0, proposed: try command(2500), previousRPM: 1700)
        XCTAssertEqual(
            throttle.tick(now: defaultInterval, proposed: try command(2600), previousRPM: 2500),
            .send(try command(2600)),
            "interval exactly elapsed (>=) + change 100 == minimumChangeRPM → sends"
        )
    }

    func testIntervalGateJustBeforeElapsedSkips() throws {
        var throttle = self.throttle()
        _ = throttle.tick(now: 0, proposed: try command(2500), previousRPM: 1700)
        XCTAssertEqual(
            throttle.tick(now: defaultInterval - 1, proposed: try command(2600), previousRPM: 2500),
            .skip
        )
    }

    func testSkipDoesNotAdvanceLastSentTimestamp() throws {
        var throttle = self.throttle()
        _ = throttle.tick(now: 0, proposed: try command(2500), previousRPM: 1700)
        XCTAssertEqual(throttle.tick(now: 1_000_000_000, proposed: try command(2600), previousRPM: 2500), .skip)
        XCTAssertEqual(throttle.tick(now: 1_500_000_000, proposed: try command(2600), previousRPM: 2500), .skip)
        XCTAssertEqual(
            throttle.tick(now: 2_000_000_000, proposed: try command(2600), previousRPM: 2500),
            .send(try command(2600)),
            "interval measured from the last SEND, not the last skip"
        )
    }

    // MARK: - Change gate

    func testChangeGateBoundaryEqualitySends() throws {
        var throttle = self.throttle()
        _ = throttle.tick(now: 0, proposed: try command(1700), previousRPM: 1700)
        XCTAssertEqual(
            throttle.tick(now: 3_000_000_000, proposed: try command(1800), previousRPM: 1700),
            .send(try command(1800)),
            "|Δ| == minimumChangeRPM (100) → sends (>=)"
        )
    }

    func testChangeGateJustBelowBoundarySkips() throws {
        var throttle = self.throttle()
        _ = throttle.tick(now: 0, proposed: try command(1700), previousRPM: 1700)
        XCTAssertEqual(
            throttle.tick(now: 3_000_000_000, proposed: try command(1799), previousRPM: 1700),
            .skip,
            "|Δ| = 99 < 100 → skip"
        )
    }

    func testLargeChangeSendsAfterInterval() throws {
        var throttle = self.throttle()
        _ = throttle.tick(now: 0, proposed: try command(2000), previousRPM: 1700)
        XCTAssertEqual(
            throttle.tick(now: 3_000_000_000, proposed: try command(2200), previousRPM: 2000),
            .send(try command(2200))
        )
    }

    // MARK: - Mode change

    func testModeChangeManualToAutomaticSendsImmediately() throws {
        var throttle = self.throttle()
        _ = throttle.tick(now: 0, proposed: try command(2500), previousRPM: 1700)
        XCTAssertEqual(
            throttle.tick(now: 500_000_000, proposed: nil, previousRPM: 2500),
            .send(nil),
            "restore to automatic bypasses the interval gate (safety)"
        )
    }

    func testModeChangeAutomaticToManualSendsWhenMeaningful() throws {
        var throttle = self.throttle()
        _ = throttle.tick(now: 0, proposed: nil, previousRPM: nil)
        XCTAssertEqual(
            throttle.tick(now: 3_000_000_000, proposed: try command(2500), previousRPM: 1700),
            .send(try command(2500)),
            "auto→manual with |Δ| >= minimumChangeRPM against actual RPM → sends"
        )
    }

    func testModeChangeAutomaticToManualTrivialChangeSkips() throws {
        var throttle = self.throttle()
        _ = throttle.tick(now: 0, proposed: nil, previousRPM: nil)
        XCTAssertEqual(
            throttle.tick(now: 3_000_000_000, proposed: try command(1750), previousRPM: 1700),
            .skip,
            "auto→manual with |Δ| = 50 < 100 vs actual RPM → skip (do not yank control for an imperceptible difference)"
        )
    }

    func testModeChangeAutomaticToManualBeforeIntervalSkips() throws {
        var throttle = self.throttle()
        _ = throttle.tick(now: 0, proposed: nil, previousRPM: nil)
        XCTAssertEqual(
            throttle.tick(now: 1_000_000_000, proposed: try command(2500), previousRPM: 1700),
            .skip,
            "interval gate still applies to auto→manual"
        )
    }

    func testNonFinitePreviousRPMDoesNotSuppressWrite() throws {
        var throttle = self.throttle()
        _ = throttle.tick(now: 0, proposed: nil, previousRPM: nil)
        XCTAssertEqual(
            throttle.tick(now: 3_000_000_000, proposed: try command(2500), previousRPM: .nan),
            .send(try command(2500)),
            "cannot prove redundancy against a garbage reference → send"
        )
    }

    // MARK: - Auto-only-once policy

    func testAutoOnlyOncePolicy() throws {
        var throttle = self.throttle()
        XCTAssertEqual(throttle.tick(now: 0, proposed: nil, previousRPM: nil), .send(nil))
        XCTAssertEqual(
            throttle.tick(now: 10_000_000_000, proposed: nil, previousRPM: nil),
            .skip,
            "repeated automatic command is sent only once until something changes"
        )
        // A manual write breaks the auto streak; the next restore is sent again.
        XCTAssertEqual(throttle.tick(now: 11_000_000_000, proposed: try command(2500), previousRPM: 1700), .send(try command(2500)))
        XCTAssertEqual(throttle.tick(now: 11_500_000_000, proposed: nil, previousRPM: 2500), .send(nil))
    }

    // MARK: - Clock anomaly

    func testFutureClockAnomalySkips() throws {
        var throttle = self.throttle()
        _ = throttle.tick(now: 1_000, proposed: try command(2500), previousRPM: 1700)
        XCTAssertEqual(
            throttle.tick(now: 500, proposed: try command(2600), previousRPM: 2500),
            .skip,
            "now < lastSentAt is an anomaly → never write"
        )
        XCTAssertEqual(
            throttle.tick(now: 500, proposed: nil, previousRPM: nil),
            .skip,
            "anomaly also suppresses a restore"
        )
    }

    // MARK: - Custom config

    func testCustomConfig() throws {
        var throttle = throttle(interval: 500_000_000, change: 50)
        _ = throttle.tick(now: 0, proposed: try command(1700), previousRPM: 1700)
        XCTAssertEqual(throttle.tick(now: 400_000_000, proposed: try command(1750), previousRPM: 1700), .skip)
        XCTAssertEqual(
            throttle.tick(now: 600_000_000, proposed: try command(1750), previousRPM: 1700),
            .send(try command(1750)),
            "interval 500ms elapsed and |Δ| = 50 == minimumChangeRPM → sends"
        )
    }

    func testZeroMinimumChangeDisablesChangeGate() throws {
        var throttle = throttle(interval: 1, change: 0)
        _ = throttle.tick(now: 0, proposed: try command(2500), previousRPM: 1700)
        XCTAssertEqual(
            throttle.tick(now: 2, proposed: try command(2500), previousRPM: 2500),
            .send(try command(2500)),
            "0 disables the change gate → even an equal target sends once the interval elapsed"
        )
    }

    // MARK: - Reset

    func testResetClearsState() throws {
        var throttle = self.throttle()
        _ = throttle.tick(now: 0, proposed: try command(2500), previousRPM: 1700)
        throttle.reset()
        XCTAssertNil(throttle.lastSentAtNanos)
        XCTAssertNil(throttle.lastSentMode)
        XCTAssertNil(throttle.lastSentTargetRPM)
        XCTAssertEqual(
            throttle.tick(now: 1, proposed: try command(2500), previousRPM: nil),
            .send(try command(2500)),
            "after reset the next tick is treated as the first command"
        )
    }

    // MARK: - Config Codable

    func testConfigCodableRoundTrip() throws {
        let config = WriteThrottleConfig(minimumIntervalNanos: 500_000_000, minimumChangeRPM: 50)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(WriteThrottleConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testConfigDecodeRejectsInvalidValues() {
        XCTAssertThrowsError(try JSONDecoder().decode(
            WriteThrottleConfig.self,
            from: Data(#"{"minimumIntervalNanos":0,"minimumChangeRPM":100}"#.utf8)
        ))
        XCTAssertThrowsError(try JSONDecoder().decode(
            WriteThrottleConfig.self,
            from: Data(#"{"minimumIntervalNanos":100,"minimumChangeRPM":-5}"#.utf8)
        ))
    }

    // MARK: - Sendable / Equatable

    func testThrottleTypesAreSendableAndEquatable() throws {
        let config = WriteThrottleConfig()
        requireSendable(config)
        requireSendable(WriteThrottle(config: config))
        requireSendable(WriteThrottleDecision.skip)
        requireSendable(WriteThrottleDecision.send(try command(2500)))
        requireSendable(WriteThrottleDecision.send(nil))

        var a = throttle()
        var b = throttle()
        _ = a.tick(now: 0, proposed: try command(2500), previousRPM: 1700)
        _ = b.tick(now: 0, proposed: try command(2500), previousRPM: 1700)
        XCTAssertEqual(a, b, "identical input sequences → identical state")
    }
}

private func requireSendable<T: Sendable>(_: T) {}
