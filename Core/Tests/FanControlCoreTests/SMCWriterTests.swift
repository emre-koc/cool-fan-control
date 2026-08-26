import XCTest
@testable import FanControlCore

/// Strict-TDD contract for the SMC write executor: pure request building
/// (`FanWriteRequestBuilder`) and the `SMCWriter` actor that verifies live
/// metadata before every write and applies manual/automatic commands through
/// a write seam that is deliberately distinct from the read-only executor.
///
/// Policy pinned here:
/// - Manual writes never clamp: an out-of-live-bounds target is a typed error.
/// - Manual writes are refused when the live mode byte is neither 0 nor 1.
/// - A manual sequence is [F{idx}Md=1, F{idx}Tg=encoded]; automatic is
///   [F{idx}Md=0] only. FNum==0 → never a write (typed error for a non-empty
///   batch; restore with zero fans is a no-op).
/// - If Md lands but Tg fails, the writer surfaces `.partialWrite` and the
///   caller must restore automatic control.
final class SMCWriterTests: XCTestCase {
    // MARK: - Pure request building

    func testManualFltRequestBuildsModeOneAndEncodedTarget() throws {
        let requests = try FanWriteRequestBuilder.requests(
            for: try manualCommand(),
            fanCount: 1,
            liveMinimumRPM: 1700,
            liveMaximumRPM: 4499,
            liveModeByte: 1,
            targetDataType: try SMCFourCC("flt "),
            targetDataSize: 4
        )
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map { $0.command }, [.writeBytes, .writeBytes])

        let modeRequest = requests[0]
        XCTAssertEqual(modeRequest.keyFourCC, try SMCFourCC("F0Md"))
        XCTAssertEqual(modeRequest.keyInfo, SMCKeyInfo(dataSize: 1, dataType: try SMCFourCC("ui8 ")))
        XCTAssertEqual(Array(modeRequest.payload.prefix(1)), [1])

