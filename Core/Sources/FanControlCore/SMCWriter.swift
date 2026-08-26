// MARK: - Write seam (deliberately separate from the read-only executor)

/// Low-level seam for AppleSMC write calls. Shape mirrors `SMCExecuting`
/// (explicit selector + wire image) but is a DISTINCT protocol: writes permit
/// command 6 (`WRITE_BYTES`), which the read-only executor must never see.
///
/// Core ships no IOKit implementation of this protocol — the root helper
/// milestone provides the production one (a serialized connection that
/// validates selector 2 and wire length and permits commands {5,6,8,9}).
/// Unit tests use scripted fakes; command 6 never reaches
/// `AppleSMCIOKitExecutor`.
public protocol WriteExecuting: Sendable {
    func execute(selector: UInt32, request: [UInt8]) async throws -> [UInt8]
}

// MARK: - SMC writing protocol

/// Fakeable contract for the one process that writes SMC (the helper).
public protocol SMCWriting: Sendable {
    /// Applies validated fan write commands. Manual commands write
    /// `F{idx}Md=1` then `F{idx}Tg=encoded target`; automatic commands write
    /// `F{idx}Md=0` only. Strict: never clamps, never writes when the live
    /// mode byte is unknown, never writes when `FNum == 0`.
    func apply(_ commands: [FanWriteCommand]) async throws

    /// Restores Apple automatic control: for every discovered fan, writes
    /// `F{idx}Md=0`. Fanless machines are a no-op (nothing to restore).
    func restoreAutomatic() async throws
}

// MARK: - Typed errors

/// Typed failures for the SMC write path. Transport failures
/// (`SMCTransportError`) pass through unwrapped; this enum adds the
/// write-path policy failures and the partial-write signal.
public enum SMCWriterError: Error, Equatable, Sendable {
    // Pure request-building failures
    /// A command was requested while `FNum == 0`: never written, surfaced.
    case fanCountZero
    /// Fan index outside the discovered fan count (also negative indexes).
    case fanIndexOutOfRange(index: Int, fanCount: UInt8)
    /// Defensive: `FanWriteCommand` already guarantees a manual target.
    case manualMissingTarget
    /// Manual write refused: the live `F{idx}Md` byte is neither 0 nor 1,
    /// so the current SMC state is not understood. `0xFF` when the caller
    /// had no live mode read.
    case unknownMode(index: Int, byte: UInt8)
    /// Target outside the LIVE `[F{idx}Mn, F{idx}Mx]` limits. Never clamped.
    case targetOutOfBounds(minimumRPM: Double, maximumRPM: Double, targetRPM: Double)
    /// Manual write without live `F{idx}Tg` metadata (type/size).
    case missingTargetMetadata(index: Int)
    /// `F{idx}Tg` reports a type other than `flt ` (4 bytes) or `fpe2` (2).
    case unsupportedTargetDataType(index: Int, type: SMCFourCC, size: UInt32)

    // Live-metadata failures
    /// `FNum` did not report `ui8`/1 byte.
    case invalidFanCountMetadata(actualType: String, actualSize: UInt32)
    /// `FNum` reports more fans than the decimal key namespace supports.
    case unsupportedFanCount(UInt8)
    /// `F{idx}Mn`/`F{idx}Mx` did not report `flt `/4 or `fpe2`/2.
    case invalidRPMMetadata(index: Int, key: SMCFourCC, actualType: String, actualSize: UInt32)
    /// Live RPM decoded to a negative value — metadata is garbage.
    case negativeRPM(index: Int, key: SMCFourCC, value: Double)
    /// Live minimum exceeds the live maximum.
    case invalidRPMRange(index: Int, minimum: Double, maximum: Double)
    /// `F{idx}Md` did not report `ui8`/1 byte.
    case invalidModeMetadata(index: Int, actualType: String, actualSize: UInt32)

