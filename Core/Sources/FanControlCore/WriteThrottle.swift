import Foundation

/// Per-fan write-rate-limit configuration.
///
/// - `minimumIntervalNanos`: minimum spacing between two *sent* commands
///   (default 2 s). Must be positive.
/// - `minimumChangeRPM`: minimum target change that justifies a write
///   (default 100). `0` disables the change gate entirely (every same-mode
///   proposal sends once the interval has elapsed). Must be finite and ≥ 0.
public struct WriteThrottleConfig: Equatable, Sendable, Codable {
    public var minimumIntervalNanos: UInt64
    public var minimumChangeRPM: Double

    public static let `default` = WriteThrottleConfig()

    public init(minimumIntervalNanos: UInt64 = 2_000_000_000, minimumChangeRPM: Double = 100) {
        precondition(minimumIntervalNanos > 0, "minimumIntervalNanos must be positive")
        precondition(
            minimumChangeRPM.isFinite && minimumChangeRPM >= 0,
            "minimumChangeRPM must be finite and non-negative (0 disables the change gate)"
        )
        self.minimumIntervalNanos = minimumIntervalNanos
        self.minimumChangeRPM = minimumChangeRPM
    }

    /// Decode applies the same validation as `init`; invalid persisted values
    /// throw a `DecodingError` rather than trapping.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let interval = try container.decode(UInt64.self, forKey: .minimumIntervalNanos)
        let change = try container.decode(Double.self, forKey: .minimumChangeRPM)
        guard interval > 0, change.isFinite, change >= 0 else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "minimumIntervalNanos must be positive; minimumChangeRPM must be finite and >= 0"
                )
            )
        }
        self.minimumIntervalNanos = interval
        self.minimumChangeRPM = change
    }

    private enum CodingKeys: String, CodingKey {
        case minimumIntervalNanos
        case minimumChangeRPM
    }
}

/// What one throttle tick decided. `.send(nil)` is an automatic-restore
/// command (the command itself carries no RPM); `.send(command)` is a manual
/// write; `.skip` means no write this tick.
public enum WriteThrottleDecision: Equatable, Sendable {
    case send(FanWriteCommand?)
    case skip
}

/// Pure, deterministic, stateful write-rate limiter for ONE fan.
///
/// Exact semantics (policy documented in the milestone verification doc):
///
/// 1. **Clock anomaly** — `now < lastSentAtNanos` means the monotonic clock
///    went backwards; treated as an anomaly → `.skip` (never write on a
///    regression), including for restores.
/// 2. **First command** of any kind → `.send` immediately (no interval or
///    change gate — the first write must never be suppressed).
/// 3. **Automatic proposals** (`proposed == nil`):
///    - nothing ever sent → `.send(nil)` (establish Apple auto);
///    - last *sent* command was manual → `.send(nil)` immediately — a restore
///      is safety-critical and is never rate-limited;
///    - last sent command was automatic → `.skip` (auto-only-once policy:
///      repeated automatic commands are sent only once until something
///      changes).
/// 4. **Manual proposals** — after the first command the interval gate
///    applies (`now - lastSentAt >= minimumIntervalNanos`):
///    - mode changed (last sent was automatic): change gate against the
///      caller-supplied `previousRPM` (the *actual* RPM — the best reference
///      after Apple takes over). `|Δ| >= minimumChangeRPM` sends, else `.skip`
///      (a trivial switch is not worth yanking control from Apple for).
///      A nil/non-finite `previousRPM` cannot prove redundancy → send.
///    - same mode (manual → manual): change gate against the last written
///      target; `|Δ| >= minimumChangeRPM` sends (equality at the boundary
///      SENDS), else `.skip`. Equal target and mode → always `.skip`.
/// 5. `minimumChangeRPM == 0` disables the change gate (equal targets send
///    once the interval has elapsed — the caller opted out of the gate).
/// 6. Skips do not advance `lastSentAtNanos` — the interval is measured from
///    the last *send*.
public struct WriteThrottle: Equatable, Sendable {
    public let config: WriteThrottleConfig
    public private(set) var lastSentAtNanos: UInt64?
    /// Mode of the last *sent* command; nil when nothing was ever sent.
    public private(set) var lastSentMode: FanWriteMode?
    /// Target of the last *sent* manual command; nil when the last send was an
    /// automatic restore (or nothing was ever sent).
    public private(set) var lastSentTargetRPM: Double?

    public init(config: WriteThrottleConfig = .default) {
        self.config = config
        self.lastSentAtNanos = nil
        self.lastSentMode = nil
        self.lastSentTargetRPM = nil
    }

    @discardableResult
    public mutating func tick(
        now: UInt64,
        proposed: FanWriteCommand?,
        previousRPM: Double?
    ) -> WriteThrottleDecision {
        // Clock anomaly: a tick earlier than the last send means the monotonic
        // clock went backwards. Never write on a regression.
        if let lastSentAtNanos, now < lastSentAtNanos {
            return .skip
        }

        // Automatic proposal (restore to Apple control).
        guard let proposed else {
            switch lastSentMode {
            case nil:
                return send(nil, at: now)
            case .manual:
                return send(nil, at: now) // restore is safety-critical: never rate-limited
            case .automatic:
                return .skip // already automatic: redundant
            }
        }

        // Manual proposal.
        guard let target = proposed.targetRPM else {
            // Validated manual commands always carry a target; a structurally
            // impossible command still degrades to a send rather than a trap.
            return send(proposed, at: now)
        }
        switch lastSentMode {
        case nil:
            return send(proposed, at: now)

        case .manual:
            if let lastSentAtNanos, now - lastSentAtNanos < config.minimumIntervalNanos {
                return .skip
            }
            // Change gate against the last written target (fall back to the
            // actual RPM only if we never recorded a written target).
            let reference = lastSentTargetRPM ?? previousRPM
            guard let reference, reference.isFinite else {
                return send(proposed, at: now)
            }
            if abs(target - reference) >= config.minimumChangeRPM {
                return send(proposed, at: now)
            }
            return .skip

        case .automatic:
            if let lastSentAtNanos, now - lastSentAtNanos < config.minimumIntervalNanos {
                return .skip
            }
            // Mode change auto → manual: judge against the actual RPM. After a
            // restore Apple may have moved the fan; only take control back when
            // the request differs meaningfully from reality.
            guard let previousRPM, previousRPM.isFinite else {
                return send(proposed, at: now)
            }
            if abs(target - previousRPM) >= config.minimumChangeRPM {
                return send(proposed, at: now)
            }
            return .skip
        }
    }

    public mutating func reset() {
        lastSentAtNanos = nil
        lastSentMode = nil
        lastSentTargetRPM = nil
    }

    private mutating func send(_ command: FanWriteCommand?, at now: UInt64) -> WriteThrottleDecision {
        lastSentAtNanos = now
        if let command {
            lastSentMode = command.mode
            lastSentTargetRPM = command.targetRPM
        } else {
            lastSentMode = .automatic
            lastSentTargetRPM = nil
        }
        return .send(command)
    }
}