        let targetRequest = requests[1]
        XCTAssertEqual(targetRequest.keyFourCC, try SMCFourCC("F0Tg"))
        XCTAssertEqual(targetRequest.keyInfo, SMCKeyInfo(dataSize: 4, dataType: try SMCFourCC("flt ")))
        // 2500.0 as IEEE-754 float is 0x451C4000, serialized little-endian.
        XCTAssertEqual(Array(targetRequest.payload.prefix(4)), [0x00, 0x40, 0x1C, 0x45])
    }

    func testManualFpe2RequestEncodesFixedPoint() throws {
        let requests = try FanWriteRequestBuilder.requests(
            for: try manualCommand(targetRPM: 2000),
            fanCount: 1,
            liveMinimumRPM: 1700,
            liveMaximumRPM: 4499,
            liveModeByte: 0,
            targetDataType: try SMCFourCC("fpe2"),
            targetDataSize: 2
        )
        XCTAssertEqual(requests.count, 2)
        let targetRequest = requests[1]
        XCTAssertEqual(targetRequest.keyFourCC, try SMCFourCC("F0Tg"))
        XCTAssertEqual(targetRequest.keyInfo, SMCKeyInfo(dataSize: 2, dataType: try SMCFourCC("fpe2")))
        // 2000 RPM in fpe2 is u16/4: 2000 * 4 = 8000 = 0x1F40 big-endian.
        XCTAssertEqual(Array(targetRequest.payload.prefix(2)), [0x1F, 0x40])
    }

    func testManualTargetAtExactLiveBoundsIsAllowed() throws {
        let minimum = try FanWriteRequestBuilder.requests(
            for: try manualCommand(targetRPM: 1700),
            fanCount: 1,
            liveMinimumRPM: 1700,
            liveMaximumRPM: 4499,
            liveModeByte: 1,
            targetDataType: try SMCFourCC("flt "),
            targetDataSize: 4
        )
        let maximum = try FanWriteRequestBuilder.requests(
            for: try manualCommand(targetRPM: 4499),
            fanCount: 1,
            liveMinimumRPM: 1700,
            liveMaximumRPM: 4499,
            liveModeByte: 1,
            targetDataType: try SMCFourCC("flt "),
            targetDataSize: 4
        )
        XCTAssertEqual(minimum.count, 2)
        XCTAssertEqual(maximum.count, 2)
    }

    func testAutomaticBuildsOnlyModeZeroAndIgnoresMetadata() throws {
        let requests = try FanWriteRequestBuilder.requests(
            for: try automaticCommand(),
            fanCount: 1,
            liveMinimumRPM: 1700,
            liveMaximumRPM: 4499,
            liveModeByte: 7, // garbage live mode must not matter for automatic
            targetDataType: try SMCFourCC("ui16"),
            targetDataSize: 2
        )
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].keyFourCC, try SMCFourCC("F0Md"))
        XCTAssertEqual(requests[0].command, .writeBytes)
        XCTAssertEqual(requests[0].keyInfo, SMCKeyInfo(dataSize: 1, dataType: try SMCFourCC("ui8 ")))
        XCTAssertEqual(Array(requests[0].payload.prefix(1)), [0])
    }

    func testOutOfBoundsTargetIsTypedErrorNeverClamped() throws {
        for target in [1699.0, 4500.0, 5000.0] {
            do {
                _ = try FanWriteRequestBuilder.requests(
                    // Construction bounds (1000...5000) admit every target;
                    // only the LIVE bounds (1700...4499) reject below/above.
                    for: try manualCommand(targetRPM: target, minimumRPM: 1000, maximumRPM: 5000),
                    fanCount: 1,
                    liveMinimumRPM: 1700,
                    liveMaximumRPM: 4499,
                    liveModeByte: 1,
                    targetDataType: try SMCFourCC("flt "),
                    targetDataSize: 4
                )
                XCTFail("Expected targetOutOfBounds for \(target)")
            } catch {
                XCTAssertEqual(
                    error as? SMCWriterError,
                    .targetOutOfBounds(minimumRPM: 1700, maximumRPM: 4499, targetRPM: target)
                )
            }
        }
    }

    func testFanCountZeroRefusesAnyCommand() throws {
        for command in [try manualCommand(), try automaticCommand()] {
            do {
                _ = try FanWriteRequestBuilder.requests(
                    for: command,
                    fanCount: 0,
                    liveMinimumRPM: 1700,
                    liveMaximumRPM: 4499,
                    liveModeByte: 1,
                    targetDataType: try SMCFourCC("flt "),
                    targetDataSize: 4
                )
                XCTFail("Expected fanCountZero")
            } catch {
                XCTAssertEqual(error as? SMCWriterError, .fanCountZero)
            }
        }
    }

    func testFanIndexOutOfRangeIsTypedError() throws {
        for index in [1, -1] {
            do {
                _ = try FanWriteRequestBuilder.requests(
                    for: try manualCommand(fanIndex: index),
                    fanCount: 1,
                    liveMinimumRPM: 1700,
                    liveMaximumRPM: 4499,
                    liveModeByte: 1,
                    targetDataType: try SMCFourCC("flt "),
                    targetDataSize: 4
                )
                XCTFail("Expected fanIndexOutOfRange for \(index)")
            } catch {
                XCTAssertEqual(error as? SMCWriterError, .fanIndexOutOfRange(index: index, fanCount: 1))
            }
        }
    }

    func testUnknownLiveModeByteRefusesManualWrite() throws {
        for byte: UInt8? in [2, 0xFF, nil] {
            do {
                _ = try FanWriteRequestBuilder.requests(
                    for: try manualCommand(),
                    fanCount: 1,
                    liveMinimumRPM: 1700,
                    liveMaximumRPM: 4499,
                    liveModeByte: byte,
                    targetDataType: try SMCFourCC("flt "),
                    targetDataSize: 4
                )
                XCTFail("Expected unknownMode for \(String(describing: byte))")
            } catch {
                XCTAssertEqual(
                    error as? SMCWriterError,
                    .unknownMode(index: 0, byte: byte ?? 0xFF)
                )
            }
        }
    }

    func testKnownLiveModeBytesAreAccepted() throws {
        for byte: UInt8 in [0, 1] {
            let requests = try FanWriteRequestBuilder.requests(
                for: try manualCommand(),
                fanCount: 1,
                liveMinimumRPM: 1700,
                liveMaximumRPM: 4499,
                liveModeByte: byte,
                targetDataType: try SMCFourCC("flt "),
                targetDataSize: 4
            )
            XCTAssertEqual(requests.count, 2)
        }
    }

    func testMissingTargetMetadataIsTypedError() throws {
        do {
            _ = try FanWriteRequestBuilder.requests(
                for: try manualCommand(),
                fanCount: 1,
                liveMinimumRPM: 1700,
                liveMaximumRPM: 4499,
                liveModeByte: 1,
                targetDataType: nil,
                targetDataSize: 4
            )
            XCTFail("Expected missingTargetMetadata")
        } catch {
            XCTAssertEqual(error as? SMCWriterError, .missingTargetMetadata(index: 0))
        }
    }

    func testUnsupportedTargetDataTypeIsTypedError() throws {
        let cases: [(SMCFourCC, UInt32)] = [
            (try SMCFourCC("flt "), 2),  // right type, wrong size
            (try SMCFourCC("fpe2"), 4),  // right type, wrong size
            (try SMCFourCC("ui16"), 2),  // RPM keys must be flt or fpe2
            (try SMCFourCC("sp78"), 2),
        ]
        for (type, size) in cases {
            do {
                _ = try FanWriteRequestBuilder.requests(
                    for: try manualCommand(),
                    fanCount: 1,
                    liveMinimumRPM: 1700,
                    liveMaximumRPM: 4499,
                    liveModeByte: 1,
                    targetDataType: type,
                    targetDataSize: size
                )
                XCTFail("Expected unsupportedTargetDataType for \(type)/\(size)")
            } catch {
                XCTAssertEqual(
                    error as? SMCWriterError,
                    .unsupportedTargetDataType(index: 0, type: type, size: size)
                )
            }
        }
    }

    func testModeWriteRequestFactoryProducesRestoreAndManualBytes() throws {
        let restore = try FanWriteRequestBuilder.modeWriteRequest(key: try SMCFourCC("F0Md"), modeByte: 0)
        XCTAssertEqual(restore.keyFourCC, try SMCFourCC("F0Md"))
        XCTAssertEqual(restore.keyInfo, SMCKeyInfo(dataSize: 1, dataType: try SMCFourCC("ui8 ")))
        XCTAssertEqual(Array(restore.payload.prefix(1)), [0])

        let manual = try FanWriteRequestBuilder.modeWriteRequest(key: try SMCFourCC("F1Md"), modeByte: 1)
        XCTAssertEqual(manual.keyFourCC, try SMCFourCC("F1Md"))
        XCTAssertEqual(Array(manual.payload.prefix(1)), [1])
    }

    // MARK: - Writer: exact call sequences

    func testManualApplyExactCallSequence() async throws {
        let (writer, readerExec, writeExec) = try makeStandardWriter()
        try await writer.apply([try manualCommand()])

        let readerCalls = await readerExec.recordedCalls()
        XCTAssertEqual(readerCalls.count, 10)
        let readRequests = try readerCalls.map { try SMCKeyData.decode($0.request) }
        XCTAssertEqual(
            readRequests.compactMap(\.command),
            [.getKeyInfo, .readBytes, .getKeyInfo, .readBytes, .getKeyInfo, .readBytes,
             .getKeyInfo, .readBytes, .getKeyInfo, .readBytes]
        )
        XCTAssertEqual(
            readRequests.map { $0.keyFourCC?.stringValue },
            ["FNum", "FNum", "F0Mn", "F0Mn", "F0Mx", "F0Mx", "F0Md", "F0Md", "F0Tg", "F0Tg"]
        )
        // The read-only executor must never see a write (command 6).
        XCTAssertFalse(readRequests.contains { $0.commandByte == SMCCommand.writeBytes.rawValue })

        let writeCalls = await writeExec.recordedCalls()
        XCTAssertEqual(writeCalls.count, 2)
        XCTAssertEqual(writeCalls.map(\.selector), [2, 2])
        let writeRequests = try writeCalls.map { try SMCKeyData.decode($0.request) }
        XCTAssertEqual(writeRequests.map { $0.command }, [.writeBytes, .writeBytes])
        XCTAssertEqual(writeRequests.map { $0.keyFourCC?.stringValue }, ["F0Md", "F0Tg"])
        XCTAssertEqual(Array(writeRequests[0].payload.prefix(1)), [1])
        XCTAssertEqual(Array(writeRequests[1].payload.prefix(4)), [0x00, 0x40, 0x1C, 0x45])
    }

    func testAutomaticApplyWritesOnlyModeZero() async throws {
        // Automatic reads FNum then F{idx}Md (mode metadata) — not the RPM keys.
        let (writer, readerExec, writeExec) = try makeWriter(readerEntries: entries([
            (try SMCFourCC("FNum"), try ui8Info(), [1]),
            (try SMCFourCC("F0Md"), try ui8Info(), [0]),
        ]))
        try await writer.apply([try automaticCommand()])

        let readRequests = try (await readerExec.recordedCalls()).map { try SMCKeyData.decode($0.request) }
        XCTAssertEqual(
            readRequests.map { $0.keyFourCC?.stringValue },
            ["FNum", "FNum", "F0Md", "F0Md"]
        )

        let writeRequests = try (await writeExec.recordedCalls()).map { try SMCKeyData.decode($0.request) }
        XCTAssertEqual(writeRequests.count, 1)
        XCTAssertEqual(writeRequests[0].keyFourCC, try SMCFourCC("F0Md"))
        XCTAssertEqual(Array(writeRequests[0].payload.prefix(1)), [0])
    }

    func testRestoreAutomaticWritesModeZeroPerFan() async throws {
        // Restore reads FNum then F{idx}Md per fan — no RPM keys, no targets.
        let (writer, readerExec, writeExec) = try makeWriter(readerEntries: entries([
            (try SMCFourCC("FNum"), try ui8Info(), [2]),
            (try SMCFourCC("F0Md"), try ui8Info(), [0]),
            (try SMCFourCC("F1Md"), try ui8Info(), [1]),
        ]))
        try await writer.restoreAutomatic()

        let readRequests = try (await readerExec.recordedCalls()).map { try SMCKeyData.decode($0.request) }
        XCTAssertEqual(
            readRequests.map { $0.keyFourCC?.stringValue },
            ["FNum", "FNum", "F0Md", "F0Md", "F1Md", "F1Md"]
        )

        let writeRequests = try (await writeExec.recordedCalls()).map { try SMCKeyData.decode($0.request) }
        XCTAssertEqual(writeRequests.count, 2)
        XCTAssertEqual(writeRequests.map { $0.keyFourCC?.stringValue }, ["F0Md", "F1Md"])
        XCTAssertEqual(writeRequests.map { Array($0.payload.prefix(1)) }, [[0], [0]])
    }

    func testApplyEmptyBatchIsNoOp() async throws {
        let (writer, readerExec, writeExec) = try makeStandardWriter()
        try await writer.apply([])
        let readerCalls = await readerExec.recordedCalls()
        XCTAssertTrue(readerCalls.isEmpty)
        await assertNoWrites(writeExec)
    }

    func testRestoreAutomaticOnFanlessMachineIsNoOp() async throws {
        let (writer, readerExec, writeExec) = try makeStandardWriter(fanCount: 0)
        try await writer.restoreAutomatic()
        let readerCalls = await readerExec.recordedCalls()
        XCTAssertEqual(readerCalls.count, 2) // FNum only
        await assertNoWrites(writeExec)
    }

    // MARK: - Writer: strict rejection (never write, never clamp)

    func testApplyWithFanCountZeroIsTypedErrorAndNeverWrites() async throws {
        let (writer, _, writeExec) = try makeStandardWriter(fanCount: 0)
        do {
            try await writer.apply([try manualCommand()])
            XCTFail("Expected fanCountZero")
        } catch {
            XCTAssertEqual(error as? SMCWriterError, .fanCountZero)
        }
        await assertNoWrites(writeExec)
    }

    func testApplyWithFanIndexOutOfRangeIsTypedErrorAndNeverWrites() async throws {
        let (writer, _, writeExec) = try makeStandardWriter()
        do {
            try await writer.apply([try manualCommand(fanIndex: 1)])
            XCTFail("Expected fanIndexOutOfRange")
        } catch {
            XCTAssertEqual(error as? SMCWriterError, .fanIndexOutOfRange(index: 1, fanCount: 1))
        }
        await assertNoWrites(writeExec)
    }

    func testLiveOutOfBoundsTargetIsTypedErrorAndNeverClamped() async throws {
        // Construction bounds pass (max 5000) but the live maximum is 4499:
        // the writer must re-verify against live limits and refuse.
        let (writer, _, writeExec) = try makeStandardWriter()
        do {
            try await writer.apply([try manualCommand(targetRPM: 4500, maximumRPM: 5000)])
            XCTFail("Expected targetOutOfBounds")
        } catch {
            XCTAssertEqual(
                error as? SMCWriterError,
                .targetOutOfBounds(minimumRPM: 1700, maximumRPM: 4499, targetRPM: 4500)
            )
        }
        await assertNoWrites(writeExec)
    }

    func testUnknownLiveModeByteRefusesManualWriteAndNeverWrites() async throws {
        let (writer, _, writeExec) = try makeStandardWriter(fan0: .init(
            index: 0, minimumRPM: 1700, maximumRPM: 4499, modeByte: 7,
            rpmType: try SMCFourCC("flt "), rpmSize: 4
        ))
        do {
            try await writer.apply([try manualCommand()])
            XCTFail("Expected unknownMode")
        } catch {
            XCTAssertEqual(error as? SMCWriterError, .unknownMode(index: 0, byte: 7))
        }
        await assertNoWrites(writeExec)
    }

    func testInvalidFanCountMetadataIsTypedError() async throws {
        let (writer, _, writeExec) = try makeWriter(readerEntries: entries([
            (try SMCFourCC("FNum"), SMCKeyInfo(dataSize: 2, dataType: try SMCFourCC("ui16")), [0, 1]),
        ]))
        do {
            try await writer.apply([try manualCommand()])
            XCTFail("Expected invalidFanCountMetadata")
        } catch {
            XCTAssertEqual(
                error as? SMCWriterError,
                .invalidFanCountMetadata(actualType: "ui16", actualSize: 2)
            )
        }
        await assertNoWrites(writeExec)
    }

    func testUnsupportedFanCountIsTypedError() async throws {
        let (writer, _, writeExec) = try makeStandardWriter(fanCount: 11)
        do {
            try await writer.apply([try manualCommand()])
            XCTFail("Expected unsupportedFanCount")
        } catch {
            XCTAssertEqual(error as? SMCWriterError, .unsupportedFanCount(11))
        }
        await assertNoWrites(writeExec)
    }

    func testInvalidRPMMetadataIsTypedError() async throws {
        let (writer, _, writeExec) = try makeWriter(readerEntries: entries([
            (try SMCFourCC("FNum"), try ui8Info(), [1]),
            (try SMCFourCC("F0Mn"), SMCKeyInfo(dataSize: 2, dataType: try SMCFourCC("ui16")), [0, 1]),
        ]))
        do {
            try await writer.apply([try manualCommand()])
            XCTFail("Expected invalidRPMMetadata")
        } catch {
            XCTAssertEqual(
                error as? SMCWriterError,
                .invalidRPMMetadata(index: 0, key: try SMCFourCC("F0Mn"), actualType: "ui16", actualSize: 2)
            )
        }
        await assertNoWrites(writeExec)
    }

    func testNegativeLiveRPMIsTypedError() async throws {
        let (writer, _, writeExec) = try makeWriter(readerEntries: entries([
            (try SMCFourCC("FNum"), try ui8Info(), [1]),
            (try SMCFourCC("F0Mn"), SMCKeyInfo(dataSize: 4, dataType: try SMCFourCC("flt ")), floatPayload(-1)),
        ]))
        do {
            try await writer.apply([try manualCommand()])
            XCTFail("Expected negativeRPM")
        } catch {
            XCTAssertEqual(
                error as? SMCWriterError,
                .negativeRPM(index: 0, key: try SMCFourCC("F0Mn"), value: -1)
            )
        }
        await assertNoWrites(writeExec)
    }

    func testInvalidLiveRPMRangeIsTypedError() async throws {
        let (writer, _, writeExec) = try makeWriter(readerEntries: entries([
            (try SMCFourCC("FNum"), try ui8Info(), [1]),
            (try SMCFourCC("F0Mn"), SMCKeyInfo(dataSize: 4, dataType: try SMCFourCC("flt ")), floatPayload(5000)),
            (try SMCFourCC("F0Mx"), SMCKeyInfo(dataSize: 4, dataType: try SMCFourCC("flt ")), floatPayload(1000)),
        ]))
        do {
            try await writer.apply([try manualCommand()])
            XCTFail("Expected invalidRPMRange")
        } catch {
            XCTAssertEqual(
                error as? SMCWriterError,
                .invalidRPMRange(index: 0, minimum: 5000, maximum: 1000)
            )
        }
        await assertNoWrites(writeExec)
    }

    func testInvalidModeMetadataIsTypedError() async throws {
        let (writer, _, writeExec) = try makeWriter(readerEntries: entries([
            (try SMCFourCC("FNum"), try ui8Info(), [1]),
            (try SMCFourCC("F0Mn"), SMCKeyInfo(dataSize: 4, dataType: try SMCFourCC("flt ")), floatPayload(1700)),
            (try SMCFourCC("F0Mx"), SMCKeyInfo(dataSize: 4, dataType: try SMCFourCC("flt ")), floatPayload(4499)),
            (try SMCFourCC("F0Md"), SMCKeyInfo(dataSize: 2, dataType: try SMCFourCC("ui16")), [0, 0]),
        ]))
        do {
            try await writer.apply([try manualCommand()])
            XCTFail("Expected invalidModeMetadata")
        } catch {
            XCTAssertEqual(
                error as? SMCWriterError,
                .invalidModeMetadata(index: 0, actualType: "ui16", actualSize: 2)
            )
        }
        await assertNoWrites(writeExec)
    }

    func testRestoreValidatesModeMetadataBeforeWriting() async throws {
        let (writer, _, writeExec) = try makeWriter(readerEntries: entries([
            (try SMCFourCC("FNum"), try ui8Info(), [1]),
            (try SMCFourCC("F0Md"), SMCKeyInfo(dataSize: 2, dataType: try SMCFourCC("ui16")), [0, 0]),
        ]))
        do {
            try await writer.restoreAutomatic()
            XCTFail("Expected invalidModeMetadata")
        } catch {
            XCTAssertEqual(
                error as? SMCWriterError,
                .invalidModeMetadata(index: 0, actualType: "ui16", actualSize: 2)
            )
        }
        await assertNoWrites(writeExec)
    }

    // MARK: - Writer: partial writes and transport failures

    func testPartialWriteFailureSurfacesWhenModeLandsButTargetFails() async throws {
        // Call 0 (F0Md=1) succeeds; call 1 (F0Tg) fails → typed partial failure.
        let (writer, _, _) = try makeStandardWriter(writeFailureAtCallIndex: 1)
        do {
            try await writer.apply([try manualCommand()])
            XCTFail("Expected partialWrite")
        } catch {
            guard case SMCWriterError.partialWrite(let index, let key, let description) = error else {
                return XCTFail("Expected partialWrite, got \(error)")
            }
            XCTAssertEqual(index, 0)
            XCTAssertEqual(key, try SMCFourCC("F0Tg"))
            XCTAssertFalse(description.isEmpty)
        }
    }

    func testWriteTransportFailureOnFirstCallPassesThrough() async throws {
        let (writer, _, _) = try makeStandardWriter(writeFailureAtCallIndex: 0)
        do {
            try await writer.apply([try manualCommand()])
            XCTFail("Expected callFailed")
        } catch {
            XCTAssertEqual(error as? SMCTransportError, .callFailed(-1))
        }
    }

    func testReaderTransportFailurePassesThrough() async throws {
        let (writer, _, writeExec) = try makeWriter(
            readerEntries: entries([(try SMCFourCC("FNum"), try ui8Info(), [1])]),
            readerFailKeys: [try SMCFourCC("FNum")]
        )
        do {
            try await writer.apply([try manualCommand()])
            XCTFail("Expected keyNotFound")
        } catch {
            XCTAssertEqual(error as? SMCTransportError, .keyNotFound(try SMCFourCC("FNum")))
        }
        await assertNoWrites(writeExec)
    }

    func testMalformedWriteResponseIsTypedTransportError() async throws {
        let (writer, _, _) = try makeWriter(
            readerEntries: try standardFanEntries(fanCount: 1, fans: [.standard]),
            writeResponseBytes: Array(repeating: 0, count: 79)
        )
        do {
            try await writer.apply([try manualCommand()])
            XCTFail("Expected malformedResponse")
        } catch {
            XCTAssertEqual(error as? SMCTransportError, .malformedResponse(expected: 80, actual: 79))
        }
    }

    // MARK: - Concurrency and Sendable

    func testConcurrentAppliesAreCompleteAndNeverTouchReadExecutorWithWrites() async throws {
        let (writer, readerExec, writeExec) = try makeStandardWriter()
        let command = try manualCommand()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { try await writer.apply([command]) }
            }
            try await group.waitForAll()
        }

        let readerCalls = await readerExec.recordedCalls()
        XCTAssertEqual(readerCalls.count, 20 * 10) // 20 applies × 5 keys × 2 calls (keyInfo + readBytes)
        let readRequests = try readerCalls.map { try SMCKeyData.decode($0.request) }
        XCTAssertFalse(readRequests.contains { $0.commandByte == SMCCommand.writeBytes.rawValue })

        let writeCalls = await writeExec.recordedCalls()
        XCTAssertEqual(writeCalls.count, 40) // 20 applies × [F0Md, F0Tg]
        let writeRequests = try writeCalls.map { try SMCKeyData.decode($0.request) }
        XCTAssertTrue(writeRequests.allSatisfy { $0.command == .writeBytes })
        // The actor suspends at each write, so concurrent applies interleave at
        // the batch level (whole-batch serialization across concurrent callers
        // is the helper milestone's composition concern, per SMCWriter docs).
        // What IS guaranteed per apply: exactly one F0Md and one F0Tg, and a
        // target write never precedes its own mode write (prefix property).
        let keys = writeRequests.map { $0.keyFourCC?.stringValue }
        var modeWritesSeen = 0
        var targetWritesSeen = 0
        for key in keys {
            switch key {
            case "F0Md": modeWritesSeen += 1
            case "F0Tg": targetWritesSeen += 1
            default: break
            }
            XCTAssertGreaterThanOrEqual(
                modeWritesSeen, targetWritesSeen,
                "target write must never precede its own mode write"
            )
        }
        XCTAssertEqual(modeWritesSeen, 20)
        XCTAssertEqual(targetWritesSeen, 20)
    }

    func testTypesAreSendable() throws {
        requireSendable(WatchdogGateConfig())
        requireSendable(WatchdogGate())
        requireSendable(SMCWriterError.fanCountZero)
        requireSendable(try FanWriteRequestBuilder.modeWriteRequest(key: SMCFourCC("F0Md"), modeByte: 0))
        requireSendable(FutureWritingFake())
        requireSendable(FutureWriteExecutorFake())
    }

    func testSMCWriterActorConformsToSMCWritingProtocol() throws {
        let reader = SMCClient(executor: ScriptedReaderExecutor(entries: [:]))
        let writer: any SMCWriting = SMCWriter(
            reader: reader,
            writeExecutor: FutureWriteExecutorFake()
        )
        requireSendable(writer)
    }
}

