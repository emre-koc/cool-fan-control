public enum FanControlMode: Equatable, Sendable {
    case automatic
    case manual
    case unknown(UInt8)

    public init(rawByte: UInt8) {
        switch rawByte {
        case 0: self = .automatic
        case 1: self = .manual
        default: self = .unknown(rawByte)
        }
    }

    public var rawByte: UInt8 {
        switch self {
        case .automatic: 0
        case .manual: 1
        case .unknown(let byte): byte
        }
    }
}

public struct FanInfo: Equatable, Sendable {
    public let index: UInt8
    public let minimumRPM: Double
    public let maximumRPM: Double
    public let currentRPM: Double
    public let mode: FanControlMode
    public let targetRPM: Double

    public init(
        index: UInt8,
        minimumRPM: Double,
        maximumRPM: Double,
        currentRPM: Double,
        mode: FanControlMode,
        targetRPM: Double
    ) {
        self.index = index
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
        self.currentRPM = currentRPM
        self.mode = mode
        self.targetRPM = targetRPM
    }
}

public struct FanSnapshot: Equatable, Sendable {
    public let fans: [FanInfo]

    public init(fans: [FanInfo]) {
        self.fans = fans
    }
}

public enum FanDiscoveryError: Error, Equatable, Sendable {
    case invalidFanCountMetadata(actualType: String, actualSize: UInt32)
    case unsupportedFanCount(UInt8)
    case invalidRPMMetadata(
        index: UInt8,
        key: SMCFourCC,
        actualType: String,
        actualSize: UInt32
    )
    case rpmDecodeFailed(index: UInt8, key: SMCFourCC, cause: SMCCodecError)
    case negativeRPM(index: UInt8, key: SMCFourCC, value: Double)
    case invalidRPMRange(index: UInt8, minimum: Double, maximum: Double)
    case invalidModeMetadata(
        index: UInt8,
        key: SMCFourCC,
        actualType: String,
        actualSize: UInt32
    )
}

/// Adds the exact failed key and optional fan index without erasing the transport error.
public struct FanDiscoveryReadError: Error, Sendable {
    public let index: UInt8?
    public let key: SMCFourCC
    public let underlyingError: any Error

    public init(index: UInt8?, key: SMCFourCC, underlyingError: any Error) {
        self.index = index
        self.key = key
        self.underlyingError = underlyingError
    }
}

public protocol FanDiscovering: Sendable {
    func snapshot() async throws -> FanSnapshot
}

/// Read-only, all-or-error discovery of the decimal AppleSMC fan-key namespace.
public struct FanDiscovery: FanDiscovering, Sendable {
    /// Decimal fan keys have one index character (`F0*` through `F9*`).
    public static let maximumRepresentableFanCount: UInt8 = 10

    private let reader: any SMCReading

    public init(reader: any SMCReading) {
        self.reader = reader
    }

    public func snapshot() async throws -> FanSnapshot {
        let countKey = try SMCFourCC("FNum")
        let countValue = try await read(countKey, index: nil)
        guard countValue.dataType.stringValue == SMCDataType.ui8.rawValue,
              countValue.dataSize == 1 else {
            throw FanDiscoveryError.invalidFanCountMetadata(
                actualType: countValue.dataType.stringValue,
                actualSize: countValue.dataSize
            )
        }

        // Exact ui8 metadata and SMCValue's byte-count invariant make this an
        // integer in 0...255 without floating-point conversion.
        let count = countValue.bytes[0]
        guard count <= Self.maximumRepresentableFanCount else {
            throw FanDiscoveryError.unsupportedFanCount(count)
        }

        var fans: [FanInfo] = []
        fans.reserveCapacity(Int(count))
        for index in UInt8(0)..<count {
            let actualKey = try fanKey(index: index, suffix: "Ac")
            let minimumKey = try fanKey(index: index, suffix: "Mn")
            let maximumKey = try fanKey(index: index, suffix: "Mx")
            let modeKey = try fanKey(index: index, suffix: "Md")
            let targetKey = try fanKey(index: index, suffix: "Tg")

            let current = try await rpm(actualKey, index: index)
            let minimum = try await rpm(minimumKey, index: index)
            let maximum = try await rpm(maximumKey, index: index)
            let mode = try await mode(modeKey, index: index)
            let target = try await rpm(targetKey, index: index)

            guard minimum <= maximum else {
                throw FanDiscoveryError.invalidRPMRange(
                    index: index,
                    minimum: minimum,
                    maximum: maximum
                )
            }
            fans.append(FanInfo(
                index: index,
                minimumRPM: minimum,
                maximumRPM: maximum,
                currentRPM: current,
                mode: mode,
                targetRPM: target
            ))
        }
        return FanSnapshot(fans: fans)
    }

    private func fanKey(index: UInt8, suffix: String) throws -> SMCFourCC {
        // The count guard guarantees a single decimal index before FourCC construction.
        try SMCFourCC("F\(index)\(suffix)")
    }

    private func read(_ key: SMCFourCC, index: UInt8?) async throws -> SMCValue {
        do {
            return try await reader.read(key)
        } catch {
            throw FanDiscoveryReadError(index: index, key: key, underlyingError: error)
        }
    }

    private func rpm(_ key: SMCFourCC, index: UInt8) async throws -> Double {
        let value = try await read(key, index: index)
        let type = value.dataType.stringValue
        let validMetadata = (type == SMCDataType.float.rawValue && value.dataSize == 4)
            || (type == SMCDataType.fpe2.rawValue && value.dataSize == 2)
        guard validMetadata else {
            throw FanDiscoveryError.invalidRPMMetadata(
                index: index,
                key: key,
                actualType: type,
                actualSize: value.dataSize
            )
        }

        let decoded: Double
        do {
            decoded = try value.numericValue()
        } catch let error as SMCCodecError {
            throw FanDiscoveryError.rpmDecodeFailed(index: index, key: key, cause: error)
        }
        guard decoded >= 0 else {
            throw FanDiscoveryError.negativeRPM(index: index, key: key, value: decoded)
        }
        return decoded
    }

    private func mode(_ key: SMCFourCC, index: UInt8) async throws -> FanControlMode {
        let value = try await read(key, index: index)
        guard value.dataType.stringValue == SMCDataType.ui8.rawValue,
              value.dataSize == 1 else {
            throw FanDiscoveryError.invalidModeMetadata(
                index: index,
                key: key,
                actualType: value.dataType.stringValue,
                actualSize: value.dataSize
            )
        }
        return FanControlMode(rawByte: value.bytes[0])
    }
}
