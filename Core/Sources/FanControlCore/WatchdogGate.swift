/// Configuration for the helper's heartbeat watchdog gate.
///
/// Defaults match the product contract (plan Task 5.5): the helper restores
/// Apple automatic control after ~30 s of app silence, and the 10 s startup
/// grace covers the first helper↔app connection after the helper launches
/// (the helper always begins in automatic mode).
public struct WatchdogGateConfig: Equatable, Sendable {
    /// Silence after the last heartbeat that triggers an automatic restore.
    public var heartbeatTimeoutNanos: UInt64
    /// Silence after gate creation (no heartbeat ever received) that
    /// triggers an automatic restore.
    public var startupGraceNanos: UInt64

    public init(
        heartbeatTimeoutNanos: UInt64 = 30_000_000_000,
        startupGraceNanos: UInt64 = 10_000_000_000
    ) {
        self.heartbeatTimeoutNanos = heartbeatTimeoutNanos
        self.startupGraceNanos = startupGraceNanos
    }

    public static let `default` = WatchdogGateConfig()
}

/// Pure, deterministic heartbeat gate: `tick` answers "must automatic restore
/// run right now?" given an injected monotonic clock in nanoseconds.
///
/// Boundary policy (uniform, pinned by `WatchdogGateTests`): restore only
/// when the silent interval STRICTLY exceeds the configured limit. At exact
/// equality the gate is still armed — `age == timeout` and `now == grace`
/// both return false. This single rule makes every boundary deterministic.
///
/// Fail-safe semantics:
/// - Before the first heartbeat, restore once `now` strictly exceeds the
///   startup grace (the helper begins in automatic, so an early restore is
///   a no-op; grace covers the first connection).
/// - After a heartbeat, restore when `now - lastHeartbeat` strictly exceeds
///   the heartbeat timeout. A heartbeat resets the timer.
/// - A regressed monotonic clock (`now < lastHeartbeat`) with no heartbeat
///   restores immediately — the age is untrustworthy, so fail safe.
/// - A claimed heartbeat always resets the timer, even under a regressed
///   clock: a live ping is the strongest evidence the app is alive. If the
///   app then dies, pings stop and the timeout restores.
public struct WatchdogGate: Equatable, Sendable {
    public let config: WatchdogGateConfig
    /// Nanoseconds of the most recent heartbeat; nil before the first one.
    public private(set) var lastHeartbeatNanos: UInt64?

    public init(config: WatchdogGateConfig = .default) {
        self.config = config
        lastHeartbeatNanos = nil
    }

    /// Returns true when automatic restore must run now.
    public mutating func tick(now: UInt64, heartbeatReceived: Bool) -> Bool {
        if heartbeatReceived {
            lastHeartbeatNanos = now
            return false
        }
        guard let lastHeartbeatNanos else {
            return now > config.startupGraceNanos
        }
        guard now >= lastHeartbeatNanos else {
            return true
        }
        return now - lastHeartbeatNanos > config.heartbeatTimeoutNanos
    }

    /// Clears heartbeat state; the gate behaves as freshly created (startup
    /// grace applies again).
    public mutating func reset() {
        lastHeartbeatNanos = nil
    }
}
