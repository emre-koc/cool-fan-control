import XCTest
@testable import FanControlCore

final class TemperatureCurveTests: XCTestCase {
    private let minRPM = 1700.0
    private let maxRPM = 4499.0

    // MARK: - Defaults (40 °C → fan min, 85 °C → fan max)

    func testDefaultCurvePointsExact() throws {
        let curve = try TemperatureCurve.default(minimumRPM: minRPM, maximumRPM: maxRPM)
        XCTAssertEqual(curve.points, [
            CurvePoint(temperatureC: 40, rpm: minRPM),
            CurvePoint(temperatureC: 85, rpm: maxRPM),
        ])
        XCTAssertEqual(curve.minimumRPM, minRPM)
        XCTAssertEqual(curve.maximumRPM, maxRPM)
        XCTAssertEqual(curve.rpm(at: 40), minRPM)
        XCTAssertEqual(curve.rpm(at: 85), maxRPM)
    }

    func testDefaultCurveMidpointExact() throws {
        let curve = try TemperatureCurve.default(minimumRPM: minRPM, maximumRPM: maxRPM)
        // Exact midpoint (62.5 °C) → 3099.5 RPM: 1700 + 2799 × 0.5.
        XCTAssertEqual(curve.rpm(at: 62.5), 3099.5)
    }

    // MARK: - Piecewise-linear interpolation

    func testExactMidpointInterpolation() throws {
        let curve = try TemperatureCurve(points: [
            CurvePoint(temperatureC: 20, rpm: 100),
            CurvePoint(temperatureC: 30, rpm: 200),
        ], minimumRPM: 0, maximumRPM: 1000)
        XCTAssertEqual(curve.rpm(at: 25), 150)
    }

    func testInterpolationQuarterPoints() throws {
        let curve = try TemperatureCurve(points: [
            CurvePoint(temperatureC: 0, rpm: 0),
            CurvePoint(temperatureC: 100, rpm: 1000),
        ], minimumRPM: 0, maximumRPM: 2000)
        XCTAssertEqual(curve.rpm(at: 25), 250)
        XCTAssertEqual(curve.rpm(at: 50), 500)
        XCTAssertEqual(curve.rpm(at: 75), 750)
    }

    func testExactPointValuesReturnExactPointRPM() throws {
        let curve = try TemperatureCurve(points: [
            CurvePoint(temperatureC: 40, rpm: 1700),
            CurvePoint(temperatureC: 60, rpm: 2500),
            CurvePoint(temperatureC: 85, rpm: 4499),
        ], minimumRPM: minRPM, maximumRPM: maxRPM)
        XCTAssertEqual(curve.rpm(at: 40), 1700)
        XCTAssertEqual(curve.rpm(at: 60), 2500)
        XCTAssertEqual(curve.rpm(at: 85), 4499)
    }

    // MARK: - Below-first / above-last clamping

    func testBelowFirstClampsToFirstPoint() throws {
        let curve = try TemperatureCurve(points: [
            CurvePoint(temperatureC: 40, rpm: 1700),
            CurvePoint(temperatureC: 85, rpm: 4499),
        ], minimumRPM: minRPM, maximumRPM: maxRPM)
        XCTAssertEqual(curve.rpm(at: 0), 1700)
        XCTAssertEqual(curve.rpm(at: 39.9), 1700)
    }

    func testAboveLastClampsToLastPoint() throws {
        let curve = try TemperatureCurve(points: [
            CurvePoint(temperatureC: 40, rpm: 1700),
            CurvePoint(temperatureC: 85, rpm: 4499),
        ], minimumRPM: minRPM, maximumRPM: maxRPM)
        XCTAssertEqual(curve.rpm(at: 90), 4499)
        XCTAssertEqual(curve.rpm(at: 120), 4499)
    }

    // MARK: - Clamping to [minRPM, maxRPM]

    func testOutputClampedToStoredBounds() throws {
        let curve = try TemperatureCurve(points: [
            CurvePoint(temperatureC: 40, rpm: 1700),
            CurvePoint(temperatureC: 85, rpm: 4499),
        ], minimumRPM: 2000, maximumRPM: 4000)
        XCTAssertEqual(curve.rpm(at: 40), 2000, "below stored min clamps up")
        XCTAssertEqual(curve.rpm(at: 85), 4000, "above stored max clamps down")
        XCTAssertEqual(curve.rpm(at: 62.5), 3099.5, "midpoint inside bounds unchanged")
    }

    func testCallerProvidedBoundsOverrideStored() throws {
        let curve = try TemperatureCurve(points: [
            CurvePoint(temperatureC: 40, rpm: 1700),
            CurvePoint(temperatureC: 85, rpm: 4499),
        ], minimumRPM: minRPM, maximumRPM: maxRPM)
        XCTAssertEqual(curve.rpm(at: 40, clampedToMinimum: 2000, clampedToMaximum: 4000), 2000)
        XCTAssertEqual(curve.rpm(at: 85, clampedToMinimum: 2000, clampedToMaximum: 4000), 4000)
        XCTAssertEqual(curve.rpm(at: 62.5, clampedToMinimum: 2000, clampedToMaximum: 4000), 3099.5)
    }

