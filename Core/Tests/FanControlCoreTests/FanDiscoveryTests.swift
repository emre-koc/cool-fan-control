import XCTest
@testable import FanControlCore

final class FanDiscoveryTests: XCTestCase {
    func testDiscoversRealM1FanVectorInDeterministicKeyOrder() async throws {
        let reader = FanReaderFake(values: try makeValues([
            ("FNum", "ui8 ", [1]),
            ("F0Ac", "flt ", [0x9A, 0x19, 0xD4, 0x44]),
            ("F0Mn", "flt ", [0x00, 0x80, 0xD4, 0x44]),
            ("F0Mx", "flt ", [0x00, 0x98, 0x8C, 0x45]),
            ("F0Md", "ui8 ", [0]),
            ("F0Tg", "flt ", [0x00, 0x80, 0xD4, 0x44]),
        ]))

        let snapshot = try await FanDiscovery(reader: reader).snapshot()

        XCTAssertEqual(snapshot, FanSnapshot(fans: [
            FanInfo(index: 0, minimumRPM: 1_700, maximumRPM: 4_499,
                    currentRPM: Double(Float(1_696.8)), mode: .automatic,
                    targetRPM: 1_700),
        ]))
        let requestedKeys = await reader.requestedKeys()
        XCTAssertEqual(requestedKeys, ["FNum", "F0Ac", "F0Mn", "F0Mx", "F0Md", "F0Tg"])
    }

    func testCountTwoConstructsExactKeysAndDecodesMixedRPMTypesIndependently() async throws {
        let reader = FanReaderFake(values: try makeValues([
            ("FNum", "ui8 ", [2]),
            ("F0Ac", "flt ", floatBytes(2_000)), ("F0Mn", "fpe2", fpe2Bytes(1_500)),
            ("F0Mx", "flt ", floatBytes(4_500)), ("F0Md", "ui8 ", [1]),
            ("F0Tg", "fpe2", fpe2Bytes(2_500)),
            ("F1Ac", "fpe2", fpe2Bytes(2_100)), ("F1Mn", "flt ", floatBytes(1_600)),
            ("F1Mx", "fpe2", fpe2Bytes(4_000)), ("F1Md", "ui8 ", [0]),
            ("F1Tg", "flt ", floatBytes(2_200)),
        ]))

        let snapshot = try await FanDiscovery(reader: reader).snapshot()

        XCTAssertEqual(snapshot.fans, [
            FanInfo(index: 0, minimumRPM: 1_500, maximumRPM: 4_500, currentRPM: 2_000, mode: .manual, targetRPM: 2_500),
            FanInfo(index: 1, minimumRPM: 1_600, maximumRPM: 4_000, currentRPM: 2_100, mode: .automatic, targetRPM: 2_200),
        ])
        let requestedKeys = await reader.requestedKeys()
        XCTAssertEqual(requestedKeys, [
            "FNum", "F0Ac", "F0Mn", "F0Mx", "F0Md", "F0Tg",
            "F1Ac", "F1Mn", "F1Mx", "F1Md", "F1Tg",
        ])
    }

    func testFanlessReturnsEmptyAndReadsOnlyFNum() async throws {
        let reader = FanReaderFake(values: try makeValues([("FNum", "ui8 ", [0])]))
        let snapshot = try await FanDiscovery(reader: reader).snapshot()
        let requestedKeys = await reader.requestedKeys()
        XCTAssertEqual(snapshot, FanSnapshot(fans: []))
        XCTAssertEqual(requestedKeys, ["FNum"])
    }

    func testWrongFNumMetadataIsTyped() async throws {
        for (type, bytes, expected): (String, [UInt8], FanDiscoveryError) in [
            ("ui16", [0, 1], .invalidFanCountMetadata(actualType: "ui16", actualSize: 2)),
            ("ui8 ", [0, 1], .invalidFanCountMetadata(actualType: "ui8 ", actualSize: 2)),
        ] {
            let reader = FanReaderFake(values: try makeValues([("FNum", type, bytes)]))
            await assertDiscoveryError(reader, expected)
        }
    }

    func testUnsupportedFanCountFailsBeforePerFanReads() async throws {
        let reader = FanReaderFake(values: try makeValues([("FNum", "ui8 ", [11])]))
        await assertDiscoveryError(reader, .unsupportedFanCount(11))
        let requestedKeys = await reader.requestedKeys()
        XCTAssertEqual(requestedKeys, ["FNum"])
    }

