import XCTest
import CryptoSwift
@testable import SmartBand10Protocol

final class SessionTests: XCTestCase {
    let authKeyHex = "000102030405060708090a0b0c0d0e0f"
    let deviceNonceHex = "ffeeddccbbaa99887766554433221100"

    /// Drive the full handshake to completion and return the watch-side crypto
    /// (keys already derived) for verifying the phone's encrypted traffic.
    @discardableResult
    private func driveToAuthenticated(_ session: Session) throws -> XiaomiCrypto {
        _ = session.start()
        XCTAssertEqual(session.state, .sessionConfigured)

        // Watch answers with a session config packet → phone sends nonce.
        let out1 = try session.handle(type: Spp.packetTypeSessionConfig, sequence: 0, payload: Data())
        let nonceCmd = try commandFromDataPacket(out1[0])
        let clientNonce = [UInt8](nonceCmd.auth.phoneNonce.nonce)
        let deviceNonce = hexBytes(deviceNonceHex)

        var watchCrypto = try XiaomiCrypto(authKeyHex: authKeyHex)
        watchCrypto.deriveSessionKeys(clientNonce: clientNonce, deviceNonce: deviceNonce)
        let deviceHmac = try HMAC(key: watchCrypto.decryptionKey, variant: .sha2(.sha256))
            .authenticate(deviceNonce + clientNonce)

        let watchPacket = try Self.watchNoncePacket(nonce: deviceNonce, hmac: deviceHmac)
        let (wt, ws, wp) = deframe(watchPacket)!
        _ = try session.handle(type: wt, sequence: ws, payload: wp)
        XCTAssertEqual(session.state, .authStep3Sent)

        let okPacket = try Self.authOkPacket()
        let (ot, osq, op) = deframe(okPacket)!
        _ = try session.handle(type: ot, sequence: osq, payload: op)

        return watchCrypto
    }

    func testFullHandshake() throws {
        let session = try Session(authKeyHex: authKeyHex)
        var authenticated: Bool?
        session.onAuthenticated = { authenticated = $0 }

        _ = try driveToAuthenticated(session)

        XCTAssertEqual(session.state, .encrypted)
        XCTAssertEqual(session.isEncrypted, true)
        XCTAssertEqual(authenticated, true)
    }

    func testHandshakeRejectsWrongHmac() throws {
        let session = try Session(authKeyHex: authKeyHex)
        var failed = false
        session.onAuthFailed = { failed = true }

        _ = session.start()
        _ = try session.handle(type: Spp.packetTypeSessionConfig, sequence: 0, payload: Data())
        XCTAssertEqual(session.state, .authNonceSent)

        let watchPacket = try Self.watchNoncePacket(
            nonce: hexBytes(deviceNonceHex),
            hmac: [UInt8](repeating: 0, count: 32)
        )
        let (wt, ws, wp) = deframe(watchPacket)!

        XCTAssertThrowsError(try session.handle(type: wt, sequence: ws, payload: wp)) { error in
            XCTAssertEqual(error as? Session.SessionError, .hmacMismatch)
        }
        XCTAssertTrue(failed)
    }

    func testPostAuthRequestIsEncrypted() throws {
        let session = try Session(authKeyHex: authKeyHex)
        var watchCrypto = try driveToAuthenticated(session)

        let packet = try session.requestBattery()
        let (type, _, payload) = deframe(packet)!
        XCTAssertEqual(type, Spp.packetTypeData)
        let (channel, opcode, inner) = Spp.parseDataPacket(payload)!
        XCTAssertEqual(channel, Spp.channelProtobuf)
        XCTAssertEqual(opcode, Spp.opcodeSendEncrypted)

        // The watch recovers it with the same (symmetric CTR) encryption key.
        let plain = try watchCrypto.encryptV2([UInt8](inner))
        let cmd = try Xiaomi_Command(serializedBytes: plain)
        XCTAssertEqual(cmd.type, 2)
        XCTAssertEqual(cmd.subtype, 1)
    }

    func testRealtimeEventDispatch() throws {
        let session = try Session(authKeyHex: authKeyHex)
        var event: Session.Event?
        session.onEvent = { event = $0 }

        var watchCrypto = try driveToAuthenticated(session)

        // Watch → phone realtime stream (type 8, subtype 47).
        var cmd = Xiaomi_Command()
        cmd.type = 8
        cmd.subtype = 47
        var health = Xiaomi_Health()
        var rts = Xiaomi_RealTimeStats()
        rts.heartRate = 75
        rts.steps = 999
        rts.calories = 12
        rts.standingHours = 2
        health.realTimeStats = rts
        cmd.health = health

        // Watch encrypts with the decryption key (phone decrypts with decryptV2).
        let cipher = try watchCrypto.decryptV2([UInt8](try cmd.serializedData()))
        let watchPacket = Spp.buildDataPacket(
            sequence: 0,
            channel: Spp.channelProtobuf,
            opcode: Spp.opcodeSendEncrypted,
            payload: Data(cipher)
        )
        let (t, s, p) = deframe(watchPacket)!
        _ = try session.handle(type: t, sequence: s, payload: p)

        guard case .realtime(let sample) = event else {
            return XCTFail("expected .realtime, got \(String(describing: event))")
        }
        XCTAssertEqual(sample, RealtimeSample(heartRate: 75, steps: 999, calories: 12, standingHours: 2))
    }

    // MARK: - Helpers

    private static func watchNoncePacket(nonce: [UInt8], hmac: [UInt8]) throws -> Data {
        var cmd = Xiaomi_Command()
        cmd.type = 1
        cmd.subtype = 26
        var auth = Xiaomi_Auth()
        var wn = Xiaomi_WatchNonce()
        wn.nonce = Data(nonce)
        wn.hmac = Data(hmac)
        auth.watchNonce = wn
        cmd.auth = auth
        return Spp.buildDataPacket(
            sequence: 0,
            channel: Spp.channelProtobuf,
            opcode: Spp.opcodeSendPlaintext,
            payload: try cmd.serializedData()
        )
    }

    private static func authOkPacket() throws -> Data {
        var cmd = Xiaomi_Command()
        cmd.type = 1
        cmd.subtype = 27
        return Spp.buildDataPacket(
            sequence: 1,
            channel: Spp.channelProtobuf,
            opcode: Spp.opcodeSendPlaintext,
            payload: try cmd.serializedData()
        )
    }
}