    func testSinglePointCurveAllowed() throws {
        let curve = try TemperatureCurve(points: [CurvePoint(temperatureC: 60, rpm: 2500)], minimumRPM: minRPM, maximumRPM: maxRPM)
        XCTAssertEqual(curve.rpm(at: 10), 2500)
        XCTAssertEqual(curve.rpm(at: 60), 2500)
        XCTAssertEqual(curve.rpm(at: 100), 2500)
    }

    // MARK: - Invalid inputs (typed errors)

    func testEmptyPointsRejected() {
        XCTAssertThrowsError(try TemperatureCurve(points: [], minimumRPM: minRPM, maximumRPM: maxRPM)) { error in
            XCTAssertEqual(error as? TemperatureCurveError, .emptyPoints)
        }
    }

    func testEqualTemperaturesRejected() {
        XCTAssertThrowsError(try TemperatureCurve(points: [
            CurvePoint(temperatureC: 40, rpm: 1700),
            CurvePoint(temperatureC: 40, rpm: 4499),
        ], minimumRPM: minRPM, maximumRPM: maxRPM)) { error in
            XCTAssertEqual(error as? TemperatureCurveError, .nonIncreasingTemperatures(previousIndex: 0, previous: 40, current: 40))
        }
    }

    func testDecreasingTemperaturesRejected() {
        XCTAssertThrowsError(try TemperatureCurve(points: [
            CurvePoint(temperatureC: 85, rpm: 4499),
            CurvePoint(temperatureC: 40, rpm: 1700),
        ], minimumRPM: minRPM, maximumRPM: maxRPM))
    }

    func testNonFiniteTemperatureRejected() {
        XCTAssertThrowsError(try TemperatureCurve(points: [
            CurvePoint(temperatureC: .nan, rpm: 1700),
            CurvePoint(temperatureC: 85, rpm: 4499),
        ], minimumRPM: minRPM, maximumRPM: maxRPM))
        XCTAssertThrowsError(try TemperatureCurve(points: [
            CurvePoint(temperatureC: 40, rpm: 1700),
            CurvePoint(temperatureC: .infinity, rpm: 4499),
        ], minimumRPM: minRPM, maximumRPM: maxRPM))
    }

    func testNonFiniteRPMRejected() {
        XCTAssertThrowsError(try TemperatureCurve(points: [
            CurvePoint(temperatureC: 40, rpm: .nan),
            CurvePoint(temperatureC: 85, rpm: 4499),
        ], minimumRPM: minRPM, maximumRPM: maxRPM))
        XCTAssertThrowsError(try TemperatureCurve(points: [
            CurvePoint(temperatureC: 40, rpm: 1700),
            CurvePoint(temperatureC: 85, rpm: .infinity),
        ], minimumRPM: minRPM, maximumRPM: maxRPM))
    }

    // MARK: - Codable

    func testCodableRoundTrip() throws {
        let curve = try TemperatureCurve(points: [
            CurvePoint(temperatureC: 40, rpm: 1700),
            CurvePoint(temperatureC: 60, rpm: 2500),
            CurvePoint(temperatureC: 85, rpm: 4499),
        ], minimumRPM: minRPM, maximumRPM: maxRPM)
        let data = try JSONEncoder().encode(curve)
        let decoded = try JSONDecoder().decode(TemperatureCurve.self, from: data)
        XCTAssertEqual(decoded, curve)
    }

    func testCurvePointCodableRoundTrip() throws {
        let point = CurvePoint(temperatureC: 62.5, rpm: 3099.5)
        let data = try JSONEncoder().encode(point)
        let decoded = try JSONDecoder().decode(CurvePoint.self, from: data)
        XCTAssertEqual(decoded, point)
    }

    func testCodableRejectsEmptyCurveJSON() throws {
        // Decoding applies the same validation as init: empty points throw.
        let json = #"{"points":[],"minimumRPM":1700,"maximumRPM":4499}"#
        XCTAssertThrowsError(try JSONDecoder().decode(TemperatureCurve.self, from: Data(json.utf8)))
    }

    // MARK: - Types

    func testModelsAreSendable() throws {
        let curve = try TemperatureCurve.default(minimumRPM: minRPM, maximumRPM: maxRPM)
        requireSendable(curve)
        requireSendable(CurvePoint(temperatureC: 40, rpm: 1700))
        requireSendable(TemperatureCurveError.emptyPoints)
    }
}

private func requireSendable<T: Sendable>(_: T) {}
