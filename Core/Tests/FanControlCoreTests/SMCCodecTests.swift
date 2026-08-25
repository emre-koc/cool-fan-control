import XCTest
@testable import FanControlCore

final class SMCCodecTests: XCTestCase {
    func testDecodesAppleSiliconFloatRPMHardwareVectors() throws {
        let vectors: [([UInt8], Double)] = [
            ([0x00, 0x80, 0xD4, 0x44], 1_700),
            ([0x00, 0xB0, 0x18, 0x45], 2_443),
            ([0x00, 0x98, 0x8C, 0x45], 4_499),
        ]

        for (bytes, expected) in vectors {
            XCTAssertEqual(
                try SMCCodec.decode(bytes, dataType: "flt ", expectedSize: 4),
                expected
            )
        }
    }

    func testDecodesAppleSiliconFloatTemperatureVectors() throws {
        XCTAssertEqual(
            try SMCCodec.decode([0x00, 0x00, 0x16, 0x42], dataType: "flt ", expectedSize: 4),
            37.5
        )
        XCTAssertEqual(
            try SMCCodec.decode([0x00, 0x80, 0x88, 0x42], dataType: "flt ", expectedSize: 4),
            68.25
        )
    }

    func testEncodesAppleSiliconFloatRPMAsLittleEndianBytes() throws {
        XCTAssertEqual(
            try SMCCodec.encode(1_700, dataType: "flt ", expectedSize: 4),
            [0x00, 0x80, 0xD4, 0x44]
        )
        XCTAssertEqual(
            try SMCCodec.encode(2_443, dataType: "flt ", expectedSize: 4),
            [0x00, 0xB0, 0x18, 0x45]
        )
        XCTAssertEqual(
            try SMCCodec.encode(4_499, dataType: "flt ", expectedSize: 4),
            [0x00, 0x98, 0x8C, 0x45]
        )
    }

    func testFloatRoundTrip() throws {
        let encoded = try SMCCodec.encode(52.125, dataType: "flt ", expectedSize: 4)
        XCTAssertEqual(
            try SMCCodec.decode(encoded, dataType: "flt ", expectedSize: 4),
            52.125
        )
    }

    func testRejectsNonFiniteFloatValuesForEncodingAndDecoding() throws {
        for value in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertThrowsError(
                try SMCCodec.encode(value, dataType: "flt ", expectedSize: 4)
            ) { error in
                XCTAssertEqual(error as? SMCCodecError, .nonFiniteFloat)
            }
        }

