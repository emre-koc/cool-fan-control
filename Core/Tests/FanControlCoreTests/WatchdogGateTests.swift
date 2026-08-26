import XCTest
@testable import FanControlCore

/// Strict-TDD contract for the helper heartbeat watchdog gate.
///
/// Policy pinned here (uniform boundary rule): the gate asks for an automatic
/// restore only when the silent interval STRICTLY exceeds the configured
/// limit. At exact equality the gate is still armed (`age == timeout` and
/// `now == grace` both return false). A regressed monotonic clock with no
/// heartbeat restores immediately (fail-safe); a claimed heartbeat always
/// resets the timer — a live ping is the strongest evidence the app is alive.
final class WatchdogGateTests: XCTestCase {
    private let second: UInt64 = 1_000_000_000

    private func gate(timeoutSeconds: UInt64 = 30, graceSeconds: UInt64 = 10) -> WatchdogGate {
        WatchdogGate(config: WatchdogGateConfig(
            heartbeatTimeoutNanos: timeoutSeconds * second,
            startupGraceNanos: graceSeconds * second
        ))
    }

    // MARK: - Startup grace (no heartbeat ever)

    func testNoHeartbeatRestoresOnlyAfterGraceStrictlyElapses() {
        var gate = gate()
        XCTAssertFalse(gate.tick(now: 0, heartbeatReceived: false))
        XCTAssertFalse(gate.tick(now: 5 * second, heartbeatReceived: false))
        XCTAssertFalse(gate.tick(now: 9 * second, heartbeatReceived: false))
        // Grace equality boundary: exactly grace elapsed is still armed.
        XCTAssertFalse(gate.tick(now: 10 * second, heartbeatReceived: false))
        XCTAssertTrue(gate.tick(now: 10 * second + 1, heartbeatReceived: false))
        // Once restored, keeps asking until a heartbeat arrives.
        XCTAssertTrue(gate.tick(now: 11 * second, heartbeatReceived: false))
    }

    // MARK: - Heartbeat keeps the gate armed

    func testHeartbeatKeepsAliveUntilTimeoutStrictlyExceeds() {
        var gate = gate()
        _ = gate.tick(now: 1 * second, heartbeatReceived: true)
        XCTAssertFalse(gate.tick(now: 30 * second, heartbeatReceived: false))     // age 29s
        XCTAssertFalse(gate.tick(now: 31 * second, heartbeatReceived: false))     // age == 30s: armed
        XCTAssertTrue(gate.tick(now: 31 * second + 1, heartbeatReceived: false))  // age > 30s
    }

    func testHeartbeatResetsTimer() {
        var gate = gate()
        _ = gate.tick(now: 5 * second, heartbeatReceived: true)
        XCTAssertFalse(gate.tick(now: 34 * second, heartbeatReceived: false))     // age 29s
        _ = gate.tick(now: 35 * second, heartbeatReceived: true)                  // reset
        XCTAssertFalse(gate.tick(now: 64 * second, heartbeatReceived: false))     // age 29s
        XCTAssertFalse(gate.tick(now: 65 * second, heartbeatReceived: false))     // age == 30s: armed
        XCTAssertTrue(gate.tick(now: 65 * second + 1, heartbeatReceived: false))  // age > 30s
    }

    func testHeartbeatAfterTimeoutEndsRestore() {
        var gate = gate()
        _ = gate.tick(now: 5 * second, heartbeatReceived: true)
        XCTAssertTrue(gate.tick(now: 40 * second, heartbeatReceived: false))      // age 35s: restore
        XCTAssertTrue(gate.tick(now: 41 * second, heartbeatReceived: false))      // still restoring
        XCTAssertFalse(gate.tick(now: 42 * second, heartbeatReceived: true))      // app alive again
        XCTAssertFalse(gate.tick(now: 43 * second, heartbeatReceived: false))     // age 1s
    }

