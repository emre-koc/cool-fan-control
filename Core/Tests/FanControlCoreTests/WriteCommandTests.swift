import XCTest
@testable import FanControlCore

/// WriteCommand (FanWriteCommand) — validation + Codable.
///
/// Policy pinned here:
/// - `automatic` → `targetRPM` must be nil (typed error otherwise).
/// - `manual` → `targetRPM` must be present, finite, and inside
///   `[minimumRPM, maximumRPM]` supplied at construction (typed error
///   otherwise; bounds are validated only for manual commands).
/// - Wire format is `{fanIndex, mode, targetRPM}`; bounds are construction-time
///   context, not part of the transport (the future helper re-clamps as
///   defense-in-depth). Decoding validates structural consistency.
final class WriteCommandTests: XCTestCase {
    private func manual(_ rpm: Double, fanIndex: Int = 0, min: Double = 1700, max: Double = 4499) throws -> FanWriteCommand {
        try FanWriteCommand(fanIndex: fanIndex, mode: .manual, targetRPM: rpm, minimumRPM: min, maximumRPM: max)
    }

    private func automatic(fanIndex: Int = 0) throws -> FanWriteCommand {
        try FanWriteCommand(fanIndex: fanIndex, mode: .automatic, targetRPM: nil, minimumRPM: 1700, maximumRPM: 4499)
    }

    // MARK: - Validation

    func testManualInsideRangeAccepted() throws {
        let command = try manual(2500)
        XCTAssertEqual(command.fanIndex, 0)
        XCTAssertEqual(command.mode, .manual)
        XCTAssertEqual(command.targetRPM, 2500)
    }

    func testManualBoundaryValuesAccepted() throws {
        XCTAssertEqual(try manual(1700).targetRPM, 1700, "exactly minimum is valid")
        XCTAssertEqual(try manual(4499).targetRPM, 4499, "exactly maximum is valid")
    }

    func testManualBelowMinimumThrowsTypedError() {
        XCTAssertThrowsError(try manual(1699)) { error in
            XCTAssertEqual(
                error as? FanWriteCommandError,
                .targetOutOfBounds(minimumRPM: 1700, maximumRPM: 4499, targetRPM: 1699)
            )
        }
    }

    func testManualAboveMaximumThrowsTypedError() {
        XCTAssertThrowsError(try manual(4500)) { error in
            XCTAssertEqual(
                error as? FanWriteCommandError,
                .targetOutOfBounds(minimumRPM: 1700, maximumRPM: 4499, targetRPM: 4500)
            )
        }
    }

    func testManualMissingTargetThrowsTypedError() {
        XCTAssertThrowsError(
            try FanWriteCommand(fanIndex: 0, mode: .manual, targetRPM: nil, minimumRPM: 1700, maximumRPM: 4499)
        ) { error in
            XCTAssertEqual(error as? FanWriteCommandError, .manualMissingTarget)
        }
    }

    func testManualNonFiniteTargetThrowsTypedError() {
        XCTAssertThrowsError(try manual(.infinity)) { error in
            XCTAssertEqual(error as? FanWriteCommandError, .nonFiniteTargetRPM(.infinity))
        }
        // NaN is never equal to itself; assert by pattern match only.
        XCTAssertThrowsError(try manual(.nan)) { error in
            guard case .nonFiniteTargetRPM = error as? FanWriteCommandError else {
                return XCTFail("expected .nonFiniteTargetRPM, got \(error)")
            }
        }
    }

    func testAutomaticWithNilTargetAccepted() throws {
        let command = try automatic()
        XCTAssertEqual(command.mode, .automatic)
        XCTAssertNil(command.targetRPM)
    }

    func testAutomaticWithTargetThrowsTypedError() {
        XCTAssertThrowsError(
            try FanWriteCommand(fanIndex: 0, mode: .automatic, targetRPM: 2500, minimumRPM: 1700, maximumRPM: 4499)
        ) { error in
            XCTAssertEqual(error as? FanWriteCommandError, .automaticWithTarget(targetRPM: 2500))
        }
    }

    func testAutomaticIgnoresBounds() throws {
        // Bounds are only meaningful for manual commands; automatic passes through
        // with any (finite or not) bounds untouched.
        let command = try FanWriteCommand(fanIndex: 2, mode: .automatic, targetRPM: nil, minimumRPM: 0, maximumRPM: 0)
        XCTAssertEqual(command.fanIndex, 2)
        XCTAssertNil(command.targetRPM)
    }

    // MARK: - Equatable

    func testEquatable() throws {
        XCTAssertEqual(try manual(2500), try manual(2500))
        XCTAssertNotEqual(try manual(2500), try manual(2501))
        XCTAssertNotEqual(try manual(2500), try manual(2500, fanIndex: 1))
        XCTAssertNotEqual(try manual(2500), try automatic())
    }

    // MARK: - Codable

    func testCodableRoundTripManual() throws {
        let original = try manual(2500)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FanWriteCommand.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCodableRoundTripAutomatic() throws {
        let original = try automatic(fanIndex: 1)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FanWriteCommand.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testStableJSONShape() throws {
        let data = try JSONEncoder().encode(try manual(2500))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["fanIndex"] as? Int, 0)
        XCTAssertEqual(object["mode"] as? String, "manual")
        XCTAssertEqual((object["targetRPM"] as? NSNumber)?.doubleValue, 2500)
    }

    func testDecodeAutomaticWithExplicitNullTarget() throws {
        let data = Data(#"{"fanIndex":0,"mode":"automatic","targetRPM":null}"#.utf8)
        let decoded = try JSONDecoder().decode(FanWriteCommand.self, from: data)
        XCTAssertEqual(decoded, try automatic())
    }

    func testDecodeAutomaticMissingTargetKey() throws {
        let data = Data(#"{"fanIndex":0,"mode":"automatic"}"#.utf8)
        let decoded = try JSONDecoder().decode(FanWriteCommand.self, from: data)
        XCTAssertEqual(decoded, try automatic())
    }

    func testDecodeAutomaticWithTargetThrows() {
        let data = Data(#"{"fanIndex":0,"mode":"automatic","targetRPM":2500}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(FanWriteCommand.self, from: data))
    }

    func testDecodeManualWithoutTargetThrows() {
        let data = Data(#"{"fanIndex":0,"mode":"manual"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(FanWriteCommand.self, from: data))
    }

    func testDecodeManualWithNullTargetThrows() {
        let data = Data(#"{"fanIndex":0,"mode":"manual","targetRPM":null}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(FanWriteCommand.self, from: data))
    }

    func testDecodeNonNumericTargetThrows() {
        let data = Data(#"{"fanIndex":0,"mode":"manual","targetRPM":"abc"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(FanWriteCommand.self, from: data))
    }

    func testDecodeUnknownModeThrows() {
        let data = Data(#"{"fanIndex":0,"mode":"turbo","targetRPM":2500}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(FanWriteCommand.self, from: data))
    }

    // MARK: - Sendable

    func testWriteCommandAndErrorAreSendable() throws {
        requireSendable(try manual(2500))
        requireSendable(try automatic())
        requireSendable(FanWriteMode.automatic)
        requireSendable(FanWriteMode.manual)
        requireSendable(FanWriteCommandError.manualMissingTarget)
        requireSendable(FanWriteCommandError.targetOutOfBounds(minimumRPM: 1700, maximumRPM: 4499, targetRPM: 4500))
    }
}

private func requireSendable<T: Sendable>(_: T) {}