    func testMaximumRepresentableCountUsesDecimalIndexNine() async throws {
        var entries: [(String, String, [UInt8])] = [("FNum", "ui8 ", [10])]
        for index in 0...9 {
            entries += [
                ("F\(index)Ac", "fpe2", fpe2Bytes(2_000)), ("F\(index)Mn", "fpe2", fpe2Bytes(1_000)),
                ("F\(index)Mx", "fpe2", fpe2Bytes(4_000)), ("F\(index)Md", "ui8 ", [0]),
                ("F\(index)Tg", "fpe2", fpe2Bytes(2_000)),
            ]
        }
        let reader = FanReaderFake(values: try makeValues(entries))
        let snapshot = try await FanDiscovery(reader: reader).snapshot()
        XCTAssertEqual(snapshot.fans.count, 10)
        XCTAssertEqual(snapshot.fans.last?.index, 9)
        let requestedKeys = await reader.requestedKeys()
        XCTAssertEqual(Array(requestedKeys.suffix(5)), ["F9Ac", "F9Mn", "F9Mx", "F9Md", "F9Tg"])
    }

    func testRPMRejectsWrongTypeAndWrongSizeWithKeyContext() async throws {
        for (type, bytes, error): (String, [UInt8], FanDiscoveryError) in [
            ("ui16", [0x07, 0xD0], .invalidRPMMetadata(index: 0, key: try SMCFourCC("F0Ac"), actualType: "ui16", actualSize: 2)),
            ("flt ", [0, 0], .invalidRPMMetadata(index: 0, key: try SMCFourCC("F0Ac"), actualType: "flt ", actualSize: 2)),
            ("fpe2", [0, 0, 0, 0], .invalidRPMMetadata(index: 0, key: try SMCFourCC("F0Ac"), actualType: "fpe2", actualSize: 4)),
        ] {
            var map = try validFanValues()
            map[try SMCFourCC("F0Ac")] = try makeValue("F0Ac", type, bytes)
            await assertDiscoveryError(FanReaderFake(values: map), error)
        }
    }

    func testRPMMalformedNaNAndInfinityAreTypedDecodeFailures() async throws {
        for bytes in [[UInt8](arrayLiteral: 0, 0, 0xC0, 0x7F), [0, 0, 0x80, 0x7F]] {
            var map = try validFanValues()
            map[try SMCFourCC("F0Ac")] = try makeValue("F0Ac", "flt ", bytes)
            await assertDiscoveryError(
                FanReaderFake(values: map),
                .rpmDecodeFailed(index: 0, key: try SMCFourCC("F0Ac"), cause: .nonFiniteFloat)
            )
        }
    }

    func testNegativeRPMIsRejectedButCurrentSlightlyBelowMinimumIsAccepted() async throws {
        var negative = try validFanValues()
        negative[try SMCFourCC("F0Tg")] = try makeValue("F0Tg", "flt ", floatBytes(-1))
        await assertDiscoveryError(FanReaderFake(values: negative), .negativeRPM(index: 0, key: try SMCFourCC("F0Tg"), value: -1))

        var transient = try validFanValues()
        transient[try SMCFourCC("F0Ac")] = try makeValue("F0Ac", "flt ", floatBytes(1_696.8))
        let fan = try await FanDiscovery(reader: FanReaderFake(values: transient)).snapshot().fans[0]
        XCTAssertLessThan(fan.currentRPM, fan.minimumRPM)
    }

    func testMinimumGreaterThanMaximumIsRejected() async throws {
        var map = try validFanValues()
        map[try SMCFourCC("F0Mn")] = try makeValue("F0Mn", "flt ", floatBytes(4_501))
        await assertDiscoveryError(FanReaderFake(values: map), .invalidRPMRange(index: 0, minimum: 4_501, maximum: 4_500))
    }

    func testModeRequiresUi8SizeOneAndPreservesUnknownByte() async throws {
        var wrong = try validFanValues()
        wrong[try SMCFourCC("F0Md")] = try makeValue("F0Md", "ui16", [0, 1])
        await assertDiscoveryError(
            FanReaderFake(values: wrong),
            .invalidModeMetadata(index: 0, key: try SMCFourCC("F0Md"), actualType: "ui16", actualSize: 2)
        )

        var unknown = try validFanValues()
        unknown[try SMCFourCC("F0Md")] = try makeValue("F0Md", "ui8 ", [0xA5])
        let mode = try await FanDiscovery(reader: FanReaderFake(values: unknown)).snapshot().fans[0].mode
        XCTAssertEqual(mode, .unknown(0xA5))
    }

