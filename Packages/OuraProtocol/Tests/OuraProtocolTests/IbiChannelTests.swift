import XCTest
@testable import OuraProtocol

/// #1071: every decoded R-R must say WHICH optical channel measured it.
///
/// The ring reports the SAME heartbeats on more than one tag — 0x80 green-quality for the whole wear
/// period, 0x6E only while an SpO2 measurement is running — and all of them decoded to `OuraEvent.ibi`
/// with nothing to tell them apart, so the store held roughly two complete copies of every night. The
/// tag is the ONLY thing that separates them at ingest: once the rows are written, the two are
/// distinguishable only by the accident that their quantisation grids differ. These tests pin the label
/// at its source, which is where it has to be right.
final class IbiChannelTests: XCTestCase {
    private let rt: UInt32 = 0x0001_0002   // 65538, as in DecoderGoldenTests

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    private func record(_ hex: String) -> OuraRecord {
        guard let rec = OuraFraming.parseRecord(bytes(hex)) else {
            XCTFail("record failed to parse: \(hex)"); return OuraRecord(type: 0, ringTimestamp: 0, payload: [])
        }
        return rec
    }

    // The three real/golden fixtures already pinned by DecoderGoldenTests, reused so the channel is
    // asserted on exactly the bytes whose VALUES are pinned elsewhere.
    private let green0x80 = "801202000100698c660e652a6a09670f6d2b693e"   // real capture, 6 good beats
    private let spo20x6E  = "6e0a02000100000a141e2832"                   // synthetic, 5 beats
    private let amp0x60   = "601202000100807b77757a78e4ddccd4e8d79d33"   // real capture, 6 beats

    func testGreenQualityDecoderStampsGreenChannel() {
        let ibis = OuraDecoders.decodeGreenIBIQuality(record(green0x80))
        XCTAssertEqual(ibis?.count, 6)
        XCTAssertEqual(ibis?.map(\.channel), Array(repeating: .greenQuality, count: 6))
    }

    func testSpO2DecoderStampsSpO2Channel() {
        let ibis = OuraDecoders.decodeSpO2IBI(record(spo20x6E))
        XCTAssertEqual(ibis?.count, 5)
        XCTAssertEqual(ibis?.map(\.channel), Array(repeating: .spo2Ibi, count: 5))
    }

    func testIbiAmplitudeDecoderStampsAmplitudeChannel() {
        let ibis = OuraDecoders.decodeIBIAmplitude(record(amp0x60))
        XCTAssertEqual(ibis?.count, 6)
        XCTAssertEqual(ibis?.map(\.channel), Array(repeating: .ibiAmplitude, count: 6))
    }

    /// The end-to-end shape of the defect: two records covering the SAME wall-clock moment, one per
    /// channel, both reaching the driver as `.ibi`. Before #1071 the resulting events were
    /// indistinguishable; now the channel survives the driver's dispatch, which is what makes the two
    /// streams separable downstream instead of silently summed.
    func testDriverPreservesTheChannelSoTwoTagsAreDistinguishable() {
        let driver = OuraDriver(ringGen: .gen3, authKey: nil)
        let green = driver.ingest(record: record(green0x80))
        let spo2 = driver.ingest(record: record(spo20x6E))

        func channels(_ events: [OuraEvent]) -> [OuraIBIChannel?] {
            events.compactMap { if case .ibi(let v) = $0 { return v.channel } else { return nil } }
        }
        XCTAssertFalse(green.isEmpty)
        XCTAssertFalse(spo2.isEmpty)
        XCTAssertEqual(Set(channels(green).compactMap { $0 }), [.greenQuality])
        XCTAssertEqual(Set(channels(spo2).compactMap { $0 }), [.spo2Ibi])
        // Both are still emitted: neither channel is dropped at decode. The 0x6E stream is a real second
        // measurement and stays available as the cross-check on green (#1071 "do not delete the rows").
        XCTAssertEqual(channels(green).count + channels(spo2).count, 11)
    }

    /// The raw values are a DURABLE storage format (`rrInterval.srcChannel`, and the `.noopbak` that
    /// carries it between platforms), so renumbering a case would silently relabel stored history.
    /// Pinned here rather than trusted to declaration order.
    func testChannelRawValuesAreTheDurableStorageCodes() {
        XCTAssertEqual(OuraIBIChannel.greenQuality.rawValue, 1)
        XCTAssertEqual(OuraIBIChannel.spo2Ibi.rawValue, 2)
        XCTAssertEqual(OuraIBIChannel.ibiAmplitude.rawValue, 3)
        XCTAssertEqual(OuraIBIChannel.allCases.count, 3)
    }
}
