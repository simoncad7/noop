import Foundation

/// Transport-agnostic SPPv2 session + auth handshake state machine
/// (port of `xiaomi_band/ble_client.py` `SmartBandClient`).
///
/// The session knows nothing about RFCOMM or BLE: it consumes complete,
/// de-framed SPP packets and returns the packets to send back. The transport
/// layer owns the byte stream, packet framing/deframing and timing (e.g. the
/// realtime keep-alive loop).
public final class Session {
    public enum State: Equatable {
        case disconnected
        case sessionConfigured
        case authNonceSent
        case authStep3Sent
        case encrypted
    }

    public enum Event {
        case deviceInfo(DeviceInfo)
        case battery(Battery)
        case realtime(RealtimeSample)
        /// A fetch (8,1 / 8,2) response listing the available file ids.
        case activityFileIds([ActivityFileId])
        /// One complete activity file, reassembled and parsed.
        case activityFile(ParsedActivityFile)
        case heartRateConfig(interval: UInt32, sleepAdvanced: Bool)
        case spo2Config(allDay: Bool)
        case stressConfig(allDay: Bool)
        case dndConfig(enabled: Bool)
        case unknown(type: UInt32, subtype: UInt32)
    }

    public enum SessionError: Error {
        case invalidPacket
        case hmacMismatch
    }

    public private(set) var state: State = .disconnected
    public private(set) var isEncrypted = false

    private var crypto: XiaomiCrypto
    private var lastClientNonce: [UInt8] = []
    private var txSequence: UInt8 = 0
    private let activityAssembler = ActivityFileAssembler()

    /// When `true` (the default), received activity files are **not** acknowledged
    /// with `8,5`, so the watch keeps them and they can be re-synced (idempotent,
    /// non-destructive). Flip to `false` only once the sync is validated on real
    /// data — acknowledging tells the watch it may delete the file.
    public var keepActivityData = true

    /// Fired once the auth handshake completes. `encrypted` is `true` for a
    /// subtype-27 session and `false` for a subtype-5 (cleartext) session.
    public var onAuthenticated: ((_ encrypted: Bool) -> Void)?
    /// Fired for every decoded command received after auth.
    public var onEvent: ((Event) -> Void)?
    /// Fired when the watch HMAC does not match (likely a wrong auth key).
    public var onAuthFailed: (() -> Void)?

    public init(authKeyHex: String) throws {
        crypto = try XiaomiCrypto(authKeyHex: authKeyHex)
    }

    private func nextSequence() -> UInt8 {
        let s = txSequence
        txSequence = txSequence &+ 1
        return s
    }

    /// First outgoing packet: the SPPv2 session config request.
    @discardableResult
    public func start() -> Data {
        state = .sessionConfigured
        txSequence = 0
        lastClientNonce = []
        isEncrypted = false
        return Spp.buildSessionConfig()
    }

    /// Wrap a protobuf `Command` into an outgoing data packet.
    ///
    /// Matches Gadgetbridge's SPPv2 channel mapping: auth commands (type 1) go
    /// out plaintext on the `Authentication` channel, every other command goes
    /// out ENCRYPTED (`encryptV2`, AES-CTR key-as-IV) on the `ProtobufCommand`
    /// channel. See `XiaomiBleProtocolV2.sendCommand` / `XiaomiSppPacketV2`.
    private func build(command: Xiaomi_Command) throws -> Data {
        var data = try command.serializedData()
        let opcode: UInt8
        let payload: Data
        if isEncrypted {
            payload = Data(try crypto.encryptV2([UInt8](data)))
            opcode = Spp.opcodeSendEncrypted
        } else {
            payload = data
            opcode = Spp.opcodeSendPlaintext
        }

        return Spp.buildDataPacket(
            sequence: nextSequence(),
            channel: Spp.channelProtobuf,
            opcode: opcode,
            payload: payload
        )
    }

    // MARK: - Post-auth data requests

    public func requestDeviceInfo() throws -> Data {
        try build(command: Commands.deviceInfo())
    }

    public func requestBattery() throws -> Data {
        try build(command: Commands.battery())
    }

    public func requestDeviceState() throws -> Data {
        try build(command: Commands.deviceStateGet())
    }

    public func setCurrentTime() throws -> Data {
        return try build(command: Commands.setCurrentTime())
    }

