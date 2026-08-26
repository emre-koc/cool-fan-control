import CoreFoundation
import Dispatch
import Foundation

// MARK: - Family classification

/// Allowlisted IOHID temperature-sensor families on Apple Silicon.
///
/// Classification is exact-prefix only: a service is trusted only when its
/// `Product` property starts with one of the verified prefixes. Near-misses
/// (case, spacing, `PMU`, `ANE`, `NAND`, ...) are rejected so they can never
/// be promoted to CPU or control candidates.
public enum ThermalSensorFamily: String, CaseIterable, Sendable, Equatable {
    case pACC_CPU
    case eACC_CPU
    case GPU
    case SOC
    case PMGR_SOC_DIE

    public static func classify(productName: String) -> ThermalSensorFamily? {
        if productName.hasPrefix("pACC MTR Temp Sensor") { return .pACC_CPU }
        if productName.hasPrefix("eACC MTR Temp Sensor") { return .eACC_CPU }
        if productName.hasPrefix("GPU MTR Temp Sensor") { return .GPU }
        if productName.hasPrefix("SOC MTR Temp Sensor") { return .SOC }
        if productName.hasPrefix("PMGR SOC Die Temp") { return .PMGR_SOC_DIE }
        return nil
    }

    /// CPU candidates: performance (`pACC`) and efficiency (`eACC`) cores.
    public var isCPU: Bool {
        self == .pACC_CPU || self == .eACC_CPU
    }

    /// Families allowed to drive the smart fan curve. PMGR is corroboration
    /// only and is deliberately excluded.
    public var isControlCandidate: Bool {
        isCPU || self == .GPU || self == .SOC
    }
}

// MARK: - Diagnostics

/// Why a raw service did not become a trusted reading. At most one diagnostic
/// is emitted per service, in precedence order: missing product, missing event,
/// non-finite value, implausible value, future timestamp, stale, unclassified.
public enum ThermalReadingDiagnostic: Equatable, Sendable {
    case missingProduct
    case missingEvent(productName: String)
    case nonFiniteValue(productName: String, value: Double)
    case outOfPlausibleRange(productName: String, value: Double)
    case futureSample(productName: String, skewNanos: UInt64)
    case stale(productName: String, ageNanos: UInt64)
    case unclassified(productName: String, celsius: Double)
}

// MARK: - Models

/// One trusted, allowlisted temperature reading in degrees Celsius.
public struct TrustedThermalReading: Equatable, Sendable {
    public let productName: String
    public let family: ThermalSensorFamily
    public let celsius: Double
    /// Monotonic clock nanoseconds at scan time (the single scan timestamp).
    public let sampledAt: UInt64

    public init(productName: String, family: ThermalSensorFamily, celsius: Double, sampledAt: UInt64) {
        self.productName = productName
        self.family = family
        self.celsius = celsius
        self.sampledAt = sampledAt
    }
}

/// Coherent, deterministic thermal snapshot for one scan.
public struct TrustedThermalSnapshot: Equatable, Sendable {
    /// Trusted readings sorted deterministically by product name.
    public let readings: [TrustedThermalReading]
    /// Hottest CPU candidate (pACC/eACC only), or nil when none is trusted.
    public let hottestCPU: TrustedThermalReading?
    /// Hottest control candidate (CPU/GPU/SOC only, never PMGR), or nil.
    public let hottestControl: TrustedThermalReading?
    public let diagnostics: [ThermalReadingDiagnostic]

    public init(
        readings: [TrustedThermalReading],
        hottestCPU: TrustedThermalReading?,
        hottestControl: TrustedThermalReading?,
        diagnostics: [ThermalReadingDiagnostic]
    ) {
        self.readings = readings
        self.hottestCPU = hottestCPU
        self.hottestControl = hottestControl
        self.diagnostics = diagnostics
    }
}

// MARK: - Raw inventory seam

/// A raw service observation before classification and validation.
/// `productName` is nil when the service exposes no `Product` property;
/// `celsius` is nil when the temperature event is missing.
public struct RawThermalReading: Equatable, Sendable {
    public let productName: String?
    public let celsius: Double?
    public let sampledAt: UInt64

