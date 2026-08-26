#if os(macOS)
import IOKit
#endif

public struct SMCValue: Equatable, Sendable {
    public let key: SMCFourCC
    public let dataType: SMCFourCC
    public let dataSize: UInt32
    public let attributes: UInt8
    public let bytes: [UInt8]

    public init(
        key: SMCFourCC,
        dataType: SMCFourCC,
        dataSize: UInt32,
        attributes: UInt8,
        bytes: [UInt8]
    ) throws {
        guard dataSize <= UInt32(SMCKeyData.maximumPayloadSize) else {
            throw SMCValueError.invalidDataSize(dataSize)
        }
        guard bytes.count == Int(dataSize) else {
            throw SMCValueError.byteCountMismatch(reported: dataSize, actual: bytes.count)
        }
        self.key = key
        self.dataType = dataType
        self.dataSize = dataSize
        self.attributes = attributes
        self.bytes = bytes
    }

    public func numericValue() throws -> Double {
        try SMCCodec.decode(
            bytes,
            dataType: dataType.stringValue,
            expectedSize: Int(dataSize)
        )
    }
}

public enum SMCValueError: Error, Equatable, Sendable {
    case invalidDataSize(UInt32)
    case byteCountMismatch(reported: UInt32, actual: Int)
}

public enum SMCTransportError: Error, Equatable, Sendable {
    case serviceNotFound
    case openFailed(Int32)
    case callFailed(Int32)
    case keyNotFound(SMCFourCC)
    case driverResult(result: UInt8, status: UInt8)
    case driverStatus(UInt8)
    case malformedResponse(expected: Int, actual: Int)
    case invalidReturnedSize(UInt32)
    case invalidReturnedDataType(UInt32)
    case invalidReturnedKey(UInt32)
    case unexpectedReturnedKey(expected: SMCFourCC, actual: UInt32)
    case inconsistentReadMetadata(expected: SMCKeyInfo, actual: SMCKeyInfo)
}

public enum SMCReadOnlyPolicyError: Error, Equatable, Sendable {
    case invalidSelector(expected: UInt32, actual: UInt32)
    case invalidRequestLength(expected: Int, actual: Int)
    case malformedRequest
    case disallowedCommand(UInt8)
}

/// Pure policy seam for validating AppleSMC requests before any IOKit call.
enum AppleSMCReadOnlyRequestValidator {
    static func validate(selector: UInt32, request: [UInt8]) throws {
        guard selector == AppleSMCProtocol.ioConnectSelector else {
            throw SMCReadOnlyPolicyError.invalidSelector(
                expected: AppleSMCProtocol.ioConnectSelector,
                actual: selector
            )
        }
        guard request.count == SMCKeyData.wireSize else {
            throw SMCReadOnlyPolicyError.invalidRequestLength(
                expected: SMCKeyData.wireSize,
                actual: request.count
            )
        }

        let decoded: SMCKeyData
        do {
            decoded = try SMCKeyData.decode(request)
        } catch {
            throw SMCReadOnlyPolicyError.malformedRequest
        }
        guard decoded.command == .readBytes
            || decoded.command == .getKeyFromIndex
            || decoded.command == .getKeyInfo
        else {
            throw SMCReadOnlyPolicyError.disallowedCommand(decoded.commandByte)
        }
    }
}

public protocol SMCReading: Sendable {
    func read(_ key: SMCFourCC) async throws -> SMCValue
    func key(at index: UInt32) async throws -> SMCFourCC
}

/// Low-level seam for the one read-only AppleSMC external method.
/// Implementations receive and return explicit wire images, never Swift ABI structs.
public protocol SMCExecuting: Sendable {
    func execute(selector: UInt32, request: [UInt8]) async throws -> [UInt8]
}

public struct SMCClient: SMCReading, Sendable {
    private let executor: any SMCExecuting

    public init(executor: any SMCExecuting) {
        self.executor = executor
    }

    #if os(macOS)
    public init() throws {
        executor = try AppleSMCIOKitExecutor()
    }
    #endif

