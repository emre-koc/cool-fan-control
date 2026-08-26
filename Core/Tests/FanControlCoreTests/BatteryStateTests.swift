import XCTest
@testable import FanControlCore

final class BatteryStateTests: XCTestCase {
    // MARK: - Model

    func testBatteryStateFieldsAndDefaults() {
        let state = BatteryState(isPresent: true, isCharging: true, chargePercent: 62.5, temperatureC: 34.2)
        XCTAssertTrue(state.isPresent)
        XCTAssertTrue(state.isCharging)
        XCTAssertEqual(state.chargePercent, 62.5)
        XCTAssertEqual(state.temperatureC, 34.2)
    }

    func testBatteryStateNotPresentHelper() {
        let state = BatteryState.notPresent
        XCTAssertFalse(state.isPresent)
        XCTAssertFalse(state.isCharging)
        XCTAssertNil(state.chargePercent)
        XCTAssertNil(state.temperatureC)
    }

    func testBatteryStateCodableRoundTrip() throws {
        let state = BatteryState(isPresent: true, isCharging: false, chargePercent: 100, temperatureC: nil)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(BatteryState.self, from: data)
        XCTAssertEqual(decoded, state)
        XCTAssertNil(decoded.temperatureC)
    }

    func testBatteryStateCodableRoundTripWithTemperature() throws {
        let state = BatteryState(isPresent: true, isCharging: true, chargePercent: 42, temperatureC: 36.25)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(BatteryState.self, from: data)
        XCTAssertEqual(decoded, state)
    }

    func testBatteryStateSendable() {
        requireSendable(BatteryState(isPresent: true, isCharging: true, chargePercent: 50, temperatureC: 33.5))
    }

    // MARK: - BatteryStatusProviding seam

    func testBatteryStatusProvidingFakeIsAsyncAndSendable() async {
        let fake = FakeBatteryProvider(state: BatteryState(isPresent: true, isCharging: true, chargePercent: 75, temperatureC: nil))
        let state = await fake.snapshot()
        XCTAssertEqual(state.isPresent, true)
        XCTAssertEqual(state.isCharging, true)
        XCTAssertEqual(state.chargePercent, 75)
        XCTAssertNil(state.temperatureC)
    }

    func testBatteryStatusProvidingProductionMonitorConforms() async {
        let monitor: any BatteryStatusProviding = IOPowerSourcesBatteryMonitor()
        requireSendable(monitor)
        let state = await monitor.snapshot()
        XCTAssertFalse(state.isPresent, "desktop host has no power source")
        XCTAssertFalse(state.isCharging)
        XCTAssertNil(state.chargePercent)
        XCTAssertNil(state.temperatureC)
    }

    // MARK: - IOPS dictionary mapping (real CF dictionary shapes)

    func testMapperAbsentSourceIsNotPresent() {
        let state = IOPowerSourcesBatteryMapper.batteryState(descriptions: [])
        XCTAssertEqual(state, .notPresent)
    }

    func testMapperDesktopNoBatteryEmptyListIsNotPresent() {
        // Live Mac mini IOPS shape: list is empty (count 0) → not present.
        let state = IOPowerSourcesBatteryMapper.batteryState(descriptions: [])
        XCTAssertFalse(state.isPresent)
    }

    func testMapperChargingOnACPower() {
        let dict = iops([
            (kIOPSIsChargingKey, kCFBooleanTrue as AnyObject),
            (kIOPSCurrentCapacityKey, NSNumber(value: 50)),
            (kIOPSMaxCapacityKey, NSNumber(value: 100)),
            (kIOPSPowerSourceStateKey, kIOPSACPowerValue as NSString),
        ])
        let state = IOPowerSourcesBatteryMapper.batteryState(descriptions: [dict])
        XCTAssertTrue(state.isPresent)
        XCTAssertTrue(state.isCharging)
        XCTAssertEqual(state.chargePercent, 50)
        XCTAssertNil(state.temperatureC, "IOPS never fabricates a temperature; SMC TB0T/BT0C is supplied by the helper later")
    }

    func testMapperChargingFlagFalseWhilePluggedAndFull() {
        let dict = iops([
            (kIOPSIsChargingKey, kCFBooleanFalse as AnyObject),
            (kIOPSCurrentCapacityKey, NSNumber(value: 100)),
            (kIOPSMaxCapacityKey, NSNumber(value: 100)),
            (kIOPSPowerSourceStateKey, kIOPSACPowerValue as NSString),
        ])
        let state = IOPowerSourcesBatteryMapper.batteryState(descriptions: [dict])
        XCTAssertTrue(state.isPresent)
        XCTAssertFalse(state.isCharging)
        XCTAssertEqual(state.chargePercent, 100)
    }

