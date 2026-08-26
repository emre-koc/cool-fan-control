import Foundation

/// Anti-hunt configuration. `bandFraction` is the falling band expressed as a
/// fraction of the current target (default 5 %).
public struct HysteresisConfig: Equatable, Sendable, Codable {
    public var bandFraction: Double

    public static let `default` = HysteresisConfig()

    public init(bandFraction: Double = 0.05) {
        precondition(
            bandFraction.isFinite && (0...1).contains(bandFraction),
            "bandFraction must be finite and in 0...1"
        )
        self.bandFraction = bandFraction
    }

    /// Decode applies the same validation as `init` (codebase convention:
    /// persisted configuration is never trusted). Invalid persisted values
    /// throw a `DecodingError` rather than trapping.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(Double.self, forKey: .bandFraction)
        guard value.isFinite, (0...1).contains(value) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "bandFraction must be finite and in 0...1"
                )
            )
        }
        self.bandFraction = value
    }

    private enum CodingKeys: String, CodingKey {
        case bandFraction
    }
}

/// Deterministic anti-hunt state machine over desired RPM targets:
///
/// - The first tick initializes `currentTarget` to the desired value.
/// - Rising: `desired > currentTarget` → follow immediately (no band on the
///   way up — heat must be answered without delay).
/// - Falling: step down only when `desired < currentTarget - band`, where
///   `band = currentTarget * bandFraction`. Exact boundary semantics: at
///   `desired == currentTarget - band` there is **no** change (strictly
///   below). This is what prevents hunting around a steady state.
/// - Missing / non-finite desired → keep the last target (no change).
///
/// Pure and deterministic: no randomness, no wall clock. The curve lookup
/// happens upstream (the engine feeds `desired`), keeping this a minimal
/// value-type state machine.
public struct HysteresisController: Equatable, Sendable {
    public private(set) var currentTarget: Double?
    public let config: HysteresisConfig

    public init(config: HysteresisConfig = .default) {
        self.config = config
    }

    /// Advances the state machine. `desired` is the curve's RPM for the
    /// current temperature (nil when the temperature is missing/non-finite).
    /// Returns the target after the tick.
    @discardableResult
    public mutating func tick(desired: Double?) -> Double? {
        guard let desired, desired.isFinite else {
            return currentTarget // missing input means no change
        }
        guard let current = currentTarget else {
            currentTarget = desired // first tick initializes
            return currentTarget
        }
        let band = current * config.bandFraction
        if desired > current {
            currentTarget = desired
        } else if desired < current - band {
            currentTarget = desired
        }
        return currentTarget
    }

    public mutating func reset() {
        currentTarget = nil
    }
}
