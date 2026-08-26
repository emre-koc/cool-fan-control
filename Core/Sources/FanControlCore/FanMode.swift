import Foundation

/// User-selectable fan control mode. `auto` hands control back to Apple's
/// firmware (no write); every other mode produces a concrete RPM target that
/// is composed with safety overrides by `FanControlEngine`.
///
/// Persisted as stable JSON: `{"mode":"manual","rpm":1200}` — the `mode`
/// string is versioned, so adding modes later never renumbers anything.
public enum FanMode: Equatable, Sendable, Codable {
    case auto
    case smart
    case manual(rpm: Int)
    case quiet
    case max

    private enum CodingKeys: String, CodingKey {
        case mode
        case rpm
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try container.decode(String.self, forKey: .mode)
        switch mode {
        case "auto":
            self = .auto
        case "smart":
            self = .smart
        case "manual":
            let rpm = try container.decode(Int.self, forKey: .rpm)
            self = .manual(rpm: rpm)
        case "quiet":
            self = .quiet
        case "max":
            self = .max
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .mode,
                in: container,
                debugDescription: "unknown FanMode: \(mode)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .auto:
            try container.encode("auto", forKey: .mode)
        case .smart:
            try container.encode("smart", forKey: .mode)
        case .manual(let rpm):
            try container.encode("manual", forKey: .mode)
            try container.encode(rpm, forKey: .rpm)
        case .quiet:
            try container.encode("quiet", forKey: .mode)
        case .max:
            try container.encode("max", forKey: .mode)
        }
    }

    /// The direct fixed-RPM target for this mode, ignoring the smart curve:
    /// `quiet` → fan min, `max` → fan max, `manual` → its RPM (left raw;
    /// composition clamps it to the fan's `[min, max]`). `auto`/`smart` → nil.
    public func fixedTarget(minimumRPM: Double, maximumRPM: Double) -> Double? {
        switch self {
        case .auto, .smart:
            return nil
        case .manual(let rpm):
            return Double(rpm)
        case .quiet:
            return minimumRPM
        case .max:
            return maximumRPM
        }
    }
}