    func testReadFailureHasFanAndKeyContextAndProducesNoPartialSnapshot() async throws {
        let failingKey = try SMCFourCC("F1Mn")
        let reader = FanReaderFake(values: try validTwoFanValues(), failureKey: failingKey)
        do {
            _ = try await FanDiscovery(reader: reader).snapshot()
            XCTFail("Expected failure")
        } catch let error as FanDiscoveryReadError {
            XCTAssertEqual(error.index, 1)
            XCTAssertEqual(error.key, failingKey)
            XCTAssertTrue(error.underlyingError is FakeReadError)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let calls = await reader.requestedKeys()
        XCTAssertEqual(calls.last, "F1Mn")
    }

    func testFNumReadFailureHasNilFanContext() async throws {
        let key = try SMCFourCC("FNum")
        do {
            _ = try await FanDiscovery(reader: FanReaderFake(values: [:], failureKey: key)).snapshot()
            XCTFail("Expected failure")
        } catch let error as FanDiscoveryReadError {
            XCTAssertNil(error.index)
            XCTAssertEqual(error.key, key)
        }
    }

    func testPublicModelsAndDiscoveryAreSendable() throws {
        requireSendable(FanControlMode.unknown(2))
        requireSendable(FanInfo(index: 0, minimumRPM: 1, maximumRPM: 2, currentRPM: 1, mode: .automatic, targetRPM: 1))
        requireSendable(FanSnapshot(fans: []))
        requireSendable(FanDiscovery(reader: FanReaderFake(values: [:])))
        let discoverer: any FanDiscovering = FanDiscovery(reader: FanReaderFake(values: [:]))
        requireSendable(discoverer)
    }
}

private enum FakeReadError: Error { case failed }

private actor FanReaderFake: SMCReading {
    private let values: [SMCFourCC: SMCValue]
    private let failureKey: SMCFourCC?
    private var calls: [String] = []

    init(values: [SMCFourCC: SMCValue], failureKey: SMCFourCC? = nil) {
        self.values = values
        self.failureKey = failureKey
    }

    func read(_ key: SMCFourCC) async throws -> SMCValue {
        calls.append(key.stringValue)
        if key == failureKey { throw FakeReadError.failed }
        guard let value = values[key] else { throw FakeReadError.failed }
        return value
    }

    func key(at index: UInt32) async throws -> SMCFourCC { throw FakeReadError.failed }
    func requestedKeys() -> [String] { calls }
}

private func makeValue(_ key: String, _ type: String, _ bytes: [UInt8]) throws -> SMCValue {
    try SMCValue(key: SMCFourCC(key), dataType: SMCFourCC(type), dataSize: UInt32(bytes.count), attributes: 0, bytes: bytes)
}

private func makeValues(_ entries: [(String, String, [UInt8])]) throws -> [SMCFourCC: SMCValue] {
    try Dictionary(uniqueKeysWithValues: entries.map { entry in
        let value = try makeValue(entry.0, entry.1, entry.2)
        return (value.key, value)
    })
}

private func validFanValues() throws -> [SMCFourCC: SMCValue] {
    try makeValues([
        ("FNum", "ui8 ", [1]), ("F0Ac", "flt ", floatBytes(2_000)),
        ("F0Mn", "flt ", floatBytes(1_700)), ("F0Mx", "flt ", floatBytes(4_500)),
        ("F0Md", "ui8 ", [0]), ("F0Tg", "flt ", floatBytes(1_700)),
    ])
}

private func validTwoFanValues() throws -> [SMCFourCC: SMCValue] {
    var map = try validFanValues()
    map[try SMCFourCC("FNum")] = try makeValue("FNum", "ui8 ", [2])
    for suffix in ["Ac", "Mn", "Mx", "Tg"] {
        map[try SMCFourCC("F1\(suffix)")] = try makeValue("F1\(suffix)", "flt ", floatBytes(suffix == "Mx" ? 4_500 : 1_700))
    }
    map[try SMCFourCC("F1Md")] = try makeValue("F1Md", "ui8 ", [0])
    return map
}

private func floatBytes(_ value: Double) -> [UInt8] {
    let bits = Float(value).bitPattern
    return [UInt8(truncatingIfNeeded: bits), UInt8(truncatingIfNeeded: bits >> 8), UInt8(truncatingIfNeeded: bits >> 16), UInt8(truncatingIfNeeded: bits >> 24)]
}

private func fpe2Bytes(_ value: Double) -> [UInt8] {
    let raw = UInt16(value * 4)
    return [UInt8(truncatingIfNeeded: raw >> 8), UInt8(truncatingIfNeeded: raw)]
}

private func assertDiscoveryError(_ reader: FanReaderFake, _ expected: FanDiscoveryError, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await FanDiscovery(reader: reader).snapshot()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? FanDiscoveryError, expected, file: file, line: line)
    }
}

private func requireSendable<T: Sendable>(_: T) {}
