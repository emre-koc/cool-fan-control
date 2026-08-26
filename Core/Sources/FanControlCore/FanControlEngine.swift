import Foundation

/// One fan's fixed RPM bounds, as discovered from `F0Mn`/`F0Mx`.
public struct FanBounds: Equatable, Sendable, Codable {
    public var minimumRPM: Double
    public var maximumRPM: Double

    public init(minimumRPM: Double, maximumRPM: Double) {
        precondition(
            minimumRPM.isFinite && maximumRPM.isFinite && minimumRPM >= 0 && minimumRPM <= maximumRPM,
            "fan bounds must be finite, non-negative, and satisfy minimumRPM <= maximumRPM"
        )
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
    }

    /// Decode applies the same validation as `init`. Invalid persisted
    /// values throw a `DecodingError` rather than trapping.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let minimumRPM = try container.decode(Double.self, forKey: .minimumRPM)
        let maximumRPM = try container.decode(Double.self, forKey: .maximumRPM)
        guard minimumRPM.isFinite, maximumRPM.isFinite,
              minimumRPM >= 0, minimumRPM <= maximumRPM else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "fan bounds must be finite, non-negative, and satisfy minimumRPM <= maximumRPM"
                )
            )
        }
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
    }

    private enum CodingKeys: String, CodingKey {
        case minimumRPM
        case maximumRPM
    }
}

/// One fan's effective target for a tick. `effectiveRPM == nil` means Apple
/// automatic control (no write).
public struct FanTarget: Equatable, Sendable {
    public let fanIndex: Int
    public let effectiveRPM: Double?

    public init(fanIndex: Int, effectiveRPM: Double?) {
        self.fanIndex = fanIndex
        self.effectiveRPM = effectiveRPM
    }
}

/// Pure orchestrator. Produces one effective target per fan:
///
/// - Mode target: `smart` → the temperature curve through a per-fan
///   `HysteresisController`; `manual(rpm)` → fixed RPM; `quiet` → fan min;
///   `max` → fan max; `auto` → nil (Apple auto, no write).
/// - Composition: `EffectiveTargetRule` takes the max of the mode target, the
///   CPU throttle guard target, and the battery cooling rule target, clamped
///   to the fan's `[min, max]`; all nil → nil (auto, no write).
///
/// The engine advances the `BatteryCoolingRule` and `CpuThrottleGuard` state
/// machines it is given (inout), so every state transition happens in one
/// deterministic pass per tick. All inputs are value types — no randomness,
/// no wall clock.
///
/// Missing-data policy: a nil or non-finite `hottestControlCelsius` in smart
/// mode is *not* interpreted as cold — the per-fan hysteresis keeps its last
/// target. Only a target never initialized yields nil (no write → Apple auto,
/// which is the safe default). Safety overrides still apply on top of a held
/// target. (The `CpuThrottleGuard`'s own release-on-missing policy is
/// orthogonal and already defined in OverrideRules.swift.)
public struct FanControlEngine: Equatable, Sendable {
    public struct Config: Equatable, Sendable, Codable {
        /// Falling hysteresis band as a fraction of the current target.
        public var hysteresisBandFraction: Double

        public static let `default` = Config()

        public init(hysteresisBandFraction: Double = 0.05) {
            precondition(
                hysteresisBandFraction.isFinite && (0...1).contains(hysteresisBandFraction),
                "hysteresisBandFraction must be finite and in 0...1"
            )
            self.hysteresisBandFraction = hysteresisBandFraction
        }