        XCTAssertThrowsError(
            try SMCCodec.decode([0x00, 0x00, 0xC0, 0x7F], dataType: "flt ", expectedSize: 4)
        ) { error in
            XCTAssertEqual(error as? SMCCodecError, .nonFiniteFloat)
        }
    }

    func testRejectsFiniteDoubleThatOverflowsFloatEncoding() throws {
        let value = Double.greatestFiniteMagnitude

        XCTAssertThrowsError(
            try SMCCodec.encode(value, dataType: "flt ", expectedSize: 4)
        ) { error in
            XCTAssertEqual(
                error as? SMCCodecError,
                .valueOutOfRange(
                    dataType: "flt ",
                    value: value,
                    minimum: -Double(Float.greatestFiniteMagnitude),
                    maximum: Double(Float.greatestFiniteMagnitude)
                )
            )
        }
    }

    func testRejectsFloatEncodeValueJustAboveAdvertisedMaximum() throws {
        let maximum = Double(Float.greatestFiniteMagnitude)
        let value = maximum.nextUp

        XCTAssertThrowsError(
            try SMCCodec.encode(value, dataType: "flt ", expectedSize: 4)
        ) { error in
            XCTAssertEqual(
                error as? SMCCodecError,
                .valueOutOfRange(
                    dataType: "flt ",
                    value: value,
                    minimum: -maximum,
                    maximum: maximum
                )
            )
        }
    }

    func testRejectsFloatEncodeValueJustBelowAdvertisedMinimum() throws {
        let maximum = Double(Float.greatestFiniteMagnitude)
        let value = (-maximum).nextDown

        XCTAssertThrowsError(
            try SMCCodec.encode(value, dataType: "flt ", expectedSize: 4)
        ) { error in
            XCTAssertEqual(
                error as? SMCCodecError,
                .valueOutOfRange(
                    dataType: "flt ",
                    value: value,
                    minimum: -maximum,
                    maximum: maximum
                )
            )
        }
    }

    func testAcceptsExactAdvertisedFloatEncodeBounds() throws {
        let maximum = Double(Float.greatestFiniteMagnitude)

        XCTAssertEqual(
            try SMCCodec.encode(maximum, dataType: "flt ", expectedSize: 4),
            [0xFF, 0xFF, 0x7F, 0x7F]
        )
        XCTAssertEqual(
            try SMCCodec.encode(-maximum, dataType: "flt ", expectedSize: 4),
            [0xFF, 0xFF, 0x7F, 0xFF]
        )
    }

    func testDecodesAndEncodesLegacyFPE2() throws {
        XCTAssertEqual(
            try SMCCodec.decode([0x1F, 0x40], dataType: "fpe2", expectedSize: 2),
            2_000
        )
        XCTAssertEqual(
            try SMCCodec.decode([0x00, 0x01], dataType: "fpe2", expectedSize: 2),
            0.25
        )
        XCTAssertEqual(
            try SMCCodec.encode(2_443, dataType: "fpe2", expectedSize: 2),
            [0x26, 0x2C]
        )
        XCTAssertEqual(
            try SMCCodec.encode(1_234.75, dataType: "fpe2", expectedSize: 2),
            [0x13, 0x4B]
        )
    }

    func testFPE2RoundTripIncludesFractionalValue() throws {
        let encoded = try SMCCodec.encode(1_700.25, dataType: "fpe2", expectedSize: 2)
        XCTAssertEqual(
            try SMCCodec.decode(encoded, dataType: "fpe2", expectedSize: 2),
            1_700.25
        )
    }

    func testRejectsInvalidFPE2EncodeValues() throws {
        XCTAssertThrowsError(
            try SMCCodec.encode(-0.25, dataType: "fpe2", expectedSize: 2)
        ) { error in
            XCTAssertEqual(
                error as? SMCCodecError,
                .valueOutOfRange(dataType: "fpe2", value: -0.25, minimum: 0, maximum: 16_383.75)
            )
        }

        XCTAssertThrowsError(
            try SMCCodec.encode(1_000.1, dataType: "fpe2", expectedSize: 2)
        ) { error in
            XCTAssertEqual(
                error as? SMCCodecError,
                .invalidEncodeValue(dataType: "fpe2", value: 1_000.1)
            )
        }
    }

    func testDecodesSignedSP78IncludingNegativeValue() throws {
        XCTAssertEqual(
            try SMCCodec.decode([0x4B, 0x00], dataType: "sp78", expectedSize: 2),
            75
        )
        XCTAssertEqual(
            try SMCCodec.decode([0xF3, 0x80], dataType: "sp78", expectedSize: 2),
            -12.5
        )
    }

    func testEncodesNegativeSP78UsingBigEndianTwosComplement() throws {
        XCTAssertEqual(
            try SMCCodec.encode(-12.5, dataType: "sp78", expectedSize: 2),
            [0xF3, 0x80]
        )
    }

    func testSP78RoundTripsPositiveAndNegativeValues() throws {
        for value in [75.25, -12.5] {
            let encoded = try SMCCodec.encode(value, dataType: "sp78", expectedSize: 2)
            XCTAssertEqual(
                try SMCCodec.decode(encoded, dataType: "sp78", expectedSize: 2),
                value
            )
        }
    }

    func testRejectsNonrepresentableSP78FractionalValue() throws {
        let value = 1.1

        XCTAssertThrowsError(
            try SMCCodec.encode(value, dataType: "sp78", expectedSize: 2)
        ) { error in
            XCTAssertEqual(
                error as? SMCCodecError,
                .invalidEncodeValue(dataType: "sp78", value: value)
            )
        }
    }

    func testRejectsSP78ValueBelowLowerBound() throws {
        let value = -128.00390625

        XCTAssertThrowsError(
            try SMCCodec.encode(value, dataType: "sp78", expectedSize: 2)
        ) { error in
            XCTAssertEqual(
                error as? SMCCodecError,
                .valueOutOfRange(
                    dataType: "sp78",
                    value: value,
                    minimum: -128,
                    maximum: 127.99609375
                )
            )
        }
    }

    func testRejectsSP78ValueAboveUpperBound() throws {
        let value = 128.0

        XCTAssertThrowsError(
            try SMCCodec.encode(value, dataType: "sp78", expectedSize: 2)
        ) { error in
            XCTAssertEqual(
                error as? SMCCodecError,
                .valueOutOfRange(
                    dataType: "sp78",
                    value: value,
                    minimum: -128,
                    maximum: 127.99609375
                )
            )
        }
    }

    func testUnsignedIntegerCodecsUseSMCByteOrder() throws {
        XCTAssertEqual(
            try SMCCodec.decode([0x01], dataType: "ui8 ", expectedSize: 1),
            1
        )
        XCTAssertEqual(
            try SMCCodec.decode([0x11, 0x93], dataType: "ui16", expectedSize: 2),
            4_499
        )
        XCTAssertEqual(
            try SMCCodec.decode([0x00, 0x00, 0x00, 0x69], dataType: "ui32", expectedSize: 4),
            105
        )
    }

    func testUnsignedIntegerRoundTrips() throws {
        let vectors: [(String, Int, Double, [UInt8])] = [
            ("ui8 ", 1, 255, [0xFF]),
            ("ui16", 2, 4_499, [0x11, 0x93]),
            ("ui32", 4, 105, [0x00, 0x00, 0x00, 0x69]),
        ]

        for (dataType, size, value, bytes) in vectors {
            XCTAssertEqual(
                try SMCCodec.encode(value, dataType: dataType, expectedSize: size),
                bytes
            )
            XCTAssertEqual(
                try SMCCodec.decode(bytes, dataType: dataType, expectedSize: size),
                value
            )
        }
    }

    func testRejectsUnsignedEncodeValuesOutsideRangeOrNonIntegral() throws {
        XCTAssertThrowsError(
            try SMCCodec.encode(256, dataType: "ui8 ", expectedSize: 1)
        ) { error in
            XCTAssertEqual(
                error as? SMCCodecError,
                .valueOutOfRange(dataType: "ui8 ", value: 256, minimum: 0, maximum: 255)
            )
        }
        XCTAssertThrowsError(
            try SMCCodec.encode(1.5, dataType: "ui16", expectedSize: 2)
        ) { error in
            XCTAssertEqual(
                error as? SMCCodecError,
                .invalidEncodeValue(dataType: "ui16", value: 1.5)
            )
        }
    }

    func testRejectsReportedSizeThatDoesNotMatchDataType() throws {
        XCTAssertThrowsError(
            try SMCCodec.decode([0x00, 0x80], dataType: "flt ", expectedSize: 2)
        ) { error in
            XCTAssertEqual(
                error as? SMCCodecError,
                .wrongSize(dataType: "flt ", expected: 4, actual: 2)
            )
        }
    }

    func testRejectsPayloadWhoseByteCountDoesNotMatchReportedSize() throws {
        XCTAssertThrowsError(
            try SMCCodec.decode([0x00, 0x80, 0xD4], dataType: "flt ", expectedSize: 4)
        ) { error in
            XCTAssertEqual(
                error as? SMCCodecError,
                .wrongSize(dataType: "flt ", expected: 4, actual: 3)
            )
        }
    }

    func testRejectsMalformedAndUnsupportedDataTypeFourCCs() throws {
        XCTAssertThrowsError(
            try SMCCodec.decode([0, 0, 0, 0], dataType: "flt", expectedSize: 4)
        ) { error in
            XCTAssertEqual(error as? SMCCodecError, .invalidDataTypeFourCC("flt"))
        }

        XCTAssertThrowsError(
            try SMCCodec.decode([0, 0, 0, 0], dataType: "FLT ", expectedSize: 4)
        ) { error in
            XCTAssertEqual(error as? SMCCodecError, .unsupportedDataType("FLT "))
        }
    }
}