    public func applySettings(hrInterval: UInt32, sleepAdvanced: Bool, spo2AllDay: Bool, stressAllDay: Bool, dndEnabled: Bool) throws -> [Data] {
        let hrCmd = Commands.setHeartRateConfig(interval: hrInterval, sleepAdvanced: sleepAdvanced)
        let spo2Cmd = Commands.setSpO2Config(allDay: spo2AllDay)
        let stressCmd = Commands.setStressConfig(allDay: stressAllDay)
        let dndCmd = Commands.setDndConfig(enabled: dndEnabled)
        return [
            try build(command: hrCmd),
            try build(command: spo2Cmd),
            try build(command: stressCmd),
            try build(command: dndCmd)
        ]
    }

    /// The post-auth init handshake, in order. Mirrors Gadgetbridge
    /// `XiaomiSupport.onAuthSuccess()`: setCurrentTime + deviceInfo +
    /// deviceStateGet + battery. The Band 10 re-sends its CMD_AUTH confirmation
    /// every ~6s until it receives this; skipping it and sending a data command
    /// (e.g. realtime) straight away makes the band drop the BLE link.
    public func postAuthInit() throws -> [Data] {
        [
            try build(command: Commands.setCurrentTime()),
            try build(command: Commands.deviceInfo()),
            try build(command: Commands.deviceStateGet()),
            try build(command: Commands.battery()),
            try build(command: Commands.getHeartRateConfig()),
            try build(command: Commands.getSpO2Config()),
            try build(command: Commands.getStressConfig()),
            try build(command: Commands.getDndConfig())
        ]
    }

    /// Start the realtime HR/steps/calories stream (`type=8, subtype=45`, bare).
    public func startRealtime() throws -> Data {
        try build(command: Commands.realtimeEnable())
    }

    public func stopRealtime() throws -> Data {
        try build(command: Commands.realtimeStop())
    }

    // MARK: - Activity sync (channel 5)

    /// Request today's activity file list (`type=8, subtype=1`).
    public func fetchActivityToday() throws -> Data {
        try build(command: Commands.activityFetchToday())
    }

    /// Request the past activity file list (`type=8, subtype=2`).
    public func fetchActivityPast() throws -> Data {
        try build(command: Commands.activityFetchPast())
    }

    /// Request one activity file by id (`type=8, subtype=3`).
    public func requestActivityFile(_ fileId: ActivityFileId) throws -> Data {
        try build(command: Commands.activityRequestFile(fileId))
    }

    /// Acknowledge a received file (`type=8, subtype=5`) — see `keepActivityData`.
    public func ackActivityFile(_ fileId: ActivityFileId) throws -> Data {
        try build(command: Commands.activityAckFile(fileId))
    }

    // MARK: - Packet handling

    /// Feed one complete received SPP packet (already de-framed: `type`,
    /// `sequence`, `payload`). Returns the packets to write back (ACK + any
    /// auth/response packets), in order.
    @discardableResult
    public func handle(type: UInt8, sequence: UInt8, payload: Data) throws -> [Data] {
        var out: [Data] = []

        switch type {
        case Spp.packetTypeSessionConfig:
            // Session opened → send the phone nonce (auth step 1).
            lastClientNonce = crypto.generateClientNonce()
            txSequence = 0
            out.append(try build(command: Commands.authPhoneNonce(Data(lastClientNonce))))
            state = .authNonceSent

        case Spp.packetTypeData:
            out.append(Spp.buildAckPacket(sequence: sequence))
            guard let (channel, opcode, inner) = Spp.parseDataPacket(payload) else {
                throw SessionError.invalidPacket
            }

            switch state {
            case .authNonceSent:
                let cmd = try Xiaomi_Command(serializedBytes: [UInt8](inner))
                let watchNonce = [UInt8](cmd.auth.watchNonce.nonce)
                let watchHmac = [UInt8](cmd.auth.watchNonce.hmac)

                // Diagnostic dump: what we sent vs what the watch echoed back.
                print("[AUTH] channel=\(channel) opcode=\(opcode) inner=\(Array(inner).hex())")
                print("[AUTH] clientNonce=\(lastClientNonce.hex()) len=\(lastClientNonce.count)")
                print("[AUTH] watchNonce=\(watchNonce.hex()) len=\(watchNonce.count)")
                print("[AUTH] watchHmac=\(watchHmac.hex()) len=\(watchHmac.count)")

                // On a fresh BLE connection the watch sometimes answers the phone
                // nonce with a preliminary auth packet first (an empty subtype-16
                // ack, no nonce/hmac) before sending the real subtype-26 nonce+hmac
                // reply. That preliminary packet is not an auth failure — just
                // ignore it and keep waiting for the nonce.
                if watchNonce.isEmpty || watchHmac.isEmpty {
                    print("[AUTH] empty nonce — ignoring preliminary packet, waiting for watch nonce")
                    return out
                }

                guard crypto.verifyDeviceHmac(
                    clientNonce: lastClientNonce,
                    deviceNonce: watchNonce,
                    deviceHmac: watchHmac
                ) else {
                    print("[AUTH] HMAC MISMATCH")
                    onAuthFailed?()
                    throw SessionError.hmacMismatch
                }

                let step3 = try crypto.generateAuthStep3Data(
                    clientNonce: lastClientNonce,
                    deviceNonce: watchNonce
                )
                let step3Cmd = Commands.authStep3(
                    encryptedNonces: Data(step3.encryptedNonces),
                    encryptedDeviceInfo: Data(step3.encryptedDeviceInfo)
                )
                out.append(try build(command: step3Cmd))
                state = .authStep3Sent

            case .authStep3Sent:
                let cmd = try Xiaomi_Command(serializedBytes: [UInt8](inner))
                if cmd.subtype == Commands.AuthSubtype.step3 || cmd.subtype == Commands.AuthSubtype.cleartextOk {
                    isEncrypted = (cmd.subtype == Commands.AuthSubtype.step3)
                    state = .encrypted
                    onAuthenticated?(isEncrypted)
                }

            case .encrypted:
                if channel == Spp.channelActivity {
                    // Activity file chunks (channel 5), encrypted with opcode 2.
                    let plain: [UInt8]
                    if opcode == Spp.opcodeSendEncrypted {
                        plain = try crypto.decryptV2([UInt8](inner))
                    } else {
                        plain = [UInt8](inner)
                    }
                    out.append(contentsOf: handleActivityChunk(plain))
                    break
                }

                let decrypted: Data
                if channel == Spp.channelProtobuf && opcode == Spp.opcodeSendEncrypted {
                    decrypted = Data(try crypto.decryptV2([UInt8](inner)))
                } else if channel == Spp.channelProtobuf && opcode == Spp.opcodeSendPlaintext {
                    decrypted = inner
                } else {
                    break // ignore other channels
                }
                let cmd = try Xiaomi_Command(serializedBytes: [UInt8](decrypted))
                dispatch(cmd)

            default:
                break
            }

        default:
            break
        }

        return out
    }

