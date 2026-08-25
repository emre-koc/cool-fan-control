public enum SMCDataType: String, CaseIterable, Equatable, Sendable {
    case float = "flt "
    case fpe2 = "fpe2"
    case sp78 = "sp78"
    case ui8 = "ui8 "
    case ui16 = "ui16"
    case ui32 = "ui32"

    public var encodedSize: Int {
        switch self {
        case .ui8:
            1
        case .fpe2, .sp78, .ui16:
            2
        case .float, .ui32:
            4
        }
    }

    public init(reportedFourCC: String) throws {
        let bytes = Array(reportedFourCC.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ $0 < 0x80 }) else {
            throw SMCCodecError.invalidDataTypeFourCC(reportedFourCC)
        }
        guard let dataType = Self(rawValue: reportedFourCC) else {
            throw SMCCodecError.unsupportedDataType(reportedFourCC)
        }
        self = dataType
    }
}

public enum SMCCodecError: Error, Equatable, Sendable {
    case invalidDataTypeFourCC(String)
    case unsupportedDataType(String)
    case wrongSize(dataType: String, expected: Int, actual: Int)
    case nonFiniteFloat
    case invalidEncodeValue(dataType: String, value: Double)
    case valueOutOfRange(
        dataType: String,
        value: Double,
        minimum: Double,
        maximum: Double
    )
}

public enum SMCCodec: Sendable {
    public static func decode(
        _ bytes: [UInt8],
        dataType reportedDataType: String,
        expectedSize: Int
    ) throws -> Double {
        let dataType = try validatedDataType(reportedDataType, expectedSize: expectedSize)
        guard bytes.count == expectedSize else {
            throw SMCCodecError.wrongSize(
                dataType: reportedDataType,
                expected: expectedSize,
                actual: bytes.count
            )
        }

        switch dataType {
        case .float:
            let bits = UInt32(bytes[0])
                | (UInt32(bytes[1]) << 8)
                | (UInt32(bytes[2]) << 16)
                | (UInt32(bytes[3]) << 24)
            let value = Float(bitPattern: bits)
            guard value.isFinite else {
                throw SMCCodecError.nonFiniteFloat
            }
            return Double(value)

        case .fpe2:
            return Double(bigEndianUInt16(bytes)) / 4

        case .sp78:
            let value = Int16(bitPattern: bigEndianUInt16(bytes))
            return Double(value) / 256

        case .ui8:
            return Double(bytes[0])

        case .ui16:
            return Double(bigEndianUInt16(bytes))

        case .ui32:
            let value = (UInt32(bytes[0]) << 24)
                | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8)
                | UInt32(bytes[3])
            return Double(value)
        }
    }

    public static func encode(
        _ value: Double,
        dataType reportedDataType: String,
        expectedSize: Int
    ) throws -> [UInt8] {
        let dataType = try validatedDataType(reportedDataType, expectedSize: expectedSize)

        switch dataType {
        case .float:
            guard value.isFinite else {
                throw SMCCodecError.nonFiniteFloat
            }
            let maximum = Double(Float.greatestFiniteMagnitude)
            guard value >= -maximum, value <= maximum else {
                throw SMCCodecError.valueOutOfRange(
                    dataType: reportedDataType,
                    value: value,
                    minimum: -maximum,
                    maximum: maximum
                )
            }
            let encoded = Float(value)
            guard encoded.isFinite else {
                throw SMCCodecError.valueOutOfRange(
                    dataType: reportedDataType,
                    value: value,
                    minimum: -maximum,
                    maximum: maximum
                )
            }
            let bits = encoded.bitPattern
            return [
                UInt8(truncatingIfNeeded: bits),
                UInt8(truncatingIfNeeded: bits >> 8),
                UInt8(truncatingIfNeeded: bits >> 16),
                UInt8(truncatingIfNeeded: bits >> 24),
            ]

        case .fpe2:
            let raw = try fixedPointRawValue(
                value,
                scale: 4,
                minimum: 0,
                maximum: 16_383.75,
                dataType: reportedDataType
            )
            return bigEndianBytes(UInt16(raw))

        case .sp78:
            let raw = try fixedPointRawValue(
                value,
                scale: 256,
                minimum: -128,
                maximum: 127.99609375,
                dataType: reportedDataType
            )
            return bigEndianBytes(UInt16(bitPattern: Int16(raw)))

        case .ui8:
            let raw = try unsignedInteger(
                value,
                maximum: Double(UInt8.max),
                dataType: reportedDataType
            )
            return [UInt8(raw)]

        case .ui16:
            let raw = try unsignedInteger(
                value,
                maximum: Double(UInt16.max),
                dataType: reportedDataType
            )
            return bigEndianBytes(UInt16(raw))

        case .ui32:
            let raw = try unsignedInteger(
                value,
                maximum: Double(UInt32.max),
                dataType: reportedDataType
            )
            let encoded = UInt32(raw)
            return [
                UInt8(truncatingIfNeeded: encoded >> 24),
                UInt8(truncatingIfNeeded: encoded >> 16),
                UInt8(truncatingIfNeeded: encoded >> 8),
                UInt8(truncatingIfNeeded: encoded),
            ]
        }
    }

    private static func validatedDataType(
        _ reportedDataType: String,
        expectedSize: Int
    ) throws -> SMCDataType {
        let dataType = try SMCDataType(reportedFourCC: reportedDataType)
        guard expectedSize == dataType.encodedSize else {
            throw SMCCodecError.wrongSize(
                dataType: reportedDataType,
                expected: dataType.encodedSize,
                actual: expectedSize
            )
        }
        return dataType
    }

    private static func bigEndianUInt16(_ bytes: [UInt8]) -> UInt16 {
        (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
    }

    private static func bigEndianBytes(_ value: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    private static func fixedPointRawValue(
        _ value: Double,
        scale: Double,
        minimum: Double,
        maximum: Double,
        dataType: String
    ) throws -> Int {
        guard value.isFinite, value >= minimum, value <= maximum else {
            throw SMCCodecError.valueOutOfRange(
                dataType: dataType,
                value: value,
                minimum: minimum,
                maximum: maximum
            )
        }
        let scaled = value * scale
        guard scaled.rounded() == scaled else {
            throw SMCCodecError.invalidEncodeValue(dataType: dataType, value: value)
        }
        return Int(scaled)
    }

    private static func unsignedInteger(
        _ value: Double,
        maximum: Double,
        dataType: String
    ) throws -> UInt64 {
        guard value.isFinite, value >= 0, value <= maximum else {
            throw SMCCodecError.valueOutOfRange(
                dataType: dataType,
                value: value,
                minimum: 0,
                maximum: maximum
            )
        }
        guard value.rounded() == value else {
            throw SMCCodecError.invalidEncodeValue(dataType: dataType, value: value)
        }
        return UInt64(value)
    }
}