// MARK: - Test doubles

private struct FanFixture: Sendable {
    let index: UInt8
    let minimumRPM: Double
    let maximumRPM: Double
    let modeByte: UInt8
    let rpmType: SMCFourCC
    let rpmSize: UInt32

    static let standard = FanFixture(
        index: 0, minimumRPM: 1700, maximumRPM: 4499, modeByte: 0,
        rpmType: try! SMCFourCC("flt "), rpmSize: 4
    )
}

/// Key-aware fake: answers each request from a per-key metadata map, exactly
/// like the real driver. Safe under concurrent reads (no script cursor).
private actor ScriptedReaderExecutor: SMCExecuting {
    struct Call: Sendable {
        let selector: UInt32
        let request: [UInt8]
    }

    private let entries: [SMCFourCC: (info: SMCKeyInfo, payload: [UInt8])]
    private let failKeys: Set<SMCFourCC>
    private var calls: [Call] = []

    init(
        entries: [SMCFourCC: (info: SMCKeyInfo, payload: [UInt8])],
        failKeys: Set<SMCFourCC> = []
    ) {
        self.entries = entries
        self.failKeys = failKeys
    }

    func execute(selector: UInt32, request: [UInt8]) async throws -> [UInt8] {
        calls.append(Call(selector: selector, request: request))
        guard let decoded = try? SMCKeyData.decode(request),
              let key = decoded.keyFourCC else {
            throw SMCTransportError.callFailed(-1)
        }
        if failKeys.contains(key) {
            throw SMCTransportError.keyNotFound(key)
        }
        guard let entry = entries[key] else {
            throw SMCTransportError.callFailed(-1)
        }
        switch decoded.command {
        case .getKeyInfo:
            return try SMCKeyData(key: key, keyInfo: entry.info, command: .getKeyInfo).encode()
        case .readBytes:
            return try SMCKeyData(key: key, keyInfo: entry.info, command: .readBytes, payload: entry.payload).encode()
        default:
            throw SMCTransportError.callFailed(-1)
        }
    }

    func recordedCalls() -> [Call] { calls }
}

