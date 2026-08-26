/// A printable four-byte ASCII code with a canonical big-endian numeric value.
///
/// For example, `FNum` is numerically `0x464E756D`. AppleSMC's scalar
/// parameter fields use the host ABI byte order, so that numeric value is
/// serialized as `[0x6D, 0x75, 0x4E, 0x46]` on little-endian Apple Silicon.
public struct SMCFourCC: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt32

    public init(_ string: String) throws {
        try self.init(bytes: Array(string.utf8))
    }

    public init(bytes: [UInt8]) throws {
        guard bytes.count == 4 else {
            throw SMCFourCCError.invalidByteCount(bytes.count)
        }
        guard bytes.allSatisfy({ $0 < 0x80 }) else {
            throw SMCFourCCError.nonASCII
        }
        try Self.validatePrintable(bytes)
        rawValue = (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
    }

    public init(rawValue: UInt32) throws {
        let bytes = Self.canonicalBytes(rawValue)
        try Self.validatePrintable(bytes)
        self.rawValue = rawValue
    }

    public var stringValue: String {
        String(decoding: Self.canonicalBytes(rawValue), as: UTF8.self)
    }

    public var description: String { stringValue }

    private static func canonicalBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ]
    }

    private static func validatePrintable(_ bytes: [UInt8]) throws {
        for (index, byte) in bytes.enumerated() where !(0x20...0x7E).contains(byte) {
            throw SMCFourCCError.nonPrintable(byte: byte, index: index)
        }
    }
}

public enum SMCFourCCError: Error, Equatable, Sendable {
    case invalidByteCount(Int)
    case nonASCII
    case nonPrintable(byte: UInt8, index: Int)
}

public enum SMCCommand: UInt8, Equatable, Sendable {
    case readBytes = 5
    case writeBytes = 6
    case getKeyFromIndex = 8
    case getKeyInfo = 9
}

public enum AppleSMCProtocol: Sendable {
    /// `IOConnectCallStructMethod` selector used for every AppleSMC command.
    public static let ioConnectSelector: UInt32 = 2
}

public struct SMCKeyInfo: Equatable, Sendable {
    public var dataSize: UInt32
    /// Canonical big-endian FourCC numeric value; serialized as a native scalar.
    public var dataType: UInt32
    public var attributes: UInt8

    public init() {
        dataSize = 0
        dataType = 0
        attributes = 0
    }

    public init(dataSize: UInt32, dataType: SMCFourCC, attributes: UInt8 = 0) {
        self.dataSize = dataSize
        self.dataType = dataType.rawValue
        self.attributes = attributes
    }

    public init(dataSize: UInt32, dataTypeRawValue: UInt32, attributes: UInt8) {
        self.dataSize = dataSize
        self.dataType = dataTypeRawValue
        self.attributes = attributes
    }

    public var dataTypeFourCC: SMCFourCC? {
        try? SMCFourCC(rawValue: dataType)
    }
}

public enum SMCKeyDataError: Error, Equatable, Sendable {
    case invalidWireLength(expected: Int, actual: Int)
    case invalidFieldLength(field: String, expected: Int, actual: Int)
    case payloadTooLarge(maximum: Int, actual: Int)
    case dataSizeTooLarge(maximum: Int, actual: Int)
    case payloadSizeMismatch(reported: Int, logical: Int)
}

/// Explicit, ABI-independent serialization of AppleSMC's 80-byte key data.
///
/// This type deliberately does not use `MemoryLayout`, raw struct copies, or
/// pointer binding. Scalar C fields are encoded little-endian to match the
/// native ABI on supported Apple Silicon hosts. FourCC values remain canonical
/// big-endian numbers even though their scalar wire bytes are little-endian.
public struct SMCKeyData: Equatable, Sendable {
    public static let wireSize = 80
    public static let maximumPayloadSize = 32

    /// Canonical FourCC numeric value, or zero for index requests.
    public var key: UInt32
    public var version: [UInt8]
    public var pLimit: [UInt8]
    public var keyInfo: SMCKeyInfo
    public var result: UInt8
    public var status: UInt8
    public var commandByte: UInt8
    public var data32: UInt32
    public var payload: [UInt8]

    public init(
        key: SMCFourCC,
        version: [UInt8] = Array(repeating: 0, count: 6),
        pLimit: [UInt8] = Array(repeating: 0, count: 16),
        keyInfo: SMCKeyInfo = SMCKeyInfo(),
        result: UInt8 = 0,
        status: UInt8 = 0,
        commandByte: UInt8 = 0,
        data32: UInt32 = 0,
        payload: [UInt8] = []
    ) throws {
        try self.init(
            keyRawValue: key.rawValue,
            version: version,
            pLimit: pLimit,
            keyInfo: keyInfo,
            result: result,
            status: status,
            commandByte: commandByte,
            data32: data32,
            payload: payload
        )
    }

    public init(
        key: SMCFourCC,
        version: [UInt8] = Array(repeating: 0, count: 6),
        pLimit: [UInt8] = Array(repeating: 0, count: 16),
        keyInfo: SMCKeyInfo = SMCKeyInfo(),
        result: UInt8 = 0,
        status: UInt8 = 0,
        command: SMCCommand,
        data32: UInt32 = 0,
        payload: [UInt8] = []
    ) throws {
        try self.init(
            keyRawValue: key.rawValue,
            version: version,
            pLimit: pLimit,
            keyInfo: keyInfo,
            result: result,
            status: status,
            commandByte: command.rawValue,
            data32: data32,
            payload: payload
        )
    }

