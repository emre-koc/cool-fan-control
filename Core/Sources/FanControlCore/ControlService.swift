import Dispatch
import Foundation

// MARK: - Write targets seam

/// What one fan tick decided should happen to the hardware.
public enum FanWriteAction: Equatable, Sendable {
    /// Write a validated manual command (target RPM).
    case write(FanWriteCommand)
    /// Return the fan to Apple's automatic control (write `F0Md = 0`).
    case restoreAutomatic
    /// No write this tick.
    case none
}

/// Seam that applies per-tick fan write decisions. Production writes SMC via
/// the helper (the only process allowed to write); tests record.
public protocol FanWriteTargets: Sendable {
    func apply(actions: [FanWriteAction]) async
}

// MARK: - Per-fan decision

/// One fan's decision for one tick. `effectiveRPM == nil` means Apple
/// automatic control.
public struct FanControlState: Equatable, Sendable {
    public let fanIndex: Int
    public let effectiveRPM: Double?
    public let action: FanWriteAction

    public init(fanIndex: Int, effectiveRPM: Double?, action: FanWriteAction) {
        self.fanIndex = fanIndex
        self.effectiveRPM = effectiveRPM
        self.action = action
    }
}

// MARK: - Fail-safe

/// Typed failure surfaced by `ControlService.tick()`. Each case pins one
/// fail-safe path: the tick that reports it restores Apple automatic control
/// for every known fan — a stale manual target is never kept.
public enum ControlFailure: Equatable, Sendable {
    case fanReadFailed(reason: String)
    case thermalSourceFailed(reason: String)
    case staleAllThermal
}

// MARK: - Control state

/// Immutable, deterministic snapshot of one service tick.
public struct ControlState: Equatable, Sendable {
    public let timestampNanos: UInt64
    /// Fan snapshot passthrough; empty when the fan read failed.
    public let fans: [FanInfo]
    public let hottestControl: TrustedThermalReading?
    public let hottestCPU: TrustedThermalReading?
    public let battery: BatteryState
    public let mode: FanMode
    public let failSafe: [ControlFailure]
    public let perFan: [FanControlState]

    public init(
        timestampNanos: UInt64,
        fans: [FanInfo],
        hottestControl: TrustedThermalReading?,
        hottestCPU: TrustedThermalReading?,
        battery: BatteryState,
        mode: FanMode,
        failSafe: [ControlFailure],
        perFan: [FanControlState]
    ) {
        self.timestampNanos = timestampNanos
        self.fans = fans
        self.hottestControl = hottestControl
        self.hottestCPU = hottestCPU
        self.battery = battery
        self.mode = mode
        self.failSafe = failSafe
        self.perFan = perFan
    }
}

// MARK: - ControlService

