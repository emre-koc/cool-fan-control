import XCTest
@testable import FanControlCore

final class SMCFourCCTests: XCTestCase {
    func testCanonicalNumericValuesAndStringRoundTrips() throws {
        let vectors: [(String, UInt32)] = [
            ("FNum", 0x464E756D),
            ("F0Tg", 0x46305467),
            ("#KEY", 0x234B4559),
            ("flt ", 0x666C7420),
        ]

        for (string, numericValue) in vectors {
            let code = try SMCFourCC(string)
            XCTAssertEqual(code.rawValue, numericValue)
            XCTAssertEqual(code.stringValue, string)
            XCTAssertEqual(code.description, string)
            XCTAssertEqual(try SMCFourCC(rawValue: numericValue), code)
        }
    }

    func testConstructsFromExactlyFourPrintableASCIIBytes() throws {
        XCTAssertEqual(
            try SMCFourCC(bytes: [0x46, 0x4E, 0x75, 0x6D]),
            try SMCFourCC("FNum")
        )
        XCTAssertThrowsError(try SMCFourCC(bytes: [0x46, 0x4E, 0x75])) { error in
            XCTAssertEqual(error as? SMCFourCCError, .invalidByteCount(3))
        }
        XCTAssertThrowsError(try SMCFourCC(bytes: [0x46, 0xFF, 0x75, 0x6D])) { error in
            XCTAssertEqual(error as? SMCFourCCError, .nonASCII)
        }
    }

    func testRejectsInvalidFourCCStringsWithTypedErrors() throws {
        let invalidLengths = ["", "ABC", "ABCDE"]
        for value in invalidLengths {
            XCTAssertThrowsError(try SMCFourCC(value)) { error in
                XCTAssertEqual(error as? SMCFourCCError, .invalidByteCount(Array(value.utf8).count))
            }
        }

        XCTAssertThrowsError(try SMCFourCC("éAB")) { error in
            XCTAssertEqual(error as? SMCFourCCError, .nonASCII)
        }
        XCTAssertThrowsError(try SMCFourCC("A\nBC")) { error in
            XCTAssertEqual(error as? SMCFourCCError, .nonPrintable(byte: 0x0A, index: 1))
        }
        XCTAssertThrowsError(try SMCFourCC("ABC\u{7F}")) { error in
            XCTAssertEqual(error as? SMCFourCCError, .nonPrintable(byte: 0x7F, index: 3))
        }
        XCTAssertThrowsError(try SMCFourCC(rawValue: 0x00414243)) { error in
            XCTAssertEqual(error as? SMCFourCCError, .nonPrintable(byte: 0x00, index: 0))
        }
    }

    func testFourCCIsHashableAndSendable() throws {
        let value = try SMCFourCC("FNum")
        XCTAssertEqual(Set([value, value]).count, 1)
        requireSendable(value)
    }
}

final class SMCKeyDataTests: XCTestCase {
    func testEncodingUsesExactlyEightyBytesAndCorrectNativeScalarOffsets() throws {
        var value = try SMCKeyData(
            key: SMCFourCC("FNum"),
            version: [1, 2, 3, 4, 0x34, 0x12],
            pLimit: Array(0x10...0x1F),
            keyInfo: SMCKeyInfo(
                dataSize: 32,
                dataType: SMCFourCC("ui8 "),
                attributes: 0xA5
            ),
            result: 0x81,
            status: 0x82,
            command: .getKeyInfo,
            data32: 0x55667788,
            payload: [0xAA, 0xBB, 0xCC]
        )
        value.commandByte = 0x09

        let bytes = try value.encode()

        XCTAssertEqual(bytes.count, 80)
        // Canonical FourCC 0x464E756D is serialized as native little-endian UInt32.
        XCTAssertEqual(Array(bytes[0..<4]), [0x6D, 0x75, 0x4E, 0x46])
        XCTAssertEqual(Array(bytes[4..<10]), [1, 2, 3, 4, 0x34, 0x12])
        XCTAssertEqual(Array(bytes[10..<12]), [0, 0])
        XCTAssertEqual(Array(bytes[12..<28]), Array(0x10...0x1F))
        XCTAssertEqual(Array(bytes[28..<32]), [0x20, 0x00, 0x00, 0x00])
        XCTAssertEqual(Array(bytes[32..<36]), [0x20, 0x38, 0x69, 0x75])
        XCTAssertEqual(bytes[36], 0xA5)
        XCTAssertEqual(bytes[37], 0)
        XCTAssertEqual(Array(bytes[38..<40]), [0, 0])
        XCTAssertEqual(bytes[40], 0x81)
        XCTAssertEqual(bytes[41], 0x82)
        XCTAssertEqual(bytes[42], 0x09)
        XCTAssertEqual(bytes[43], 0)
        XCTAssertEqual(Array(bytes[44..<48]), [0x88, 0x77, 0x66, 0x55])
        XCTAssertEqual(Array(bytes[48..<51]), [0xAA, 0xBB, 0xCC])
        XCTAssertEqual(Array(bytes[51..<80]), Array(repeating: 0, count: 29))
    }