private actor ScriptedWriteExecutor: WriteExecuting {
    struct Call: Sendable {
        let selector: UInt32
        let request: [UInt8]
    }

    private var calls: [Call] = []
    private let failureAtCallIndex: Int?
    private let fallbackResponseKey: SMCFourCC
    private let responseBytes: [UInt8]
    private let cannedResponse: Bool

    init(
        responseKey: SMCFourCC,
        failureAtCallIndex: Int? = nil,
        responseBytes: [UInt8]? = nil
    ) {
        self.fallbackResponseKey = responseKey
        self.failureAtCallIndex = failureAtCallIndex
        self.cannedResponse = responseBytes != nil
        self.responseBytes = responseBytes ?? (try! SMCKeyData(key: responseKey, command: .writeBytes).encode())
    }

    func execute(selector: UInt32, request: [UInt8]) async throws -> [UInt8] {
        calls.append(Call(selector: selector, request: request))
        if let failureAtCallIndex, calls.count - 1 == failureAtCallIndex {
            throw SMCTransportError.callFailed(-1)
        }
        // Echo the request's own key (realistic driver behavior) unless the
        // test forced a canned response image.
        if !cannedResponse, let key = try? SMCKeyData.decode(request).keyFourCC {
            return try SMCKeyData(key: key, command: .writeBytes).encode()
        }
        return responseBytes
    }

    func recordedCalls() -> [Call] { calls }
}