    public func read(_ key: SMCFourCC) async throws -> SMCValue {
        let infoRequest = try SMCKeyData.keyInfoRequest(key: key).encode()
        let infoResponse = try await call(infoRequest, key: key)
        let info = infoResponse.keyInfo
        guard info.dataSize <= UInt32(SMCKeyData.maximumPayloadSize) else {
            throw SMCTransportError.invalidReturnedSize(info.dataSize)
        }
        guard let dataType = try? SMCFourCC(rawValue: info.dataType) else {
            throw SMCTransportError.invalidReturnedDataType(info.dataType)
        }

        let readRequest = try SMCKeyData.readRequest(key: key, keyInfo: info).encode()
        let readResponse = try await call(readRequest, key: key)
        let emptyReadMetadata = SMCKeyInfo()
        guard readResponse.keyInfo == emptyReadMetadata || readResponse.keyInfo == info else {
            throw SMCTransportError.inconsistentReadMetadata(
                expected: info,
                actual: readResponse.keyInfo
            )
        }

        return try SMCValue(
            key: key,
            dataType: dataType,
            dataSize: info.dataSize,
            attributes: info.attributes,
            bytes: Array(readResponse.payload.prefix(Int(info.dataSize)))
        )
    }

    public func key(at index: UInt32) async throws -> SMCFourCC {
        let request = try SMCKeyData.getKeyFromIndexRequest(index).encode()
        let response = try await call(request, key: nil)
        guard let key = try? SMCFourCC(rawValue: response.key) else {
            throw SMCTransportError.invalidReturnedKey(response.key)
        }
        return key
    }

    private func call(_ request: [UInt8], key: SMCFourCC?) async throws -> SMCKeyData {
        let bytes = try await executor.execute(
            selector: AppleSMCProtocol.ioConnectSelector,
            request: request
        )
        guard bytes.count == SMCKeyData.wireSize else {
            throw SMCTransportError.malformedResponse(
                expected: SMCKeyData.wireSize,
                actual: bytes.count
            )
        }

        let response: SMCKeyData
        do {
            response = try SMCKeyData.decode(bytes)
        } catch SMCKeyDataError.dataSizeTooLarge(_, let actual) {
            throw SMCTransportError.invalidReturnedSize(UInt32(actual))
        } catch {
            throw SMCTransportError.malformedResponse(
                expected: SMCKeyData.wireSize,
                actual: bytes.count
            )
        }

        if response.result == 132, let key {
            throw SMCTransportError.keyNotFound(key)
        }
        guard response.result == 0 else {
            throw SMCTransportError.driverResult(
                result: response.result,
                status: response.status
            )
        }
        guard response.status == 0 else {
            throw SMCTransportError.driverStatus(response.status)
        }
        if let expectedKey = key {
            let command = request[42]
            let isMeasuredZeroSentinel = response.key == 0
                && (command == SMCCommand.getKeyInfo.rawValue
                    || command == SMCCommand.readBytes.rawValue)
            guard response.key == expectedKey.rawValue || isMeasuredZeroSentinel else {
                throw SMCTransportError.unexpectedReturnedKey(
                    expected: expectedKey,
                    actual: response.key
                )
            }
        }
        return response
    }
}

#if os(macOS)
/// A serialized, unprivileged AppleSMC connection exposing only selector 2.
public actor AppleSMCIOKitExecutor: SMCExecuting {
    private let connection: io_connect_t

    public init() throws {
        guard let matching = IOServiceMatching("AppleSMC") else {
            throw SMCTransportError.serviceNotFound
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else {
            throw SMCTransportError.serviceNotFound
        }
        defer { IOObjectRelease(service) }

        var opened = io_connect_t(IO_OBJECT_NULL)
        let result = IOServiceOpen(service, mach_task_self_, 0, &opened)
        guard result == KERN_SUCCESS else {
            if opened != IO_OBJECT_NULL {
                IOServiceClose(opened)
            }
            throw SMCTransportError.openFailed(result)
        }
        connection = opened
    }

    deinit {
        IOServiceClose(connection)
    }

    public func execute(selector: UInt32, request: [UInt8]) async throws -> [UInt8] {
        try AppleSMCReadOnlyRequestValidator.validate(selector: selector, request: request)

        var output = Array(repeating: UInt8(0), count: SMCKeyData.wireSize)
        var outputSize = output.count
        let result = request.withUnsafeBytes { inputBuffer in
            output.withUnsafeMutableBytes { outputBuffer in
                IOConnectCallStructMethod(
                    connection,
                    AppleSMCProtocol.ioConnectSelector,
                    inputBuffer.baseAddress,
                    inputBuffer.count,
                    outputBuffer.baseAddress,
                    &outputSize
                )
            }
        }
        guard result == KERN_SUCCESS else {
            throw SMCTransportError.callFailed(result)
        }
        guard outputSize == SMCKeyData.wireSize else {
            throw SMCTransportError.malformedResponse(
                expected: SMCKeyData.wireSize,
                actual: outputSize
            )
        }
        return output
    }
}
#endif