    func testResultAndCommandRegressionOffsetsAreFortyAndFortyTwo() throws {
        let value = try SMCKeyData(
            key: SMCFourCC("FNum"),
            result: 0x84,
            status: 0x55,
            command: .readBytes
        )

        let bytes = try value.encode()

        XCTAssertEqual(bytes[40], 0x84)
        XCTAssertEqual(bytes[41], 0x55)
        XCTAssertEqual(bytes[42], 5)
        XCTAssertEqual(bytes[37...39], [0, 0, 0])
        XCTAssertEqual(bytes[43], 0)
    }

    func testDecodeEncodeRoundTripPreservesDefinedFields() throws {
        let original = try SMCKeyData(
            key: SMCFourCC("F0Tg"),
            version: [9, 8, 7, 6, 5, 4],
            pLimit: Array(1...16),
            keyInfo: SMCKeyInfo(
                dataSize: 32,
                dataType: SMCFourCC("flt "),
                attributes: 0xFE
            ),
            result: 0x12,
            status: 0x34,
            commandByte: 0xAB,
            data32: 0x89ABCDEF,
            payload: Array(0..<32)
        )

        let encoded = try original.encode()
        let decoded = try SMCKeyData.decode(encoded)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(try decoded.encode(), encoded)
        requireSendable(decoded)
    }

    func testEmptyAndShortPayloadsCanonicalizeAndRoundTripAsFixedBuffers() throws {
        let key = try SMCFourCC("F0Tg")

        for logicalPayload: [UInt8] in [[], [0xAA, 0xBB, 0xCC]] {
            let original = try SMCKeyData(key: key, payload: logicalPayload)

            XCTAssertEqual(original.payload.count, 32)
            XCTAssertEqual(Array(original.payload.prefix(logicalPayload.count)), logicalPayload)
            XCTAssertEqual(
                Array(original.payload.dropFirst(logicalPayload.count)),
                Array(repeating: 0, count: 32 - logicalPayload.count)
            )
            XCTAssertEqual(try SMCKeyData.decode(original.encode()), original)
        }
    }

    func testConstructionRejectsDataSizeLargerThanWirePayload() throws {
        let info = SMCKeyInfo(dataSize: 33, dataType: try SMCFourCC("ch8*"))

        XCTAssertThrowsError(try SMCKeyData(key: SMCFourCC("F0Tg"), keyInfo: info)) { error in
            XCTAssertEqual(error as? SMCKeyDataError, .dataSizeTooLarge(maximum: 32, actual: 33))
        }
    }

    func testEncodeRejectsMutatedDataSizeLargerThanWirePayload() throws {
        var value = try SMCKeyData(key: SMCFourCC("F0Tg"))
        value.keyInfo.dataSize = 33

        XCTAssertThrowsError(try value.encode()) { error in
            XCTAssertEqual(error as? SMCKeyDataError, .dataSizeTooLarge(maximum: 32, actual: 33))
        }
    }

    func testDecodeRejectsExactWireImageWithOversizedDataSize() {
        var bytes = Array(repeating: UInt8(0), count: 80)
        bytes[28] = 33

        XCTAssertThrowsError(try SMCKeyData.decode(bytes)) { error in
            XCTAssertEqual(error as? SMCKeyDataError, .dataSizeTooLarge(maximum: 32, actual: 33))
        }
    }

    func testFNumKeyInfoAndReadRequestFixtures() throws {
        let key = try SMCFourCC("FNum")
        let keyInfoRequest = try SMCKeyData.keyInfoRequest(key: key)
        XCTAssertEqual(keyInfoRequest.payload, Array(repeating: 0, count: 32))
        let keyInfoBytes = try keyInfoRequest.encode()
        XCTAssertEqual(keyInfoBytes[42], 9)
        XCTAssertEqual(Array(keyInfoBytes[0..<4]), [0x6D, 0x75, 0x4E, 0x46])
        XCTAssertEqual(keyInfoBytes.enumerated().filter { ![0, 1, 2, 3, 42].contains($0.offset) }.map(\.element), Array(repeating: 0, count: 75))

        let info = SMCKeyInfo(dataSize: 1, dataType: try SMCFourCC("ui8 "), attributes: 0x80)
        let readRequest = try SMCKeyData.readRequest(key: key, keyInfo: info)
        XCTAssertEqual(readRequest.payload, Array(repeating: 0, count: 32))
        let readBytes = try readRequest.encode()
        XCTAssertEqual(readBytes[42], 5)
        XCTAssertEqual(Array(readBytes[28..<32]), [1, 0, 0, 0])
        XCTAssertEqual(Array(readBytes[32..<36]), [0x20, 0x38, 0x69, 0x75])
        XCTAssertEqual(readBytes[36], 0x80)
    }