        /// Decode applies the same validation as `init`. Invalid persisted
        /// values throw a `DecodingError` rather than trapping.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let value = try container.decode(Double.self, forKey: .hysteresisBandFraction)
            guard value.isFinite, (0...1).contains(value) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "hysteresisBandFraction must be finite and in 0...1"
                    )
                )
            }
            self.hysteresisBandFraction = value
        }

        private enum CodingKeys: String, CodingKey {
            case hysteresisBandFraction
        }
    }

    public let config: Config
    private var hysteresisByFan: [Int: HysteresisController]

    public init(config: Config = .default) {
        self.config = config
        self.hysteresisByFan = [:]
    }

    /// Clears all per-fan hysteresis state. The caller-owned safety rules are
    /// not touched — reset them separately.
    public mutating func reset() {
        hysteresisByFan = [:]
    }

    /// The smart-mode target currently held for a fan (nil when never
    /// initialized in smart mode).
    public func currentTarget(fanIndex: Int) -> Double? {
        hysteresisByFan[fanIndex]?.currentTarget
    }

    /// Advance every state machine once and produce one effective target per
    /// fan, ordered by fan index.
    ///
    /// - `mode`: the user-selected mode (applies to every fan).
    /// - `curve`: the smart temperature curve (points only; each fan's bounds
    ///   are applied as caller-provided clamp bounds).
    /// - `hottestControlCelsius`: trusted hottest control candidate
    ///   (CPU/GPU/SOC). nil or non-finite in smart mode → hysteresis keeps
    ///   its last target.
    /// - `hottestCPUCelsius`: trusted hottest CPU candidate, drives the
    ///   throttle guard.
    /// - `isCharging` / `batteryTemperatureC`: drive the battery cooling rule.
    /// - `fanBounds`: one entry per fan, ordered by fan index.
    /// - `batteryRule` / `cpuGuard`: the shared safety state machines,
    ///   advanced here (inout).
    @discardableResult
    public mutating func tick(
        mode: FanMode,
        curve: TemperatureCurve,
        hottestControlCelsius: Double?,
        hottestCPUCelsius: Double?,
        isCharging: Bool,
        batteryTemperatureC: Double?,
        fanBounds: [FanBounds],
        batteryRule: inout BatteryCoolingRule,
        cpuGuard: inout CpuThrottleGuard
    ) -> [FanTarget] {
        _ = batteryRule.tick(isCharging: isCharging, batteryTempC: batteryTemperatureC)
        _ = cpuGuard.tick(hottestCPUCelsius: hottestCPUCelsius)

        var targets: [FanTarget] = []
        targets.reserveCapacity(fanBounds.count)
        for (index, bounds) in fanBounds.enumerated() {
            let modeTarget = modeTarget(
                mode: mode,
                curve: curve,
                hottestControlCelsius: hottestControlCelsius,
                bounds: bounds,
                fanIndex: index
            )
            let effective = EffectiveTargetRule.effectiveTarget(
                modeTarget: modeTarget,
                cpuGuardTarget: rpmTarget(cpuGuard.decision(fanMaximumRPM: bounds.maximumRPM)),
                batteryTarget: rpmTarget(
                    batteryRule.decision(fanMinimumRPM: bounds.minimumRPM, fanMaximumRPM: bounds.maximumRPM)
                ),
                fanMinimumRPM: bounds.minimumRPM,
                fanMaximumRPM: bounds.maximumRPM
            )
            targets.append(FanTarget(fanIndex: index, effectiveRPM: effective))
        }
        return targets
    }

    private mutating func modeTarget(
        mode: FanMode,
        curve: TemperatureCurve,
        hottestControlCelsius: Double?,
        bounds: FanBounds,
        fanIndex: Int
    ) -> Double? {
        guard case .smart = mode else {
            return mode.fixedTarget(minimumRPM: bounds.minimumRPM, maximumRPM: bounds.maximumRPM)
        }
        var controller = hysteresisByFan[fanIndex]
            ?? HysteresisController(config: HysteresisConfig(bandFraction: config.hysteresisBandFraction))
        let desired: Double?
        if let temperature = hottestControlCelsius, temperature.isFinite {
            desired = curve.rpm(
                at: temperature,
                clampedToMinimum: bounds.minimumRPM,
                clampedToMaximum: bounds.maximumRPM
            )
        } else {
            desired = nil // missing/non-finite → keep last target
        }
        let target = controller.tick(desired: desired)
        hysteresisByFan[fanIndex] = controller
        return target
    }

    private func rpmTarget(_ decision: OverrideDecision) -> Double? {
        switch decision {
        case .inactive:
            return nil
        case .forceRPM(let rpm):
            return rpm
        }
    }
}