    func testMapperOnBatteryPowerNeverChargingEvenIfFlagSet() {
        let dict = iops([
            (kIOPSIsChargingKey, kCFBooleanTrue as AnyObject),
            (kIOPSCurrentCapacityKey, NSNumber(value: 40)),
            (kIOPSMaxCapacityKey, NSNumber(value: 100)),
            (kIOPSPowerSourceStateKey, kIOPSBatteryPowerValue as NSString),
        ])
        let state = IOPowerSourcesBatteryMapper.batteryState(descriptions: [dict])
        XCTAssertTrue(state.isPresent)
        XCTAssertFalse(state.isCharging, "state == Battery Power forces isCharging false")
        XCTAssertEqual(state.chargePercent, 40)
    }

    func testMapperMissingCapacityKeysYieldsNilPercent() {
        let dict = iops([
            (kIOPSIsChargingKey, kCFBooleanTrue as AnyObject),
            (kIOPSPowerSourceStateKey, kIOPSACPowerValue as NSString),
        ])
        let state = IOPowerSourcesBatteryMapper.batteryState(descriptions: [dict])
        XCTAssertTrue(state.isPresent)
        XCTAssertTrue(state.isCharging)
        XCTAssertNil(state.chargePercent)
    }

    func testMapperZeroMaxCapacityYieldsNilPercent() {
        let dict = iops([
            (kIOPSCurrentCapacityKey, NSNumber(value: 0)),
            (kIOPSMaxCapacityKey, NSNumber(value: 0)),
        ])
        let state = IOPowerSourcesBatteryMapper.batteryState(descriptions: [dict])
        XCTAssertTrue(state.isPresent)
        XCTAssertNil(state.chargePercent)
    }

    func testMapperClampsPercentToZeroThroughHundred() {
        let over = IOPowerSourcesBatteryMapper.batteryState(descriptions: [iops([
            (kIOPSCurrentCapacityKey, NSNumber(value: 120)),
            (kIOPSMaxCapacityKey, NSNumber(value: 100)),
        ])])
        XCTAssertEqual(over.chargePercent, 100)

        let under = IOPowerSourcesBatteryMapper.batteryState(descriptions: [iops([
            (kIOPSCurrentCapacityKey, NSNumber(value: -5)),
            (kIOPSMaxCapacityKey, NSNumber(value: 100)),
        ])])
        XCTAssertEqual(under.chargePercent, 0)
    }

    func testMapperIsPresentFalseFlagYieldsNotPresent() {
        let dict = iops([
            (kIOPSIsPresentKey, kCFBooleanFalse as AnyObject),
            (kIOPSIsChargingKey, kCFBooleanTrue as AnyObject),
        ])
        let state = IOPowerSourcesBatteryMapper.batteryState(descriptions: [dict])
        XCTAssertEqual(state, .notPresent)
    }

    func testMapperUsesFirstSourceDescription() {
        let first = iops([
            (kIOPSCurrentCapacityKey, NSNumber(value: 25)),
            (kIOPSMaxCapacityKey, NSNumber(value: 100)),
            (kIOPSIsChargingKey, kCFBooleanTrue as AnyObject),
        ])
        let second = iops([
            (kIOPSCurrentCapacityKey, NSNumber(value: 90)),
            (kIOPSMaxCapacityKey, NSNumber(value: 100)),
        ])
        let state = IOPowerSourcesBatteryMapper.batteryState(descriptions: [first, second])
        XCTAssertTrue(state.isPresent)
        XCTAssertEqual(state.chargePercent, 25)
        XCTAssertTrue(state.isCharging)
    }
}

// MARK: - Helpers

/// Builds a real CFDictionary with CFString keys (the shape returned by
/// IOPSGetPowerSourceDescription).
private func iops(_ pairs: [(String, AnyObject)]) -> CFDictionary {
    pairs.reduce(into: [String: AnyObject]()) { partial, pair in
        partial[pair.0] = pair.1
    } as CFDictionary
}

private struct FakeBatteryProvider: BatteryStatusProviding {
    let state: BatteryState
    func snapshot() async -> BatteryState { state }
}

private func requireSendable<T: Sendable>(_: T) {}