    private func dispatch(_ cmd: Xiaomi_Command) {
        // Activity fetch responses (type 8, subtype 1 = today / 2 = past) carry
        // the list of available file ids in `health.activityRequestFileIds`.
        if cmd.type == Commands.CommandType.health
            && (cmd.subtype == Commands.HealthSubtype.activityFetchToday || cmd.subtype == Commands.HealthSubtype.activityFetchPast) {
            let raw = [UInt8](cmd.health.activityRequestFileIds)
            var ids: [ActivityFileId] = []
            var i = 0
            while i + 7 <= raw.count {
                if let fid = ActivityFileId(bytes: Array(raw[i..<(i + 7)])), !fid.isNull {
                    ids.append(fid)
                }
                i += 7
            }
            onEvent?(.activityFileIds(ids))
            return
        }

        if let deviceInfo = Commands.parseDeviceInfo(cmd) {
            onEvent?(.deviceInfo(deviceInfo))
        } else if let hr = Commands.parseHeartRateConfig(cmd) {
            onEvent?(.heartRateConfig(interval: hr.interval, sleepAdvanced: hr.advancedMonitoring.enabled))
        } else if let spo2 = Commands.parseSpO2Config(cmd) {
            onEvent?(.spo2Config(allDay: spo2.allDayTracking))
        } else if let stress = Commands.parseStressConfig(cmd) {
            onEvent?(.stressConfig(allDay: stress.allDayTracking))
        } else if let dnd = Commands.parseDndConfig(cmd) {
            onEvent?(.dndConfig(enabled: dnd.status == 0))
        } else if let battery = Commands.parseBattery(cmd) {
            onEvent?(.battery(battery))
        } else if let realtime = Commands.parseRealtime(cmd) {
            onEvent?(.realtime(realtime))
        } else {
            onEvent?(.unknown(type: cmd.type, subtype: cmd.subtype))
        }
    }

    /// Reassemble channel-5 chunks into a file, parse it, and (optionally) emit
    /// the `8,5` ACK. Returns any packets to write back to the transport.
    private func handleActivityChunk(_ chunk: [UInt8]) -> [Data] {
        guard let fileBytes = activityAssembler.push(chunk) else { return [] }
        let parsed = ActivityParser.parseActivityFile(fileBytes)
        onEvent?(.activityFile(parsed))

        guard !keepActivityData, parsed.error == nil, !parsed.fileId.isNull else { return [] }
        return (try? [ackActivityFile(parsed.fileId)]) ?? []
    }
}
