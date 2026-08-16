import XCTest
@testable import SmartBand10Protocol

final class SppTests: XCTestCase {
    func testCRCKnownAnswer() {
        XCTAssertEqual(Spp.calculateChecksum(Array("123456789".utf8)), 0xBB3D)
    }

    func testSessionConfigMatchesPython() {
        XCTAssertEqual(
            Spp.buildSessionConfig().hexString,
            "a5a5020016001d4d0101030001000002020000fc03020020000402001027"
        )
    }

    func testBuildDataPacketMatchesPython() {
        let pkt = Spp.buildDataPacket(
            sequence: 1,
            channel: Spp.channelProtobuf,
            opcode: Spp.opcodeSendPlaintext,
            payload: Data([0x08, 0x01])
        )
        XCTAssertEqual(pkt.hexString, "a5a503010400963c01010801")
    }

    func testParseDataPacket() {
        let parsed = Spp.parseDataPacket(Data([0x01, 0x01, 0x08, 0x01]))
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.channel, 1)
        XCTAssertEqual(parsed?.opcode, 1)
        XCTAssertEqual(parsed?.payload, Data([0x08, 0x01]))
    }

    func testParseDataPacketRejectsShortPayload() {
        XCTAssertNil(Spp.parseDataPacket(Data([0x01])))
    }

    func testAckPacketStructure() {
        let ack = Spp.buildAckPacket(sequence: 5)
        XCTAssertEqual([UInt8](ack.prefix(4)), [0xA5, 0xA5, Spp.packetTypeAck, 5])
        // Empty payload → length 0
        XCTAssertEqual(ack[4], 0)
        XCTAssertEqual(ack[5], 0)
    }
}