    func testFirstHeartbeatDuringGraceSwitchesToTimeoutDomain() {
        var gate = gate()
        XCTAssertFalse(gate.tick(now: 3 * second, heartbeatReceived: true))       // heartbeat during grace
        XCTAssertFalse(gate.tick(now: 32 * second, heartbeatReceived: false))     // age 29s
        XCTAssertFalse(gate.tick(now: 33 * second, heartbeatReceived: false))     // age == 30s: armed
        XCTAssertTrue(gate.tick(now: 33 * second + 1, heartbeatReceived: false))
    }

    // MARK: - Clock anomaly (fail-safe)

    func testFutureClockWithoutHeartbeatRestores() {
        var gate = gate()
        _ = gate.tick(now: 50 * second, heartbeatReceived: true)
        XCTAssertTrue(gate.tick(now: 49 * second, heartbeatReceived: false))      // regression: fail-safe
    }

    func testHeartbeatWithRegressedClockResetsTimer() {
        var gate = gate()
        _ = gate.tick(now: 50 * second, heartbeatReceived: true)
        XCTAssertFalse(gate.tick(now: 49 * second, heartbeatReceived: true))      // live ping wins
        XCTAssertFalse(gate.tick(now: 50 * second, heartbeatReceived: false))     // age 1s
        XCTAssertTrue(gate.tick(now: 80 * second, heartbeatReceived: false))      // age 31s > 30s
    }

    // MARK: - Reset

    func testResetClearsHeartbeatAndReappliesGrace() {
        var gate = gate()
        _ = gate.tick(now: 5 * second, heartbeatReceived: true)
        gate.reset()
        XCTAssertNil(gate.lastHeartbeatNanos)
        XCTAssertFalse(gate.tick(now: 9 * second, heartbeatReceived: false))      // grace from reset
        XCTAssertFalse(gate.tick(now: 10 * second, heartbeatReceived: false))     // == grace: armed
        XCTAssertTrue(gate.tick(now: 10 * second + 1, heartbeatReceived: false))
    }

    // MARK: - Custom config and defaults

    func testCustomConfig() {
        var gate = gate(timeoutSeconds: 5, graceSeconds: 1)
        _ = gate.tick(now: 2 * second, heartbeatReceived: true)
        XCTAssertFalse(gate.tick(now: 6 * second, heartbeatReceived: false))      // age 4s
        XCTAssertFalse(gate.tick(now: 7 * second, heartbeatReceived: false))      // age == 5s: armed
        XCTAssertTrue(gate.tick(now: 7 * second + 1, heartbeatReceived: false))
    }

    func testDefaultConfigValues() {
        let config = WatchdogGateConfig()
        XCTAssertEqual(config.heartbeatTimeoutNanos, 30_000_000_000)
        XCTAssertEqual(config.startupGraceNanos, 10_000_000_000)
        XCTAssertEqual(WatchdogGateConfig.default, config)
    }

    // MARK: - Equatable, deterministic state

    func testStateIsEquatableAndResetRestoresEquality() {
        var a = gate()
        var b = gate()
        _ = a.tick(now: 5 * second, heartbeatReceived: true)
        _ = b.tick(now: 5 * second, heartbeatReceived: true)
        XCTAssertEqual(a, b)
        _ = a.tick(now: 6 * second, heartbeatReceived: true) // diverging state
        XCTAssertNotEqual(a, b)
        a.reset()
        b.reset()
        XCTAssertEqual(a, b)
    }

    func testRestoreDecisionsAreDeterministicAcrossIdenticalGates() {
        var a = gate()
        var b = gate()
        let ticks: [(now: UInt64, heartbeat: Bool)] = [
            (0, false),
            (5 * second, true),
            (34 * second, false),
            (35 * second, false),
            (36 * second, true),
        ]
        for tick in ticks {
            let resultA = a.tick(now: tick.now, heartbeatReceived: tick.heartbeat)
            let resultB = b.tick(now: tick.now, heartbeatReceived: tick.heartbeat)
            XCTAssertEqual(resultA, resultB)
        }
        XCTAssertEqual(a, b)
    }

    func testGateIsSendable() {
        requireSendable(WatchdogGateConfig())
        requireSendable(WatchdogGate())
    }
}

private func requireSendable<T: Sendable>(_: T) {}