    /// `F{idx}Md` was written but a later request in the same sequence
    /// (`F{idx}Tg`) failed: a manual target may be half-applied. The caller
    /// MUST restore automatic control.
    case partialWrite(committedFanIndex: Int, failingKey: SMCFourCC, underlyingDescription: String)
}

// MARK: - Pure request building

/// Builds the exact SMC write requests for one validated fan command.
///
/// - Manual: `[F{idx}Md=1 (ui8), F{idx}Tg=encoded target]`. The target is
///   encoded with SMCCodec using the FAN'S REPORTED type read live from
///   `F{idx}Tg` (never inferred from the key name; `flt `/4 or `fpe2`/2).
///   Refuses when the live mode byte is not 0/1 and when the target is
///   outside the live `[min, max]` — never clamped.
/// - Automatic: `[F{idx}Md=0 (ui8)]` only. Mode 0 restores Apple control;
///   no target write.
///
/// `F{idx}Md` metadata is protocol knowledge (`ui8`, size 1); the writer
/// verifies the live read matches before building (invalid mode metadata is
/// a typed error).
public enum FanWriteRequestBuilder {
    /// The restore/manual-mode write request for `F{idx}Md`.
    public static func modeWriteRequest(key: SMCFourCC, modeByte: UInt8) throws -> SMCKeyData {
        try SMCKeyData.writeRequest(
            key: key,
            keyInfo: SMCKeyInfo(dataSize: 1, dataType: try SMCFourCC("ui8 ")),
            payload: [modeByte]
        )
    }

    /// Builds the write requests for one command, validated against live
    /// metadata. `liveModeByte`, `targetDataType`, and `targetDataSize` are
    /// only consulted for manual commands (automatic ignores them).
    public static func requests(
        for command: FanWriteCommand,
        fanCount: UInt8,
        liveMinimumRPM: Double,
        liveMaximumRPM: Double,
        liveModeByte: UInt8?,
        targetDataType: SMCFourCC?,
        targetDataSize: UInt32
    ) throws -> [SMCKeyData] {
        guard fanCount > 0 else {
            throw SMCWriterError.fanCountZero
        }
        guard command.fanIndex >= 0, command.fanIndex < Int(fanCount) else {
            throw SMCWriterError.fanIndexOutOfRange(index: command.fanIndex, fanCount: fanCount)
        }

        let modeKey = try SMCFourCC("F\(command.fanIndex)Md")
        switch command.mode {
        case .automatic:
            return [try modeWriteRequest(key: modeKey, modeByte: 0)]
        case .manual:
            guard let targetRPM = command.targetRPM else {
                throw SMCWriterError.manualMissingTarget
            }
            guard let liveModeByte, liveModeByte == 0 || liveModeByte == 1 else {
                throw SMCWriterError.unknownMode(index: command.fanIndex, byte: liveModeByte ?? 0xFF)
            }
            guard targetRPM >= liveMinimumRPM, targetRPM <= liveMaximumRPM else {
                throw SMCWriterError.targetOutOfBounds(
                    minimumRPM: liveMinimumRPM,
                    maximumRPM: liveMaximumRPM,
                    targetRPM: targetRPM
                )
            }
            guard let targetDataType else {
                throw SMCWriterError.missingTargetMetadata(index: command.fanIndex)
            }
            let typeName = targetDataType.stringValue
            let isFloat = typeName == SMCDataType.float.rawValue && targetDataSize == 4
            let isFpe2 = typeName == SMCDataType.fpe2.rawValue && targetDataSize == 2
            guard isFloat || isFpe2 else {
                throw SMCWriterError.unsupportedTargetDataType(
                    index: command.fanIndex,
                    type: targetDataType,
                    size: targetDataSize
                )
            }
            let payload = try SMCCodec.encode(
                targetRPM,
                dataType: typeName,
                expectedSize: Int(targetDataSize)
            )
            let targetKey = try SMCFourCC("F\(command.fanIndex)Tg")
            let targetInfo = SMCKeyInfo(dataSize: targetDataSize, dataType: targetDataType)
            return [
                try modeWriteRequest(key: modeKey, modeByte: 1),
                try SMCKeyData.writeRequest(key: targetKey, keyInfo: targetInfo, payload: payload),
            ]
        }
    }
}

