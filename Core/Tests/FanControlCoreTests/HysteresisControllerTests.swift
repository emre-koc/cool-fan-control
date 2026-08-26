import XCTest
@testable import FanControlCore

final class HysteresisControllerTests: XCTestCase {
    // MARK: - First tick

    func testFirstTickInitializesTargetToDesired() {
        var controller = HysteresisController()
        XCTAssertNil(controller.currentTarget)
        XCTAssertEqual(controller.tick(desired: 1700), 1700)
        XCTAssertEqual(controller.currentTarget, 1700)
    }

    func testFirstTickWithNilDesiredStaysUninitialized() {
        var controller = HysteresisController()
        XCTAssertNil(controller.tick(desired: nil))
        XCTAssertNil(controller.currentTarget)
    }

    // MARK: - Rising

    func testRisingFollowsDesiredImmediately() {
        var controller = HysteresisController()
        _ = controller.tick(desired: 1700)
        XCTAssertEqual(controller.tick(desired: 2000), 2000)
        XCTAssertEqual(controller.tick(desired: 4499), 4499)
    }

    func testRisingEqualityDoesNotChange() {
        var controller = HysteresisController()
        _ = controller.tick(desired: 2000)
        XCTAssertEqual(controller.tick(desired: 2000), 2000)
        XCTAssertEqual(controller.currentTarget, 2000)
    }

    // MARK: - Falling band (default 5 % of current target)

    func testFallingWithinBandHolds() {
        var controller = HysteresisController()
        _ = controller.tick(desired: 2000)
        // band = 5 % of 2000 = 100 → hold while desired >= 1900.
        XCTAssertEqual(controller.tick(desired: 1900), 2000, "desired == current - band holds (strictly-below semantics)")
        XCTAssertEqual(controller.tick(desired: 1900.1), 2000)
        XCTAssertEqual(controller.tick(desired: 1950), 2000)
    }

    func testFallingBelowBandStepsDown() {
        var controller = HysteresisController()
        _ = controller.tick(desired: 2000)
        XCTAssertEqual(controller.tick(desired: 1899.9), 1899.9, "strictly below current - band steps down")
        XCTAssertEqual(controller.currentTarget, 1899.9)
    }

    func testExactBandBoundarySemantics() {
        var controller = HysteresisController()
        _ = controller.tick(desired: 1500)
        // band = 5 % of 1500 = 75; falling boundary = 1425.
        XCTAssertEqual(controller.tick(desired: 1425), 1500, "desired == currentTarget - band → NO change (strictly below)")
        XCTAssertEqual(controller.tick(desired: 1424.9), 1424.9, "desired < currentTarget - band → change")
    }

    func testDefaultConfigBandIsFivePercent() {
        let config = HysteresisConfig()
        XCTAssertEqual(config.bandFraction, 0.05)
        XCTAssertEqual(HysteresisConfig.default, config)
    }

    func testCustomBandFractionHonored() {
        var controller = HysteresisController(config: HysteresisConfig(bandFraction: 0.1))
        _ = controller.tick(desired: 2000)
        // band = 200; boundary = 1800.
        XCTAssertEqual(controller.tick(desired: 1800), 2000, "exactly at band boundary holds")
        XCTAssertEqual(controller.tick(desired: 1799.9), 1799.9)
    }

    func testZeroBandStepsDownOnAnyDrop() {
        var controller = HysteresisController(config: HysteresisConfig(bandFraction: 0))
        _ = controller.tick(desired: 2000)
        XCTAssertEqual(controller.tick(desired: 1999.9), 1999.9)
    }

    // MARK: - Missing / nonfinite input (keep last target)

    func testNilDesiredKeepsLastTarget() {
        var controller = HysteresisController()
        _ = controller.tick(desired: 2500)
        XCTAssertEqual(controller.tick(desired: nil), 2500, "missing input means no change")
        XCTAssertEqual(controller.currentTarget, 2500)
    }

    func testNonFiniteDesiredKeepsLastTarget() {
        var controller = HysteresisController()
        _ = controller.tick(desired: 2500)
        XCTAssertEqual(controller.tick(desired: .nan), 2500)
        XCTAssertEqual(controller.currentTarget, 2500)
        XCTAssertEqual(controller.tick(desired: .infinity), 2500)
        XCTAssertEqual(controller.currentTarget, 2500)
    }

    // MARK: - Reset

    func testResetClearsState() {
        var controller = HysteresisController()
        _ = controller.tick(desired: 2500)
        controller.reset()
        XCTAssertNil(controller.currentTarget)
        XCTAssertEqual(controller.tick(desired: 1700), 1700, "re-initializes after reset")
    }

    // MARK: - Determinism / types

    func testDeterministicReplay() {
        var first = HysteresisController()
        var second = HysteresisController()
        let inputs: [Double?] = [1700, 2500, 2400, 2350, 2300, nil, 2299, 2000, 1700]
        for desired in inputs {
            XCTAssertEqual(first.tick(desired: desired), second.tick(desired: desired))
        }
        XCTAssertEqual(first, second)
    }

    func testStateIsEquatable() {
        var controller = HysteresisController()
        XCTAssertEqual(controller, HysteresisController())
        _ = controller.tick(desired: 2500)
        XCTAssertNotEqual(controller, HysteresisController())
        controller.reset()
        XCTAssertEqual(controller, HysteresisController())
    }

    func testConfigCodableRoundTrip() throws {
        let config = HysteresisConfig(bandFraction: 0.1)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(HysteresisConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testConfigDecodeRejectsOutOfRangeBandFraction() {
        // Persisted configuration is never trusted: decode validates like init.
        for json in [#"{"bandFraction":2}"#, #"{"bandFraction":-1}"#, #"{"bandFraction":1.5}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(HysteresisConfig.self, from: Data(json.utf8)))
        }
    }

    func testModelsAreSendable() {
        requireSendable(HysteresisConfig())
        requireSendable(HysteresisController())
    }
}

private func requireSendable<T: Sendable>(_: T) {}