    public init(productName: String?, celsius: Double?, sampledAt: UInt64) {
        self.productName = productName
        self.celsius = celsius
        self.sampledAt = sampledAt
    }
}

/// Seam that produces the raw matched temperature-service inventory.
/// Production uses the IOHID event-system client; tests inject fakes.
public protocol RawThermalSampling: Sendable {
    func copyRawThermalReadings(at now: UInt64) -> [RawThermalReading]
}

// MARK: - Pure snapshot builder

/// Pure classification/validation/freshness logic, fully unit-testable
/// without hardware.
public struct TrustedThermalSnapshotBuilder: Sendable {
    public static let defaultMaxAgeNanos: UInt64 = 5_000_000_000

    /// Freshness window. Must be positive.
    public let maxAgeNanos: UInt64

    public init(maxAgeNanos: UInt64 = TrustedThermalSnapshotBuilder.defaultMaxAgeNanos) {
        precondition(maxAgeNanos > 0, "maxAgeNanos must be positive")
        self.maxAgeNanos = maxAgeNanos
    }

    public func build(rawReadings: [RawThermalReading], now: UInt64) -> TrustedThermalSnapshot {
        var diagnostics: [ThermalReadingDiagnostic] = []
        diagnostics.reserveCapacity(rawReadings.count)
        var accepted: [TrustedThermalReading] = []
        accepted.reserveCapacity(rawReadings.count)

        for raw in rawReadings {
            guard let productName = raw.productName, !productName.isEmpty else {
                diagnostics.append(.missingProduct)
                continue
            }
            guard let celsius = raw.celsius else {
                diagnostics.append(.missingEvent(productName: productName))
                continue
            }
            guard celsius.isFinite else {
                diagnostics.append(.nonFiniteValue(productName: productName, value: celsius))
                continue
            }
            // Live plausibility gate from the verified contract: 10 < T <= 120.
            guard celsius > 10, celsius <= 120 else {
                diagnostics.append(.outOfPlausibleRange(productName: productName, value: celsius))
                continue
            }
            if raw.sampledAt > now {
                diagnostics.append(.futureSample(productName: productName, skewNanos: raw.sampledAt - now))
                continue
            }
            let age = now - raw.sampledAt
            if age > maxAgeNanos {
                diagnostics.append(.stale(productName: productName, ageNanos: age))
                continue
            }
            guard let family = ThermalSensorFamily.classify(productName: productName) else {
                diagnostics.append(.unclassified(productName: productName, celsius: celsius))
                continue
            }
            accepted.append(TrustedThermalReading(
                productName: productName,
                family: family,
                celsius: celsius,
                sampledAt: raw.sampledAt
            ))
        }

        // Deterministic total order: product name, then sample time, then value.
        accepted.sort { lhs, rhs in
            if lhs.productName != rhs.productName { return lhs.productName < rhs.productName }
            if lhs.sampledAt != rhs.sampledAt { return lhs.sampledAt < rhs.sampledAt }
            return lhs.celsius < rhs.celsius
        }

        // Strict greater-than keeps the first (alphabetically smallest) max as
        // the representative, so ties are deterministic.
        var hottestCPU: TrustedThermalReading?
        var hottestControl: TrustedThermalReading?
        for reading in accepted {
            if reading.family.isCPU, hottestCPU == nil || reading.celsius > hottestCPU!.celsius {
                hottestCPU = reading
            }
            if reading.family.isControlCandidate, hottestControl == nil || reading.celsius > hottestControl!.celsius {
                hottestControl = reading
            }
        }

        return TrustedThermalSnapshot(
            readings: accepted,
            hottestCPU: hottestCPU,
            hottestControl: hottestControl,
            diagnostics: diagnostics
        )
    }
}

// MARK: - Source protocol

/// A source of trusted, validated thermal snapshots.
public protocol TrustedThermalReadingSource: Sendable {
    func trustedSnapshot() async throws -> TrustedThermalSnapshot
}

// MARK: - Production IOHID reader