private struct FutureWritingFake: SMCWriting {
    func apply(_ commands: [FanWriteCommand]) async throws {}
    func restoreAutomatic() async throws {}
}

private struct FutureWriteExecutorFake: WriteExecuting {
    func execute(selector: UInt32, request: [UInt8]) async throws -> [UInt8] {
        try SMCKeyData(key: SMCFourCC("F0Md"), command: .writeBytes).encode()
    }
}


private func assertNoWrites(_ writeExec: ScriptedWriteExecutor) async {
    let calls = await writeExec.recordedCalls()
    XCTAssertTrue(calls.isEmpty)
}

private func requireSendable<T: Sendable>(_: T) {}

// MARK: - Script helpers

private func ui8Info() throws -> SMCKeyInfo {
    SMCKeyInfo(dataSize: 1, dataType: try SMCFourCC("ui8 "))
}

private func floatPayload(_ value: Double) throws -> [UInt8] {
    try SMCCodec.encode(value, dataType: SMCDataType.float.rawValue, expectedSize: 4)
}

private typealias ReaderEntry = (key: SMCFourCC, info: SMCKeyInfo, payload: [UInt8])

private func entries(_ pairs: [ReaderEntry]) -> [SMCFourCC: (info: SMCKeyInfo, payload: [UInt8])] {
    Dictionary(uniqueKeysWithValues: pairs.map { ($0.key, (info: $0.info, payload: $0.payload)) })
}

