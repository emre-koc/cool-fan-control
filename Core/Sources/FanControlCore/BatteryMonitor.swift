import CoreFoundation
import Foundation

// MARK: - Model

/// Read-only battery status for laptops. Cooling is fans-only: this model is
/// purely observational and never carries charging/power commands.
public struct BatteryState: Equatable, Sendable, Codable {
    /// A battery power source is attached (laptops). Desktops report false.
    public var isPresent: Bool
    /// The battery is currently drawing charge current (AC power + Is Charging).
    public var isCharging: Bool
    /// 0...100 percent, or nil when the source reports no capacity keys.
    public var chargePercent: Double?
    /// Battery temperature °C. SMC (`TB0T`/`BT0C`) supplies this via the helper;
    /// IOPowerSources never fabricates it — it stays nil unless a validated
    /// SMC reading is attached.
    public var temperatureC: Double?

    public init(isPresent: Bool, isCharging: Bool, chargePercent: Double?, temperatureC: Double?) {
        self.isPresent = isPresent
        self.isCharging = isCharging
        self.chargePercent = chargePercent
        self.temperatureC = temperatureC
    }

    /// The desktop / no-battery state.
    public static let notPresent = BatteryState(
        isPresent: false,
        isCharging: false,
        chargePercent: nil,
        temperatureC: nil
    )
}

// MARK: - Source seam

/// Fakeable source of battery status. Production wraps the public IOPowerSources
/// API; tests inject fakes.
public protocol BatteryStatusProviding: Sendable {
    func snapshot() async -> BatteryState
}

#if os(macOS)
import IOKit.ps
#endif

// MARK: - Pure IOPS dictionary mapping

/// Maps real `IOPSGetPowerSourceDescription` dictionary shapes to
/// `BatteryState`. Pure and unit-testable; tests build genuine CFDictionary
/// values with CFString keys so the exact bridging code path is exercised.
public enum IOPowerSourcesBatteryMapper: Sendable {
    public static func batteryState(descriptions: [CFDictionary]) -> BatteryState {
        guard let description = descriptions.first else { return .notPresent }
        let dictionary = description as NSDictionary

        // "Is Present" may be absent on internal batteries; treat missing as present.
        let present = (dictionary[kIOPSIsPresentKey as String] as? Bool) ?? true
        guard present else { return .notPresent }

        let isChargingFlag = (dictionary[kIOPSIsChargingKey as String] as? Bool) ?? false
        let state = dictionary[kIOPSPowerSourceStateKey as String] as? String
        // Plan policy: charging means AC power AND the "Is Charging" flag.
        // On Battery Power the flag is meaningless — force it false.
        let isCharging = isChargingFlag && state != kIOPSBatteryPowerValue

        var chargePercent: Double?
        if let current = dictionary[kIOPSCurrentCapacityKey as String] as? Int,
           let maximum = dictionary[kIOPSMaxCapacityKey as String] as? Int,
           maximum > 0 {
            chargePercent = min(max(100.0 * Double(current) / Double(maximum), 0), 100)
        }

        return BatteryState(
            isPresent: true,
            isCharging: isCharging,
            chargePercent: chargePercent,
            temperatureC: nil // SMC only; never fabricated here
        )
    }
}

// MARK: - Production monitor

/// Production battery-status provider backed by the public IOPowerSources API
/// (`IOPSCopyPowerSourcesInfo` / `IOPSCopyPowerSourcesList` /
/// `IOPSGetPowerSourceDescription`). Unprivileged, read-only.
///
/// CF ownership: all returned values come from Copy/Get functions and are
/// bridged by Swift ARC inside one synchronous scope — no manual CFRelease
/// (it is unavailable in Swift).
public struct IOPowerSourcesBatteryMonitor: BatteryStatusProviding, Sendable {
    public init() {}

    public func snapshot() async -> BatteryState {
        // One synchronous scope: every CF value is created, used, and released here.
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return .notPresent
        }
        guard let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() else {
            return .notPresent
        }

        let count = CFArrayGetCount(list)
        var descriptions: [CFDictionary] = []
        descriptions.reserveCapacity(count)
        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let source = unsafeBitCast(raw, to: AnyObject.self)
            if let rawDescription = IOPSGetPowerSourceDescription(info, source) {
                // Get-function result: not owned by us — it lives as long as the
                // blob (`info`) does, which covers this whole synchronous scope.
                descriptions.append(rawDescription.takeUnretainedValue())
            }
        }
        return IOPowerSourcesBatteryMapper.batteryState(descriptions: descriptions)
    }
}
