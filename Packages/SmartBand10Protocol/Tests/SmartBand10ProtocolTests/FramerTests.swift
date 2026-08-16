import XCTest
@testable import SmartBand10Protocol

final class FramerTests: XCTestCase {
    func testParsesSinglePacket() {
        let framer = Framer()
        let packets = framer.push(Spp.buildSessionConfig())
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets[0].type, Spp.packetTypeSessionConfig)
    }

    func testParsesPartialThenComplete() {
        let framer = Framer()
        let pkt = Spp.buildDataPacket(
            sequence: 3,
            channel: Spp.channelProtobuf,
            opcode: Spp.opcodeSendPlaintext,
            payload: Data([1, 2, 3, 4, 5])
        )
        let half = pkt.subdata(in: 0..<5)
        let rest = pkt.subdata(in: 5..<pkt.count)

        XCTAssertTrue(framer.push(half).isEmpty)
        let packets = framer.push(rest)
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets[0].sequence, 3)
        XCTAssertEqual(packets[0].payload, Data([0x01, 0x01, 0x01, 0x02, 0x03, 0x04, 0x05]))
    }

    func testResyncOnGarbagePrefix() {
        let framer = Framer()
        var dirty = Data([0x00, 0x11, 0x22, 0x33])
        dirty.append(Spp.buildSessionConfig())
        let packets = framer.push(dirty)
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets[0].type, Spp.packetTypeSessionConfig)
    }

    func testMultiplePacketsInOneChunk() {
        let framer = Framer()
        var data = Data()
        data.append(Spp.buildAckPacket(sequence: 1))
        data.append(Spp.buildAckPacket(sequence: 2))
        let packets = framer.push(data)
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets[0].sequence, 1)
        XCTAssertEqual(packets[1].sequence, 2)
    }
}
