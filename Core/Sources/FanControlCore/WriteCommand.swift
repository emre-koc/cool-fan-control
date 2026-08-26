import Foundation

/// The control mode a `FanWriteCommand` requests. `automatic` hands control
/// back to Apple's firmware (write `F0Md = 0`); `manual` sets a target RPM
/// (write `F0Md = 1` then `F0Tg`).
public enum FanWriteMode: String, Equatable, Sendable, Codable {
    case automatic
    case manual
}

/// Typed construction failure for a `FanWriteCommand`. Bounds are supplied at
/// construction time and validated only for manual commands; `automatic`
/// commands carry no RPM at all.
public enum FanWriteCommandError: Error, Equatable, Sendable {
    case automaticWithTarget(targetRPM: Double)
    case manualMissingTarget
    case nonFiniteTargetRPM(Double)
    case targetOutOfBounds(minimumRPM: Double, maximumRPM: Double, targetRPM: Double)
}

/// One validated write command for one fan.
///
/// - `automatic` → `targetRPM` must be nil.
/// - `manual` → `targetRPM` must be present, finite, and inside
///   `[minimumRPM, maximumRPM]` supplied at construction.
///
/// The wire format is `{fanIndex, mode, targetRPM}` — the fan's bounds are
/// construction-time context, not transport payload. Decoding validates the
/// structural invariant (automatic ⇒ nil target; manual ⇒ finite target); the
/// future helper re-clamps as defense-in-depth (plan Task 5.3).
public struct FanWriteCommand: Equatable, Sendable, Codable {
    public let fanIndex: Int
    public let mode: FanWriteMode
    public let targetRPM: Double?

    public init(
        fanIndex: Int,
        mode: FanWriteMode,
        targetRPM: Double?,
        minimumRPM: Double,
        maximumRPM: Double
    ) throws {
        switch mode {
        case .automatic:
            if let targetRPM {
                throw FanWriteCommandError.automaticWithTarget(targetRPM: targetRPM)
            }
        case .manual:
            guard let targetRPM else {
                throw FanWriteCommandError.manualMissingTarget
            }
            guard targetRPM.isFinite else {
                throw FanWriteCommandError.nonFiniteTargetRPM(targetRPM)
            }
            guard targetRPM >= minimumRPM, targetRPM <= maximumRPM else {
                throw FanWriteCommandError.targetOutOfBounds(
                    minimumRPM: minimumRPM,
                    maximumRPM: maximumRPM,
                    targetRPM: targetRPM
                )
            }
        }
        self.fanIndex = fanIndex
        self.mode = mode
        self.targetRPM = targetRPM
    }

    private enum CodingKeys: String, CodingKey {
        case fanIndex
        case mode
        case targetRPM
    }

    /// Decodes `{fanIndex, mode, targetRPM}` and validates the structural
    /// invariant. Bounds are not on the wire, so they are not re-checked here
    /// (the helper clamps again on apply).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fanIndex = try container.decode(Int.self, forKey: .fanIndex)
        let mode = try container.decode(FanWriteMode.self, forKey: .mode)
        let targetRPM = try container.decodeIfPresent(Double.self, forKey: .targetRPM)
        switch mode {
        case .automatic:
            guard targetRPM == nil else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "automatic command must not carry a targetRPM"
                    )
                )
            }
        case .manual:
            guard let targetRPM, targetRPM.isFinite else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "manual command requires a finite targetRPM"
                    )
                )
            }
        }
        self.fanIndex = fanIndex
        self.mode = mode
        self.targetRPM = targetRPM
    }
}