// MARK: - Production writer

/// Serialized SMC write executor. The only object in Core that issues
/// command 6 (via the injected `WriteExecuting` seam).
///
/// Every manual command re-verifies live state before writing anything:
/// `F{idx}Mn`/`F{idx}Mx` limits (never trust construction-time bounds),
/// `F{idx}Md` mode byte (unknown → refuse), and `F{idx}Tg` reported type
/// (drive encoding). Automatic commands and restores read `F{idx}Md`
/// metadata, validate it, then write `Md=0`.
///
/// All-or-nothing per command: a failure throws immediately; commands before
/// the failure may already be applied, and a `Md`-written-`Tg`-failed
/// sequence surfaces `.partialWrite`. The helper's fail-safe contract is to
/// call `restoreAutomatic()` on any of these failures.
///
/// Note on serialization: `SMCWriter` is an actor with immutable Sendable
/// dependencies, so access is actor-serialized; whole-batch serialization
/// across concurrent callers is the helper milestone's composition concern.
public actor SMCWriter: SMCWriting {
    private let reader: any SMCReading
    private let writeExecutor: any WriteExecuting

    public init(reader: any SMCReading, writeExecutor: any WriteExecuting) {
        self.reader = reader
        self.writeExecutor = writeExecutor
    }

    public func apply(_ commands: [FanWriteCommand]) async throws {
        guard !commands.isEmpty else { return }
        let count = try await fanCount()
        guard count > 0 else {
            throw SMCWriterError.fanCountZero
        }
        for command in commands {
            try await applyOne(command, fanCount: count)
        }
    }

    public func restoreAutomatic() async throws {
        let count = try await fanCount()
        guard count > 0 else { return }
        for index in UInt8(0)..<count {
            let modeKey = try SMCFourCC("F\(index)Md")
            _ = try await modeValue(modeKey, index: Int(index))
            try await write(try FanWriteRequestBuilder.modeWriteRequest(key: modeKey, modeByte: 0))
        }
    }

    // MARK: - Per-command

    private func applyOne(_ command: FanWriteCommand, fanCount: UInt8) async throws {
        guard command.fanIndex >= 0, command.fanIndex < Int(fanCount) else {
            throw SMCWriterError.fanIndexOutOfRange(index: command.fanIndex, fanCount: fanCount)
        }
        let index = command.fanIndex
        let modeKey = try SMCFourCC("F\(index)Md")

        switch command.mode {
        case .automatic:
            _ = try await modeValue(modeKey, index: index)
            try await write(try FanWriteRequestBuilder.modeWriteRequest(key: modeKey, modeByte: 0))

        case .manual:
            let minimumKey = try SMCFourCC("F\(index)Mn")
            let maximumKey = try SMCFourCC("F\(index)Mx")
            let targetKey = try SMCFourCC("F\(index)Tg")

            let liveMinimumRPM = try await rpmValue(minimumKey, index: index)
            let liveMaximumRPM = try await rpmValue(maximumKey, index: index)
            guard liveMinimumRPM <= liveMaximumRPM else {
                throw SMCWriterError.invalidRPMRange(
                    index: index,
                    minimum: liveMinimumRPM,
                    maximum: liveMaximumRPM
                )
            }
            let mode = try await modeValue(modeKey, index: index)
            let targetMetadata = try await reader.read(targetKey)

            let requests = try FanWriteRequestBuilder.requests(
                for: command,
                fanCount: fanCount,
                liveMinimumRPM: liveMinimumRPM,
                liveMaximumRPM: liveMaximumRPM,
                liveModeByte: mode.bytes[0],
                targetDataType: targetMetadata.dataType,
                targetDataSize: targetMetadata.dataSize
            )
            try await execute(requests, fanIndex: index)
        }
    }

    /// Writes a request sequence, surfacing `.partialWrite` when an earlier
    /// request already landed and a later one fails.
    private func execute(_ requests: [SMCKeyData], fanIndex: Int) async throws {
        for (offset, request) in requests.enumerated() {
            do {
                try await write(request)
            } catch {
                if offset > 0, let failingKey = request.keyFourCC {
                    throw SMCWriterError.partialWrite(
                        committedFanIndex: fanIndex,
                        failingKey: failingKey,
                        underlyingDescription: String(describing: error)
                    )
                }
                throw error
            }
        }
    }

    // MARK: - Low-level pieces

    private func fanCount() async throws -> UInt8 {
        let key = try SMCFourCC("FNum")
        let value = try await reader.read(key)
        guard value.dataType.stringValue == SMCDataType.ui8.rawValue,
              value.dataSize == 1 else {
            throw SMCWriterError.invalidFanCountMetadata(
                actualType: value.dataType.stringValue,
                actualSize: value.dataSize
            )
        }
        let count = value.bytes[0]
        guard count <= FanDiscovery.maximumRepresentableFanCount else {
            throw SMCWriterError.unsupportedFanCount(count)
        }
        return count
    }

    private func rpmValue(_ key: SMCFourCC, index: Int) async throws -> Double {
        let value = try await reader.read(key)
        let type = value.dataType.stringValue
        let validMetadata = (type == SMCDataType.float.rawValue && value.dataSize == 4)
            || (type == SMCDataType.fpe2.rawValue && value.dataSize == 2)
        guard validMetadata else {
            throw SMCWriterError.invalidRPMMetadata(
                index: index,
                key: key,
                actualType: type,
                actualSize: value.dataSize
            )
        }
        let decoded = try value.numericValue()
        guard decoded >= 0 else {
            throw SMCWriterError.negativeRPM(index: index, key: key, value: decoded)
        }
        return decoded
    }

    private func modeValue(_ key: SMCFourCC, index: Int) async throws -> SMCValue {
        let value = try await reader.read(key)
        guard value.dataType.stringValue == SMCDataType.ui8.rawValue,
              value.dataSize == 1 else {
            throw SMCWriterError.invalidModeMetadata(
                index: index,
                actualType: value.dataType.stringValue,
                actualSize: value.dataSize
            )
        }
        return value
    }

    private func write(_ request: SMCKeyData) async throws {
        let responseBytes = try await writeExecutor.execute(
            selector: AppleSMCProtocol.ioConnectSelector,
            request: try request.encode()
        )
        guard responseBytes.count == SMCKeyData.wireSize else {
            throw SMCTransportError.malformedResponse(
                expected: SMCKeyData.wireSize,
                actual: responseBytes.count
            )
        }
        let response: SMCKeyData
        do {
            response = try SMCKeyData.decode(responseBytes)
        } catch {
            throw SMCTransportError.malformedResponse(
                expected: SMCKeyData.wireSize,
                actual: responseBytes.count
            )
        }
        if response.result == 132, let expectedKey = request.keyFourCC {
            throw SMCTransportError.keyNotFound(expectedKey)
        }
        guard response.result == 0 else {
            throw SMCTransportError.driverResult(result: response.result, status: response.status)
        }
        guard response.status == 0 else {
            throw SMCTransportError.driverStatus(response.status)
        }
        // Write responses are unmeasured on this host (root writes deferred to
        // the helper milestone): accept the exact key or the zero sentinel,
        // mirroring the measured read behavior, pending live validation.
        if let expectedKey = request.keyFourCC,
           response.key != expectedKey.rawValue,
           response.key != 0 {
            throw SMCTransportError.unexpectedReturnedKey(expected: expectedKey, actual: response.key)
        }
    }
}