private func standardFanEntries(
    fanCount: UInt8,
    fans: [FanFixture]
) throws -> [SMCFourCC: (info: SMCKeyInfo, payload: [UInt8])] {
    var result: [SMCFourCC: (info: SMCKeyInfo, payload: [UInt8])] = [
        try SMCFourCC("FNum"): (try ui8Info(), [fanCount])
    ]
    for fan in fans {
        let rpmInfo = SMCKeyInfo(dataSize: fan.rpmSize, dataType: fan.rpmType)
        result[try SMCFourCC("F\(fan.index)Mn")] = (
            rpmInfo,
            try SMCCodec.encode(fan.minimumRPM, dataType: fan.rpmType.stringValue, expectedSize: Int(fan.rpmSize))
        )
        result[try SMCFourCC("F\(fan.index)Mx")] = (
            rpmInfo,
            try SMCCodec.encode(fan.maximumRPM, dataType: fan.rpmType.stringValue, expectedSize: Int(fan.rpmSize))
        )
        result[try SMCFourCC("F\(fan.index)Md")] = (try ui8Info(), [fan.modeByte])
        result[try SMCFourCC("F\(fan.index)Tg")] = (rpmInfo, Array(repeating: 0, count: Int(fan.rpmSize)))
    }
    return result
}

