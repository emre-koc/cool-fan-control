import XCTest
@testable import FanControlCore

final class FanModeTests: XCTestCase {
    // MARK: - Codable round-trips

    func testCodableRoundTripAllCases() throws {
        let modes: [FanMode] = [.auto, .smart, .manual(rpm: 1200), .quiet, .max]
        for mode in modes {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(FanMode.self, from: data)
            XCTAssertEqual(decoded, mode, "round-trip for \(mode)")
        }
    }

    func testManualJSONShapeIsStable() throws {
        let data = try JSONEncoder().encode(FanMode.manual(rpm: 1200))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["mode"] as? String, "manual")
        XCTAssertEqual(json["rpm"] as? Int, 1200)
    }

    func testDecodesKnownJSON() throws {
        let auto = try JSONDecoder().decode(FanMode.self, from: Data(#"{"mode":"auto"}"#.utf8))
        XCTAssertEqual(auto, .auto)
        let manual = try JSONDecoder().decode(FanMode.self, from: Data(#"{"mode":"manual","rpm":1800}"#.utf8))
        XCTAssertEqual(manual, .manual(rpm: 1800))
        let quiet = try JSONDecoder().decode(FanMode.self, from: Data(#"{"mode":"quiet"}"#.utf8))
        XCTAssertEqual(quiet, .quiet)
    }

    func testRejectsUnknownModeJSON() {
        XCTAssertThrowsError(try JSONDecoder().decode(FanMode.self, from: Data(#"{"mode":"turbo"}"#.utf8)))
    }

    func testRejectsManualWithoutRPM() {
        XCTAssertThrowsError(try JSONDecoder().decode(FanMode.self, from: Data(#"{"mode":"manual"}"#.utf8)))
    }

    // MARK: - Mode → fixed target mapping (quiet/max/manual; auto/smart nil)

    func testQuietMapsToFanMinimum() {
        XCTAssertEqual(FanMode.quiet.fixedTarget(minimumRPM: 1700, maximumRPM: 4499), 1700)
        XCTAssertEqual(FanMode.quiet.fixedTarget(minimumRPM: 2000, maximumRPM: 4000), 2000)
    }

    func testMaxMapsToFanMaximum() {
        XCTAssertEqual(FanMode.max.fixedTarget(minimumRPM: 1700, maximumRPM: 4499), 4499)
        XCTAssertEqual(FanMode.max.fixedTarget(minimumRPM: 2000, maximumRPM: 4000), 4000)
    }

    func testManualMapsToFixedRPMRaw() {
        XCTAssertEqual(FanMode.manual(rpm: 2500).fixedTarget(minimumRPM: 1700, maximumRPM: 4499), 2500)
    }

    func testAutoAndSmartHaveNoFixedTarget() {
        XCTAssertNil(FanMode.auto.fixedTarget(minimumRPM: 1700, maximumRPM: 4499))
        XCTAssertNil(FanMode.smart.fixedTarget(minimumRPM: 1700, maximumRPM: 4499))
    }

    // MARK: - Types

    func testFanModeIsSendable() {
        requireSendable(FanMode.auto)
        requireSendable(FanMode.smart)
        requireSendable(FanMode.manual(rpm: 100))
        requireSendable(FanMode.quiet)
        requireSendable(FanMode.max)
    }
}

private func requireSendable<T: Sendable>(_: T) {}