/// Production thermal reader backed by the private-but-exported IOHID
/// event-system contract (PrimaryUsagePage 0xff00 / PrimaryUsage 0x0005,
/// event type 15, float field 15 << 16, already Celsius).
///
/// One scan uses exactly one clock value: it is read once, stamped onto every
/// raw reading, and used as the freshness base for the whole snapshot.
public actor IOHIDTrustedThermalReader: TrustedThermalReadingSource {
    private let sampler: any RawThermalSampling
    private let builder: TrustedThermalSnapshotBuilder
    private let clock: @Sendable () -> UInt64

    public init(
        sampler: any RawThermalSampling = IOHIDRawThermalSampler(),
        maxAgeNanos: UInt64 = TrustedThermalSnapshotBuilder.defaultMaxAgeNanos,
        clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.sampler = sampler
        self.builder = TrustedThermalSnapshotBuilder(maxAgeNanos: maxAgeNanos)
        self.clock = clock
    }

    public func trustedSnapshot() async throws -> TrustedThermalSnapshot {
        let now = clock()
        let rawReadings = sampler.copyRawThermalReadings(at: now)
        return builder.build(rawReadings: rawReadings, now: now)
    }
}

// MARK: - IOHID raw sampler

/// Enumerates the matched temperature services through the IOHID event system
/// and copies their raw product names and Celsius float values.
public struct IOHIDRawThermalSampler: RawThermalSampling {
    private static let temperatureEventType: Int64 = 15
    private static let temperatureField: Int64 = 15 << 16

    public init() {}

    public func copyRawThermalReadings(at now: UInt64) -> [RawThermalReading] {
        // Swift ARC manages Core Foundation objects returned from Create/Copy
        // functions, so no manual CFRelease is needed (it is unavailable).
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return [] }

        let page = NSNumber(value: 0xFF00) as CFNumber
        let usage = NSNumber(value: 0x0005) as CFNumber
        let matching = ["PrimaryUsagePage": page, "PrimaryUsage": usage] as CFDictionary
        IOHIDEventSystemClientSetMatching(client, matching)

        guard let services = IOHIDEventSystemClientCopyServices(client) else { return [] }

        var readings: [RawThermalReading] = []
        let count = CFArrayGetCount(services)
        readings.reserveCapacity(count)
        for index in 0..<count {
            guard let rawService = CFArrayGetValueAtIndex(services, index) else { continue }
            let service = unsafeBitCast(rawService, to: AnyObject.self)
            let productName = copyProductName(service)
            var celsius: Double?
            if let event = IOHIDServiceClientCopyEvent(service, Self.temperatureEventType, 0, 0) {
                celsius = IOHIDEventGetFloatValue(event, Self.temperatureField)
            }
            readings.append(RawThermalReading(productName: productName, celsius: celsius, sampledAt: now))
        }
        return readings
    }

    private func copyProductName(_ service: AnyObject) -> String? {
        guard let value = IOHIDServiceClientCopyProperty(service, "Product" as CFString) else { return nil }
        guard CFGetTypeID(value) == CFStringGetTypeID() else { return String(describing: value) }
        return (value as! CFString) as String
    }
}

// MARK: - Private-but-exported IOHID event-system symbols
//
// Same declarations used by Stats/macmon/mactop: direct symbol references,
// no dlsym. All returned values are retained (Copy semantics) and released by
// the caller. CF ownership never crosses an isolation boundary: every value is
// created, used, and released inside one synchronous scope.

private typealias IOHIDEventSystemClientRef = AnyObject
private typealias IOHIDServiceClientRef = AnyObject
private typealias IOHIDEventRef = AnyObject

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> IOHIDEventSystemClientRef?

@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: IOHIDEventSystemClientRef?, _ matching: CFDictionary?) -> Void

@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: IOHIDEventSystemClientRef?) -> CFArray?

@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: IOHIDServiceClientRef?, _ key: CFString?) -> CFTypeRef?

@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: IOHIDServiceClientRef?, _ type: Int64, _ options: Int32, _ timeout: Double) -> IOHIDEventRef?

@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: IOHIDEventRef?, _ field: Int64) -> Double