// MARK: - Writer factory

private func makeWriter(
    readerEntries: [SMCFourCC: (info: SMCKeyInfo, payload: [UInt8])],
    readerFailKeys: Set<SMCFourCC> = [],
    writeFailureAtCallIndex: Int? = nil,
    writeResponseBytes: [UInt8]? = nil
) throws -> (SMCWriter, ScriptedReaderExecutor, ScriptedWriteExecutor) {
    let readerExec = ScriptedReaderExecutor(entries: readerEntries, failKeys: readerFailKeys)
    let reader = SMCClient(executor: readerExec)
    let writeExec = ScriptedWriteExecutor(
        responseKey: try SMCFourCC("F0Md"),
        failureAtCallIndex: writeFailureAtCallIndex,
        responseBytes: writeResponseBytes
    )
    return (SMCWriter(reader: reader, writeExecutor: writeExec), readerExec, writeExec)
}

private func makeStandardWriter(
    fanCount: UInt8 = 1,
    fan0: FanFixture = .standard,
    fan1: FanFixture? = nil,
    writeFailureAtCallIndex: Int? = nil
) throws -> (SMCWriter, ScriptedReaderExecutor, ScriptedWriteExecutor) {
    var fans = [fan0]
    if let fan1 { fans.append(fan1) }
    return try makeWriter(
        readerEntries: try standardFanEntries(fanCount: fanCount, fans: fans),
        writeFailureAtCallIndex: writeFailureAtCallIndex
    )
}

private func manualCommand(
    fanIndex: Int = 0,
    targetRPM: Double = 2500,
    minimumRPM: Double = 1700,
    maximumRPM: Double = 4499
) throws -> FanWriteCommand {
    try FanWriteCommand(
        fanIndex: fanIndex,
        mode: .manual,
        targetRPM: targetRPM,
        minimumRPM: minimumRPM,
        maximumRPM: maximumRPM
    )
}

private func automaticCommand(fanIndex: Int = 0) throws -> FanWriteCommand {
    try FanWriteCommand(
        fanIndex: fanIndex,
        mode: .automatic,
        targetRPM: nil,
        minimumRPM: 0,
        maximumRPM: 0
    )
}
