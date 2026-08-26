import XCTest
@testable import FanControlCore

final class SMCClientTests: XCTestCase {
    func testReadPerformsKeyInfoThenReadWithReturnedMetadata() async throws {
        let key = try SMCFourCC("FNum")
        let info = SMCKeyInfo(dataSize: 1, dataType: try SMCFourCC("ui8 "), attributes: 0xA5)
        let executor = ScriptedSMCExecutor(responses: [
            .success(try response(key: key, keyInfo: info, command: .getKeyInfo)),
            .success(try response(key: key, keyInfo: info, command: .readBytes, payload: [1, 0xEE])),
        ])
        let client = SMCClient(executor: executor)

        let value = try await client.read(key)

        XCTAssertEqual(value, try SMCValue(key: key, dataType: SMCFourCC("ui8 "), dataSize: 1, attributes: 0xA5, bytes: [1]))
        XCTAssertEqual(try value.numericValue(), 1)
        let calls = await executor.recordedCalls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.map(\.selector), [2, 2])
        let requests = try calls.map { try SMCKeyData.decode($0.request) }
        XCTAssertEqual(requests.map(\.command), [.getKeyInfo, .readBytes])
        XCTAssertEqual(requests.map(\.key), [key.rawValue, key.rawValue])
        XCTAssertEqual(requests[1].keyInfo, info)
        XCTAssertFalse(requests.contains { $0.commandByte == 6 })
    }

    func testFloatReadReturnsFourHardwareBytesAndDecodes() async throws {
        let key = try SMCFourCC("F0Ac")
        let info = SMCKeyInfo(dataSize: 4, dataType: try SMCFourCC("flt "), attributes: 0)
        let hardwareBytes: [UInt8] = [0x00, 0xB0, 0x18, 0x45]
        let executor = ScriptedSMCExecutor(responses: [
            .success(try response(key: key, keyInfo: info, command: .getKeyInfo)),
            .success(try response(key: key, keyInfo: info, command: .readBytes, payload: hardwareBytes)),
        ])

        let value = try await SMCClient(executor: executor).read(key)

        XCTAssertEqual(value.bytes, hardwareBytes)
        XCTAssertEqual(try value.numericValue(), 2_443)
    }

    func testValueRejectsOversizeAndLogicalSizeMismatch() throws {
        let key = try SMCFourCC("FNum")
        let type = try SMCFourCC("ui8 ")
        XCTAssertThrowsError(try SMCValue(key: key, dataType: type, dataSize: 33, attributes: 0, bytes: Array(repeating: 0, count: 33))) {
            XCTAssertEqual($0 as? SMCValueError, .invalidDataSize(33))
        }
        XCTAssertThrowsError(try SMCValue(key: key, dataType: type, dataSize: 1, attributes: 0, bytes: [])) {
            XCTAssertEqual($0 as? SMCValueError, .byteCountMismatch(reported: 1, actual: 0))
        }
    }

    func testDriverKeyNotFoundAndOtherResultAreDistinct() async throws {
        let key = try SMCFourCC("FNum")
        for (result, expected): (UInt8, SMCTransportError) in [
            (132, .keyNotFound(key)),
            (7, .driverResult(result: 7, status: 0)),
        ] {
            let executor = ScriptedSMCExecutor(responses: [.success(try response(key: key, result: result, command: .getKeyInfo))])
            do {
                _ = try await SMCClient(executor: executor).read(key)
                XCTFail("Expected failure")
            } catch {
                XCTAssertEqual(error as? SMCTransportError, expected)
            }
        }
    }

    func testNonzeroDriverStatusIsRejected() async throws {
        let key = try SMCFourCC("FNum")
        let executor = ScriptedSMCExecutor(responses: [.success(try response(key: key, status: 3, command: .getKeyInfo))])
        do {
            _ = try await SMCClient(executor: executor).read(key)
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? SMCTransportError, .driverStatus(3))
        }
    }

    func testExecutorCallFailureRemainsDistinctFromMissingKey() async throws {
        let key = try SMCFourCC("FNum")
        let executor = ScriptedSMCExecutor(responses: [.failure(.callFailed(0x1234))])
        do {
            _ = try await SMCClient(executor: executor).read(key)
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? SMCTransportError, .callFailed(0x1234))
        }
    }

    func testMalformedOutputLengthIsTyped() async throws {
        let key = try SMCFourCC("FNum")
        let executor = ScriptedSMCExecutor(responses: [.success(Array(repeating: 0, count: 79))])
        do {
            _ = try await SMCClient(executor: executor).read(key)
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? SMCTransportError, .malformedResponse(expected: 80, actual: 79))
        }
    }

    func testRejectsReturnedSizeAboveThirtyTwo() async throws {
        let key = try SMCFourCC("FNum")
        var bytes = try response(key: key, command: .getKeyInfo)
        bytes[28] = 33
        let executor = ScriptedSMCExecutor(responses: [.success(bytes)])
        do {
            _ = try await SMCClient(executor: executor).read(key)
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? SMCTransportError, .invalidReturnedSize(33))
        }
    }

    func testRejectsNonprintableReturnedDataType() async throws {
        let key = try SMCFourCC("FNum")
        var bytes = try response(key: key, command: .getKeyInfo)
        bytes.replaceSubrange(28..<32, with: [1, 0, 0, 0])
        bytes.replaceSubrange(32..<36, with: [0, 0, 0, 0])
        let executor = ScriptedSMCExecutor(responses: [.success(bytes)])
        do {
            _ = try await SMCClient(executor: executor).read(key)
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? SMCTransportError, .invalidReturnedDataType(0))
        }
    }

    func testReadAcceptsDriverReadResponseWithEmptyMetadata() async throws {
        let key = try SMCFourCC("FNum")
        let info = SMCKeyInfo(dataSize: 1, dataType: try SMCFourCC("ui8 "), attributes: 0x80)
        let executor = ScriptedSMCExecutor(responses: [
            .success(try response(key: key, keyInfo: info, command: .getKeyInfo)),
            .success(try response(key: key, command: .readBytes, payload: [1])),
        ])

        let value = try await SMCClient(executor: executor).read(key)

        XCTAssertEqual(value.bytes, [1])
        XCTAssertEqual(value.attributes, 0x80)
    }

    func testRejectsInconsistentReadMetadata() async throws {
        let key = try SMCFourCC("FNum")
        let info = SMCKeyInfo(dataSize: 1, dataType: try SMCFourCC("ui8 "), attributes: 0)
        let changed = SMCKeyInfo(dataSize: 1, dataType: try SMCFourCC("ui8 "), attributes: 1)
        let executor = ScriptedSMCExecutor(responses: [
            .success(try response(key: key, keyInfo: info, command: .getKeyInfo)),
            .success(try response(key: key, keyInfo: changed, command: .readBytes, payload: [1])),
        ])
        do {
            _ = try await SMCClient(executor: executor).read(key)
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? SMCTransportError, .inconsistentReadMetadata(expected: info, actual: changed))
        }
    }

    func testKeyAtIndexUsesCommandEightAndReturnsCanonicalKey() async throws {
        let returned = try SMCFourCC("FNum")
        let executor = ScriptedSMCExecutor(responses: [.success(try response(key: returned, command: .getKeyFromIndex))])

        let key = try await SMCClient(executor: executor).key(at: 1_007)

        XCTAssertEqual(key, returned)
        let calls = await executor.recordedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].selector, 2)
        let request = try SMCKeyData.decode(calls[0].request)
        XCTAssertEqual(request.command, .getKeyFromIndex)
        XCTAssertEqual(request.data32, 1_007)
        XCTAssertEqual(request.key, 0)
        XCTAssertNotEqual(request.commandByte, 6)
    }

    func testKeyAtIndexRejectsNonprintableReturnedKey() async throws {
        var bytes = try response(key: SMCFourCC("FNum"), command: .getKeyFromIndex)
        bytes.replaceSubrange(0..<4, with: [0, 0, 0, 0])
        let executor = ScriptedSMCExecutor(responses: [.success(bytes)])
        do {
            _ = try await SMCClient(executor: executor).key(at: 0)
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? SMCTransportError, .invalidReturnedKey(0))
        }
    }

    func testKeyInfoResponseRejectsDifferentPrintableReturnedKey() async throws {
        let expected = try SMCFourCC("FNum")
        let actual = try SMCFourCC("F0Ac")
        let info = SMCKeyInfo(dataSize: 1, dataType: try SMCFourCC("ui8 "))
        let executor = ScriptedSMCExecutor(responses: [
            .success(try response(key: actual, keyInfo: info, command: .getKeyInfo)),
            .success(try response(key: expected, keyInfo: info, command: .readBytes, payload: [1])),
        ])

        do {
            _ = try await SMCClient(executor: executor).read(expected)
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(
                error as? SMCTransportError,
                .unexpectedReturnedKey(expected: expected, actual: actual.rawValue)
            )
        }
    }

    func testReadBytesResponseRejectsDifferentPrintableReturnedKey() async throws {
        let expected = try SMCFourCC("FNum")
        let actual = try SMCFourCC("F0Ac")
        let info = SMCKeyInfo(dataSize: 1, dataType: try SMCFourCC("ui8 "))
        let executor = ScriptedSMCExecutor(responses: [
            .success(try response(key: expected, keyInfo: info, command: .getKeyInfo)),
            .success(try response(key: actual, keyInfo: info, command: .readBytes, payload: [1])),
        ])

        do {
            _ = try await SMCClient(executor: executor).read(expected)
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(
                error as? SMCTransportError,
                .unexpectedReturnedKey(expected: expected, actual: actual.rawValue)
            )
        }
    }

    func testNamedReadAcceptsMeasuredZeroReturnedKeySentinelForCommandsNineAndFive() async throws {
        let key = try SMCFourCC("FNum")
        let info = SMCKeyInfo(dataSize: 1, dataType: try SMCFourCC("ui8 "))
        let executor = ScriptedSMCExecutor(responses: [
            .success(try responseWithZeroKey(keyInfo: info, command: .getKeyInfo)),
            .success(try responseWithZeroKey(command: .readBytes, payload: [1])),
        ])

        let value = try await SMCClient(executor: executor).read(key)

        XCTAssertEqual(value.bytes, [1])
    }

    func testReadOnlyRequestValidatorAcceptsOnlyReadCommandsWithSelectorTwo() throws {
        let key = try SMCFourCC("FNum")
        let info = SMCKeyInfo(dataSize: 1, dataType: try SMCFourCC("ui8 "))
        let requests = [
            try SMCKeyData.readRequest(key: key, keyInfo: info).encode(),
            try SMCKeyData.getKeyFromIndexRequest(0).encode(),
            try SMCKeyData.keyInfoRequest(key: key).encode(),
        ]

        for request in requests {
            XCTAssertNoThrow(
                try AppleSMCReadOnlyRequestValidator.validate(selector: 2, request: request)
            )
        }
    }

    func testReadOnlyRequestValidatorRejectsWrongSelector() throws {
        let request = try SMCKeyData.keyInfoRequest(key: SMCFourCC("FNum")).encode()

        XCTAssertThrowsError(
            try AppleSMCReadOnlyRequestValidator.validate(selector: 1, request: request)
        ) {
            XCTAssertEqual(
                $0 as? SMCReadOnlyPolicyError,
                .invalidSelector(expected: 2, actual: 1)
            )
        }
    }

    func testReadOnlyRequestValidatorRejectsCommandSixZeroAndUnknown() throws {
        let key = try SMCFourCC("FNum")
        for command: UInt8 in [6, 0, 7] {
            let request = try SMCKeyData(key: key, commandByte: command).encode()

            XCTAssertThrowsError(
                try AppleSMCReadOnlyRequestValidator.validate(selector: 2, request: request)
            ) {
                XCTAssertEqual($0 as? SMCReadOnlyPolicyError, .disallowedCommand(command))
            }
        }
    }

    func testReadOnlyRequestValidatorRejectsNonEightyByteRequest() {
        let request = Array(repeating: UInt8(0), count: 79)

        XCTAssertThrowsError(
            try AppleSMCReadOnlyRequestValidator.validate(selector: 2, request: request)
        ) {
            XCTAssertEqual(
                $0 as? SMCReadOnlyPolicyError,
                .invalidRequestLength(expected: 80, actual: 79)
            )
        }
    }

    func testReadProtocolCanBeImplementedBySendableFutureFake() async throws {
        let expected = try SMCValue(key: SMCFourCC("FNum"), dataType: SMCFourCC("ui8 "), dataSize: 1, attributes: 0, bytes: [1])
        let fake: any SMCReading = FutureReaderFake(value: expected)
        requireSendable(expected)
        let readValue = try await fake.read(SMCFourCC("FNum"))
        let indexedKey = try await fake.key(at: 0)
        XCTAssertEqual(readValue, expected)
        XCTAssertEqual(indexedKey, try SMCFourCC("FNum"))
    }
}

