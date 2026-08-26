import Foundation

// MARK: - Decision

/// What one safety rule wants applied. `.forceRPM` is clamped by
/// `EffectiveTargetRule` to the fan's `[min, max]` before any write.
public enum OverrideDecision: Equatable, Sendable {
    case inactive
    case forceRPM(Double)
}

// MARK: - Battery cooling rule (two-tier, while charging only)

/// Thresholds and targets for the battery cooling rule. Defaults per spec:
/// mid engages > 33 °C, high engages > 35 °C, mid releases < 31 °C, high
/// releases < 33 °C. `midRPM`/`highRPM` default to the fan-range midpoint
/// (floored) and the fan maximum respectively.
public struct BatteryCoolingConfig: Equatable, Sendable, Codable {
    public var midEngageC: Double
    public var highEngageC: Double
    public var midReleaseC: Double
    public var highReleaseC: Double
    public var midRPM: Double?
    public var highRPM: Double?

    public static let `default` = BatteryCoolingConfig()

    public init(
        midEngageC: Double = 33,
        highEngageC: Double = 35,
        midReleaseC: Double = 31,
        highReleaseC: Double = 33,
        midRPM: Double? = nil,
        highRPM: Double? = nil
    ) {
        precondition(midReleaseC <= midEngageC, "midReleaseC must not exceed midEngageC")
        precondition(highReleaseC <= highEngageC, "highReleaseC must not exceed highEngageC")
        precondition(midEngageC <= highEngageC, "midEngageC must not exceed highEngageC")
        precondition(midReleaseC <= highReleaseC, "midReleaseC must not exceed highReleaseC")
        self.midEngageC = midEngageC
        self.highEngageC = highEngageC
        self.midReleaseC = midReleaseC
        self.highReleaseC = highReleaseC
        self.midRPM = midRPM
        self.highRPM = highRPM
    }
}

public enum BatteryCoolingTier: Equatable, Sendable {
    case off
    case mid
    case high
}

/// Stateful, hysteretic two-tier cooling rule. Engages only while charging;
/// missing/non-finite temperature or a charger unplug resets to `.off`.
/// Missing data is never interpreted as hot.
public struct BatteryCoolingRule: Equatable, Sendable {
    public private(set) var tier: BatteryCoolingTier = .off
    public let config: BatteryCoolingConfig

    public init(config: BatteryCoolingConfig = .default) {
        self.config = config
    }

    /// Advances the state machine. Returns the resulting tier.
    ///
    /// - Rising: `> midEngageC` → mid; `> highEngageC` → high (from any lower state).
    /// - Falling: high releases `< highReleaseC` → mid; mid releases `< midReleaseC` → off.
    /// - Not charging, missing, or non-finite temperature → off (reset).
    @discardableResult
    public mutating func tick(isCharging: Bool, batteryTempC: Double?) -> BatteryCoolingTier {
        guard isCharging else {
            tier = .off
            return .off
        }
        guard let temperature = batteryTempC, temperature.isFinite else {
            tier = .off
            return .off
        }

        switch tier {
        case .off:
            if temperature > config.highEngageC {
                tier = .high
            } else if temperature > config.midEngageC {
                tier = .mid
            }
        case .mid:
            if temperature > config.highEngageC {
                tier = .high
            } else if temperature < config.midReleaseC {
                tier = .off
            }
        case .high:
            if temperature < config.highReleaseC {
                tier = .mid
            }
        }
        return tier
    }

    public mutating func reset() {
        tier = .off
    }

    /// RPM decision for one fan. Policy-exact midpoint: `min + (max - min) / 2`,
    /// floored — computed from the fan's *provided* min/max on every call.
    public func decision(fanMinimumRPM: Double, fanMaximumRPM: Double) -> OverrideDecision {
        precondition(fanMinimumRPM <= fanMaximumRPM, "fanMinimumRPM must not exceed fanMaximumRPM")
        switch tier {
        case .off:
            return .inactive
        case .mid:
            return .forceRPM(config.midRPM ?? Self.midPointRPM(minimum: fanMinimumRPM, maximum: fanMaximumRPM))
        case .high:
            return .forceRPM(config.highRPM ?? fanMaximumRPM)
        }
    }

    public static func midPointRPM(minimum: Double, maximum: Double) -> Double {
        precondition(minimum <= maximum, "minimum must not exceed maximum")
        return (minimum + (maximum - minimum) / 2).rounded(.down)
    }
}

// MARK: - CPU throttle guard

public struct CpuThrottleGuardConfig: Equatable, Sendable, Codable {
    public var engageC: Double
    public var releaseC: Double

    public static let `default` = CpuThrottleGuardConfig()

    public init(engageC: Double = 90, releaseC: Double = 88) {
        precondition(releaseC <= engageC, "releaseC must not exceed engageC")
        self.engageC = engageC
        self.releaseC = releaseC
    }
}

/// Stateful CPU throttle guard: engages at `>= engageC` (90 °C default),
/// releases only below `releaseC` (88 °C default). Missing or non-finite
/// input releases — missing data is never interpreted as hot (nor as cold
/// enough to stay engaged on stale data).
public struct CpuThrottleGuard: Equatable, Sendable {
    public private(set) var engaged = false
    public let config: CpuThrottleGuardConfig

    public init(config: CpuThrottleGuardConfig = .default) {
        self.config = config
    }

    /// Advances the state machine with the trusted snapshot's hottest CPU
    /// temperature. Returns whether the guard is engaged.
    @discardableResult
    public mutating func tick(hottestCPUCelsius: Double?) -> Bool {
        guard let temperature = hottestCPUCelsius, temperature.isFinite else {
            engaged = false
            return false
        }
        if engaged {
            if temperature < config.releaseC {
                engaged = false
            }
        } else if temperature >= config.engageC {
            engaged = true
        }
        return engaged
    }

    public mutating func reset() {
        engaged = false
    }

    /// Fan-max decision for one fan while engaged.
    public func decision(fanMaximumRPM: Double) -> OverrideDecision {
        engaged ? .forceRPM(fanMaximumRPM) : .inactive
    }
}

// MARK: - Effective target composition

/// `effective = max(mode, cpuGuard, battery)` clamped to the fan's
/// `[min, max]`; nil when every target is nil (auto mode, no write).
public enum EffectiveTargetRule: Sendable {
    public static func effectiveTarget(
        modeTarget: Double?,
        cpuGuardTarget: Double?,
        batteryTarget: Double?,
        fanMinimumRPM: Double,
        fanMaximumRPM: Double
    ) -> Double? {
        precondition(fanMinimumRPM <= fanMaximumRPM, "fanMinimumRPM must not exceed fanMaximumRPM")
        var candidates: [Double] = []
        if let modeTarget, modeTarget.isFinite { candidates.append(modeTarget) }
        if let cpuGuardTarget, cpuGuardTarget.isFinite { candidates.append(cpuGuardTarget) }
        if let batteryTarget, batteryTarget.isFinite { candidates.append(batteryTarget) }
        guard let combined = candidates.max() else { return nil }
        return min(max(combined, fanMinimumRPM), fanMaximumRPM)
    }
}