/// One coherent tick combining fan/thermal/battery readers, the pure engine,
/// per-fan write throttling, and the write-target seam.
///
/// Fail-safe policy (pinned by `ControlServiceTests`):
/// - Fan-read failure → restore automatic for every *last-known* fan; with no
///   fans ever known there is nothing to restore and nothing is written.
/// - Thermal transport failure, or a fully-stale thermal snapshot (raw
///   readings present but none fresh) → restore automatic for every current
///   fan. A stale manual target is never kept.
/// - A *valid* thermal snapshot with no readings is NOT a failure: existing
///   engine semantics apply (CPU guard releases on nil, smart hysteresis
///   holds its last target).
/// - Fanless → no fan commands at all (an empty apply is still delivered).
///
/// Every action — normal or fail-safe — passes through that fan's
/// `WriteThrottle`, so restores are never rate-limited out of existence and
/// repeated automatic commands collapse to the auto-only-once policy.
public actor ControlService {
    public struct Config: Equatable, Sendable {
        public var mode: FanMode
        public var curve: TemperatureCurve
        public var engine: FanControlEngine.Config
        public var batteryCooling: BatteryCoolingConfig
        public var cpuGuard: CpuThrottleGuardConfig
        public var throttle: WriteThrottleConfig

        public init(
            mode: FanMode,
            curve: TemperatureCurve,
            engine: FanControlEngine.Config = .default,
            batteryCooling: BatteryCoolingConfig = .default,
            cpuGuard: CpuThrottleGuardConfig = .default,
            throttle: WriteThrottleConfig = .default
        ) {
            self.mode = mode
            self.curve = curve
            self.engine = engine
            self.batteryCooling = batteryCooling
            self.cpuGuard = cpuGuard
            self.throttle = throttle
        }
    }

    private let fanDiscovery: any FanDiscovering
    private let thermalSource: any TrustedThermalReadingSource
    private let batteryStatus: any BatteryStatusProviding
    private let writeTargets: any FanWriteTargets
    private let clock: @Sendable () -> UInt64

    private var config: Config
    private var engine: FanControlEngine
    private var batteryRule: BatteryCoolingRule
    private var cpuGuard: CpuThrottleGuard
    private var throttles: [Int: WriteThrottle]
    /// Fans from the last successful discovery — the restore set when a later
    /// fan read fails.
    private var lastKnownFans: [FanInfo]

    public init(
        fanDiscovery: any FanDiscovering,
        thermalSource: any TrustedThermalReadingSource,
        batteryStatus: any BatteryStatusProviding,
        writeTargets: any FanWriteTargets,
        config: Config,
        clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.fanDiscovery = fanDiscovery
        self.thermalSource = thermalSource
        self.batteryStatus = batteryStatus
        self.writeTargets = writeTargets
        self.config = config
        self.engine = FanControlEngine(config: config.engine)
        self.batteryRule = BatteryCoolingRule(config: config.batteryCooling)
        self.cpuGuard = CpuThrottleGuard(config: config.cpuGuard)
        self.throttles = [:]
        self.lastKnownFans = []
        self.clock = clock
    }

    /// Switches the active mode. The change takes effect on the next tick.
    public func setMode(_ mode: FanMode) {
        config.mode = mode
    }

    /// Advances every reader and state machine once and applies the resulting
    /// fan commands (possibly none) through the write-target seam.
    public func tick() async -> ControlState {
        let now = clock()
        var failures: [ControlFailure] = []
        var fans: [FanInfo] = []

        do {
            fans = try await fanDiscovery.snapshot().fans
            lastKnownFans = fans
        } catch {
            failures.append(.fanReadFailed(reason: String(describing: error)))
        }

        var thermal: TrustedThermalSnapshot?
        do {
            thermal = try await thermalSource.trustedSnapshot()
        } catch {
            failures.append(.thermalSourceFailed(reason: String(describing: error)))
        }

        let battery = await batteryStatus.snapshot()

        // Stale-all: raw readings were delivered but none survived freshness
        // validation. Distinguishable from a valid-empty snapshot (no raw
        // readings, no diagnostics) by the stale diagnostic.
        if let thermal,
           thermal.readings.isEmpty,
           thermal.diagnostics.contains(where: { failure in
               if case .stale = failure { return true } else { return false }
           }) {
            failures.append(.staleAllThermal)
        }

        let fanReadFailed = failures.contains(where: isFanReadFailure)
        let thermalFailed = failures.contains(where: isThermalSourceFailure)
        let staleAll = failures.contains(where: isStaleAllThermal)

        // Restore set: after a fan-read failure we still know the fans from
        // the last successful discovery; otherwise the current snapshot.
        let knownFans = fanReadFailed ? lastKnownFans : fans

        var perFan: [FanControlState] = []
        perFan.reserveCapacity(knownFans.count)
        var actions: [FanWriteAction] = []
        actions.reserveCapacity(knownFans.count)

        if fanReadFailed || thermalFailed || staleAll {
            for fan in knownFans {
                let (decision, throttle) = decide(now: now, fan: fan, proposed: nil, previousRPM: nil)
                throttles[Int(fan.index)] = throttle
                perFan.append(FanControlState(
                    fanIndex: Int(fan.index),
                    effectiveRPM: nil,
                    action: action(for: decision)
                ))
                actions.append(action(for: decision))
            }
        } else if let thermal {
            let fanBounds = knownFans.map { FanBounds(minimumRPM: $0.minimumRPM, maximumRPM: $0.maximumRPM) }
            let targets = engine.tick(
                mode: config.mode,
                curve: config.curve,
                // Policy (confirmed by spec review): the smart curve is driven
                // by the hottest valid allowlisted CPU, GPU, or SoC reading —
                // CPU included (`thermal.hottestControl`). The CPU throttle
                // guard stays independent on the hottest pACC/eACC reading
                // (`thermal.hottestCPU`, 90 °C engage / 88 °C release).
                hottestControlCelsius: thermal.hottestControl?.celsius,
                hottestCPUCelsius: thermal.hottestCPU?.celsius,
                isCharging: battery.isPresent && battery.isCharging,
                batteryTemperatureC: battery.temperatureC,
                fanBounds: fanBounds,
                batteryRule: &batteryRule,
                cpuGuard: &cpuGuard
            )
            for (index, fan) in knownFans.enumerated() {
                let effectiveRPM = targets[index].effectiveRPM
                let proposed: FanWriteCommand?
                if let effectiveRPM {
                    // The engine clamps to the fan's own bounds, so this
                    // validated construction cannot fail; a defensive nil
                    // degrades to an automatic restore rather than a crash.
                    proposed = try? FanWriteCommand(
                        fanIndex: Int(fan.index),
                        mode: .manual,
                        targetRPM: effectiveRPM,
                        minimumRPM: fan.minimumRPM,
                        maximumRPM: fan.maximumRPM
                    )
                } else {
                    proposed = nil
                }
                let (decision, throttle) = decide(now: now, fan: fan, proposed: proposed, previousRPM: fan.currentRPM)
                throttles[Int(fan.index)] = throttle
                perFan.append(FanControlState(
                    fanIndex: Int(fan.index),
                    effectiveRPM: effectiveRPM,
                    action: action(for: decision)
                ))
                actions.append(action(for: decision))
            }
        }

        await writeTargets.apply(actions: actions)

        return ControlState(
            timestampNanos: now,
            fans: fans,
            hottestControl: thermal?.hottestControl,
            hottestCPU: thermal?.hottestCPU,
            battery: battery,
            mode: config.mode,
            failSafe: failures,
            perFan: perFan
        )
    }

    /// Runs one fan's proposal through its throttle, returning the decision
    /// and the advanced throttle for storage.
    private func decide(
        now: UInt64,
        fan: FanInfo,
        proposed: FanWriteCommand?,
        previousRPM: Double?
    ) -> (WriteThrottleDecision, WriteThrottle) {
        var throttle = throttles[Int(fan.index)] ?? WriteThrottle(config: config.throttle)
        let decision = throttle.tick(now: now, proposed: proposed, previousRPM: previousRPM)
        return (decision, throttle)
    }

    private func action(for decision: WriteThrottleDecision) -> FanWriteAction {
        switch decision {
        case .send(.some(let command)):
            return .write(command)
        case .send(.none):
            return .restoreAutomatic
        case .skip:
            return .none
        }
    }
}

private func isFanReadFailure(_ failure: ControlFailure) -> Bool {
    if case .fanReadFailed = failure { return true }
    return false
}

private func isThermalSourceFailure(_ failure: ControlFailure) -> Bool {
    if case .thermalSourceFailed = failure { return true }
    return false
}

private func isStaleAllThermal(_ failure: ControlFailure) -> Bool {
    if case .staleAllThermal = failure { return true }
    return false
}