private actor ScriptedSMCExecutor: SMCExecuting {
    struct Call: Sendable {
        let selector: UInt32
        let request: [UInt8]
    }

    private var responses: [Result<[UInt8], SMCTransportError>]
    private var calls: [Call] = []

    init(responses: [Result<[UInt8], SMCTransportError>]) {
        self.responses = responses
    }

    func execute(selector: UInt32, request: [UInt8]) async throws -> [UInt8] {
        calls.append(Call(selector: selector, request: request))
        guard !responses.isEmpty else { throw SMCTransportError.callFailed(-1) }
        return try responses.removeFirst().get()
    }

    func recordedCalls() -> [Call] { calls }
}

private struct FutureReaderFake: SMCReading {
    let value: SMCValue
    func read(_ key: SMCFourCC) async throws -> SMCValue { value }
    func key(at index: UInt32) async throws -> SMCFourCC { value.key }
}

private func response(
    key: SMCFourCC,
    keyInfo: SMCKeyInfo = SMCKeyInfo(),
    result: UInt8 = 0,
    status: UInt8 = 0,
    command: SMCCommand,
    payload: [UInt8] = []
) throws -> [UInt8] {
    try SMCKeyData(key: key, keyInfo: keyInfo, result: result, status: status, command: command, payload: payload).encode()
}

private func responseWithZeroKey(
    keyInfo: SMCKeyInfo = SMCKeyInfo(),
    command: SMCCommand,
    payload: [UInt8] = []
) throws -> [UInt8] {
    var bytes = try response(
        key: SMCFourCC("FNum"),
        keyInfo: keyInfo,
        command: command,
        payload: payload
    )
    bytes.replaceSubrange(0..<4, with: [0, 0, 0, 0])
    return bytes
}

private func requireSendable<T: Sendable>(_: T) {}