    func testGetKeyFromIndexFixtureUsesCommandEightAndNativeIndex() throws {
        let request = try SMCKeyData.getKeyFromIndexRequest(1_007)
        XCTAssertEqual(request.payload, Array(repeating: 0, count: 32))
        let bytes = try request.encode()

        XCTAssertEqual(bytes[42], 8)
        XCTAssertEqual(Array(bytes[44..<48]), [0xEF, 0x03, 0x00, 0x00])
        XCTAssertEqual(bytes.enumerated().filter { ![42, 44, 45].contains($0.offset) }.map(\.element), Array(repeating: 0, count: 77))
    }

    func testWriteRequestIncludesPayloadAndZerosUnusedBytes() throws {
        let key = try SMCFourCC("F0Md")
        let info = SMCKeyInfo(dataSize: 1, dataType: try SMCFourCC("ui8 "), attributes: 0)
        let request = try SMCKeyData.writeRequest(key: key, keyInfo: info, payload: [1])
        let bytes = try request.encode()

        XCTAssertEqual(bytes[42], 6)
        XCTAssertEqual(request.payload.count, 32)
        XCTAssertEqual(request.payload, [1] + Array(repeating: 0, count: 31))
        XCTAssertEqual(bytes[48], 1)
        XCTAssertEqual(Array(bytes[49..<80]), Array(repeating: 0, count: 31))
    }

    func testWriteRequestRequiresLogicalPayloadToMatchReportedDataSize() throws {
        let key = try SMCFourCC("F0Md")
        let info = SMCKeyInfo(dataSize: 1, dataType: try SMCFourCC("ui8 "))

        XCTAssertThrowsError(try SMCKeyData.writeRequest(key: key, keyInfo: info, payload: [])) { error in
            XCTAssertEqual(error as? SMCKeyDataError, .payloadSizeMismatch(reported: 1, logical: 0))
        }
        XCTAssertThrowsError(try SMCKeyData.writeRequest(key: key, keyInfo: info, payload: [1, 2])) { error in
            XCTAssertEqual(error as? SMCKeyDataError, .payloadSizeMismatch(reported: 1, logical: 2))
        }

        let request = try SMCKeyData.writeRequest(key: key, keyInfo: info, payload: [1])
        XCTAssertEqual(request.payload, [1] + Array(repeating: 0, count: 31))
    }

    func testRejectsMalformedWireLengthAndOversizedPayload() throws {
        for count in [0, 79, 81] {
            XCTAssertThrowsError(try SMCKeyData.decode(Array(repeating: 0, count: count))) { error in
                XCTAssertEqual(error as? SMCKeyDataError, .invalidWireLength(expected: 80, actual: count))
            }
        }

        XCTAssertThrowsError(
            try SMCKeyData(key: SMCFourCC("F0Tg"), payload: Array(repeating: 1, count: 33))
        ) { error in
            XCTAssertEqual(error as? SMCKeyDataError, .payloadTooLarge(maximum: 32, actual: 33))
        }

        var value = try SMCKeyData(key: SMCFourCC("F0Tg"))
        value.payload = Array(repeating: 1, count: 33)
        XCTAssertThrowsError(try value.encode()) { error in
            XCTAssertEqual(error as? SMCKeyDataError, .payloadTooLarge(maximum: 32, actual: 33))
        }
    }

    func testRejectsInvalidFixedFieldLengths() throws {
        XCTAssertThrowsError(
            try SMCKeyData(key: SMCFourCC("FNum"), version: [1, 2, 3])
        ) { error in
            XCTAssertEqual(error as? SMCKeyDataError, .invalidFieldLength(field: "version", expected: 6, actual: 3))
        }
        XCTAssertThrowsError(
            try SMCKeyData(key: SMCFourCC("FNum"), pLimit: [1])
        ) { error in
            XCTAssertEqual(error as? SMCKeyDataError, .invalidFieldLength(field: "pLimit", expected: 16, actual: 1))
        }
    }

    func testProtocolConstantsMatchProvenAppleSMCContract() {
        XCTAssertEqual(AppleSMCProtocol.ioConnectSelector, 2)
        XCTAssertEqual(SMCCommand.readBytes.rawValue, 5)
        XCTAssertEqual(SMCCommand.writeBytes.rawValue, 6)
        XCTAssertEqual(SMCCommand.getKeyFromIndex.rawValue, 8)
        XCTAssertEqual(SMCCommand.getKeyInfo.rawValue, 9)
    }
}

private func requireSendable<T: Sendable>(_: T) {}
