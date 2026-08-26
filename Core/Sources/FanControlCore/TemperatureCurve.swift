import Foundation

/// One (temperature °C → RPM) anchor of a piecewise-linear curve.
public struct CurvePoint: Equatable, Sendable, Codable {
    public var temperatureC: Double
    public var rpm: Double

    public init(temperatureC: Double, rpm: Double) {
        self.temperatureC = temperatureC
        self.rpm = rpm
    }
}

/// Typed validation failure for persisted user curve data.
public enum TemperatureCurveError: Error, Equatable, Sendable {
    case emptyPoints
    case nonFiniteTemperature(index: Int, celsius: Double)
    case nonFiniteRPM(index: Int, rpm: Double)
    case nonIncreasingTemperatures(previousIndex: Int, previous: Double, current: Double)
}

/// Piecewise-linear temperature → RPM curve, clamped to `[minimumRPM,
/// maximumRPM]`.
///
/// Points must be non-empty with strictly-increasing, finite temperatures and
/// finite RPMs — invalid *point data* is a typed error (points are persisted
/// user configuration). Bounds are code invariants (finite, non-negative,
/// `minimumRPM <= maximumRPM`) and use preconditions, matching the other
/// engine configs. Decoding applies the same validation as `init`.
public struct TemperatureCurve: Equatable, Sendable, Codable {
    public let points: [CurvePoint]
    public let minimumRPM: Double
    public let maximumRPM: Double

    private enum CodingKeys: String, CodingKey {
        case points
        case minimumRPM
        case maximumRPM
    }

    public init(points: [CurvePoint], minimumRPM: Double, maximumRPM: Double) throws {
        precondition(
            minimumRPM.isFinite && maximumRPM.isFinite && minimumRPM >= 0 && minimumRPM <= maximumRPM,
            "fan bounds must be finite, non-negative, and satisfy minimumRPM <= maximumRPM"
        )
        guard !points.isEmpty else { throw TemperatureCurveError.emptyPoints }
        for (index, point) in points.enumerated() {
            guard point.temperatureC.isFinite else {
                throw TemperatureCurveError.nonFiniteTemperature(index: index, celsius: point.temperatureC)
            }
            guard point.rpm.isFinite else {
                throw TemperatureCurveError.nonFiniteRPM(index: index, rpm: point.rpm)
            }
            if index > 0 {
                let previous = points[index - 1].temperatureC
                guard point.temperatureC > previous else {
                    throw TemperatureCurveError.nonIncreasingTemperatures(
                        previousIndex: index - 1,
                        previous: previous,
                        current: point.temperatureC
                    )
                }
            }
        }
        self.points = points
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let points = try container.decode([CurvePoint].self, forKey: .points)
        let minimumRPM = try container.decode(Double.self, forKey: .minimumRPM)
        let maximumRPM = try container.decode(Double.self, forKey: .maximumRPM)
        try self.init(points: points, minimumRPM: minimumRPM, maximumRPM: maximumRPM)
    }

    /// The spec default: 40 °C → fan min, 85 °C → fan max.
    public static func `default`(minimumRPM: Double, maximumRPM: Double) throws -> TemperatureCurve {
        try TemperatureCurve(
            points: [
                CurvePoint(temperatureC: 40, rpm: minimumRPM),
                CurvePoint(temperatureC: 85, rpm: maximumRPM),
            ],
            minimumRPM: minimumRPM,
            maximumRPM: maximumRPM
        )
    }

    /// Piecewise-linear RPM at `temperatureC`, clamped to the stored bounds.
    /// Below the first point / above the last point clamp to the endpoint RPM.
    /// `temperatureC` must be finite — missing/non-finite temperature handling
    /// (keep-last) lives in `HysteresisController` and `FanControlEngine`.
    public func rpm(at temperatureC: Double) -> Double {
        rpm(at: temperatureC, clampedToMinimum: minimumRPM, clampedToMaximum: maximumRPM)
    }

    /// `rpm(at:)` with caller-provided bounds overriding the stored ones —
    /// lets the engine clamp one shared curve to each fan's range.
    public func rpm(at temperatureC: Double, clampedToMinimum: Double, clampedToMaximum: Double) -> Double {
        precondition(
            temperatureC.isFinite,
            "temperature must be finite; missing/non-finite handling belongs to the caller"
        )
        precondition(
            clampedToMinimum.isFinite && clampedToMaximum.isFinite && clampedToMinimum <= clampedToMaximum,
            "clamp bounds must be finite with minimum <= maximum"
        )
        func clamped(_ rpm: Double) -> Double {
            min(max(rpm, clampedToMinimum), clampedToMaximum)
        }
        let first = points[0]
        let last = points[points.count - 1]
        if temperatureC <= first.temperatureC { return clamped(first.rpm) }
        if temperatureC >= last.temperatureC { return clamped(last.rpm) }
        for index in 0..<(points.count - 1) {
            let lower = points[index]
            let upper = points[index + 1]
            if temperatureC >= lower.temperatureC && temperatureC <= upper.temperatureC {
                let fraction = (temperatureC - lower.temperatureC) / (upper.temperatureC - lower.temperatureC)
                return clamped(lower.rpm + (upper.rpm - lower.rpm) * fraction)
            }
        }
        return clamped(last.rpm) // unreachable: the loop covers the full range
    }
}