    private init(
        keyRawValue: UInt32,
        version: [UInt8],
        pLimit: [UInt8],
        keyInfo: SMCKeyInfo,
        result: UInt8,
        status: UInt8,
        commandByte: UInt8,
        data32: UInt32,
        payload: [UInt8]
    ) throws {
        try Self.validateFixedFields(version: version, pLimit: pLimit, keyInfo: keyInfo)
        guard payload.count <= Self.maximumPayloadSize else {
            throw SMCKeyDataError.payloadTooLarge(
                maximum: Self.maximumPayloadSize,
                actual: payload.count
            )
        }
        key = keyRawValue
        self.version = version
        self.pLimit = pLimit
        self.keyInfo = keyInfo
        self.result = result
        self.status = status
        self.commandByte = commandByte
        self.data32 = data32
        self.payload = payload + Array(
            repeating: 0,
            count: Self.maximumPayloadSize - payload.count
        )
    }

    public var keyFourCC: SMCFourCC? { try? SMCFourCC(rawValue: key) }
    public var command: SMCCommand? { SMCCommand(rawValue: commandByte) }

    public func encode() throws -> [UInt8] {
        try Self.validateFixedFields(version: version, pLimit: pLimit, keyInfo: keyInfo)
        guard payload.count == Self.maximumPayloadSize else {
            if payload.count > Self.maximumPayloadSize {
                throw SMCKeyDataError.payloadTooLarge(
                    maximum: Self.maximumPayloadSize,
                    actual: payload.count
                )
            }
            throw SMCKeyDataError.invalidFieldLength(
                field: "payload",
                expected: Self.maximumPayloadSize,
                actual: payload.count
            )
        }
        var bytes = Array(repeating: UInt8(0), count: Self.wireSize)

        Self.writeLittleEndian(key, to: &bytes, at: 0)
        bytes.replaceSubrange(4..<10, with: version)
        // 10...11: native alignment padding, always zero.
        bytes.replaceSubrange(12..<28, with: pLimit)
        Self.writeLittleEndian(keyInfo.dataSize, to: &bytes, at: 28)
        Self.writeLittleEndian(keyInfo.dataType, to: &bytes, at: 32)
        bytes[36] = keyInfo.attributes
        // 37: packed keyInfo alignment byte; 38...39: explicit UInt16 padding.
        bytes[40] = result
        bytes[41] = status
        bytes[42] = commandByte
        // 43: native UInt32 alignment padding.
        Self.writeLittleEndian(data32, to: &bytes, at: 44)
        bytes.replaceSubrange(48..<80, with: payload)

        return bytes
    }

    public static func decode(_ bytes: [UInt8]) throws -> SMCKeyData {
        guard bytes.count == wireSize else {
            throw SMCKeyDataError.invalidWireLength(expected: wireSize, actual: bytes.count)
        }
        return try SMCKeyData(
            keyRawValue: readLittleEndian(bytes, at: 0),
            version: Array(bytes[4..<10]),
            pLimit: Array(bytes[12..<28]),
            keyInfo: SMCKeyInfo(
                dataSize: readLittleEndian(bytes, at: 28),
                dataTypeRawValue: readLittleEndian(bytes, at: 32),
                attributes: bytes[36]
            ),
            result: bytes[40],
            status: bytes[41],
            commandByte: bytes[42],
            data32: readLittleEndian(bytes, at: 44),
            payload: Array(bytes[48..<80])
        )
    }

    public static func keyInfoRequest(key: SMCFourCC) throws -> SMCKeyData {
        try SMCKeyData(key: key, command: .getKeyInfo)
    }

    public static func readRequest(key: SMCFourCC, keyInfo: SMCKeyInfo) throws -> SMCKeyData {
        try SMCKeyData(key: key, keyInfo: keyInfo, command: .readBytes)
    }

    public static func writeRequest(
        key: SMCFourCC,
        keyInfo: SMCKeyInfo,
        payload: [UInt8]
    ) throws -> SMCKeyData {
        try Self.validateDataSize(keyInfo.dataSize)
        guard payload.count == Int(keyInfo.dataSize) else {
            throw SMCKeyDataError.payloadSizeMismatch(
                reported: Int(keyInfo.dataSize),
                logical: payload.count
            )
        }
        return try SMCKeyData(key: key, keyInfo: keyInfo, command: .writeBytes, payload: payload)
    }

    public static func getKeyFromIndexRequest(_ index: UInt32) throws -> SMCKeyData {
        try SMCKeyData(
            keyRawValue: 0,
            version: Array(repeating: 0, count: 6),
            pLimit: Array(repeating: 0, count: 16),
            keyInfo: SMCKeyInfo(),
            result: 0,
            status: 0,
            commandByte: SMCCommand.getKeyFromIndex.rawValue,
            data32: index,
            payload: []
        )
    }

    private static func validateFixedFields(
        version: [UInt8],
        pLimit: [UInt8],
        keyInfo: SMCKeyInfo
    ) throws {
        guard version.count == 6 else {
            throw SMCKeyDataError.invalidFieldLength(
                field: "version",
                expected: 6,
                actual: version.count
            )
        }
        guard pLimit.count == 16 else {
            throw SMCKeyDataError.invalidFieldLength(
                field: "pLimit",
                expected: 16,
                actual: pLimit.count
            )
        }
        try validateDataSize(keyInfo.dataSize)
    }

    private static func validateDataSize(_ dataSize: UInt32) throws {
        guard dataSize <= UInt32(maximumPayloadSize) else {
            throw SMCKeyDataError.dataSizeTooLarge(
                maximum: maximumPayloadSize,
                actual: Int(dataSize)
            )
        }
    }

    private static func writeLittleEndian(_ value: UInt32, to bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private static func readLittleEndian(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
