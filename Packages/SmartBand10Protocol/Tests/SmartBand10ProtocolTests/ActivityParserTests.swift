import XCTest
@testable import SmartBand10Protocol

final class ActivityParserTests: XCTestCase {

    // MARK: - Helpers

    private func readFixture(_ name: String) throws -> [UInt8] {
        if let url = Bundle.module.url(forResource: name, withExtension: "bin", subdirectory: "Fixtures") {
            return [UInt8](try Data(contentsOf: url))
        }
        if let url = Bundle.module.url(forResource: name, withExtension: "bin") {
            return [UInt8](try Data(contentsOf: url))
        }
        throw NSError(domain: "SmartBand10Tests", code: 2, userInfo: [NSLocalizedDescriptionKey: "fixture \(name) not found"])
    }

    // MARK: - CRC32

    func testCRC32Vector() {
        // zlib.crc32 / java.util.zip.CRC32 check value for "123456789".
        XCTAssertEqual(ActivityCRC.crc32(Array("123456789".utf8)), 0xCBF4_3926)
    }

    func testCRCRepairsLostPadding() {
        // A 7-byte fileId + padding + payload + valid CRC should pass through unchanged.
        let data: [UInt8] = [
            0x40, 0x2D, 0xE0, 0x6A, 0x08, 0x05, 0x00,  // fileId (ts=1786583580, tz=8, v=5, flags=0)
            0x00, 0x01, 0x02, 0x03, 0x04,               // padding + payload
        ]
        let crc = ActivityCRC.crc32(data)
        var withCrc = data
        withCrc.append(UInt8(crc & 0xFF))
        withCrc.append(UInt8((crc >> 8) & 0xFF))
        withCrc.append(UInt8((crc >> 16) & 0xFF))
        withCrc.append(UInt8((crc >> 24) & 0xFF))
        XCTAssertEqual(ActivityCRC.fixed(withCrc), withCrc)
    }

    // MARK: - ActivityFileId

    func testFileIdRoundTrip() {
        let fid = ActivityFileId(timestamp: 1786583580, timezone: 8, version: 5, type: 0, subtype: 0x08, detailType: 1)
        let decoded = ActivityFileId(bytes: fid.bytes)
        XCTAssertEqual(decoded, fid)
        XCTAssertEqual(fid.typeName, "ACTIVITY")
        XCTAssertEqual(fid.subtypeName, "ACTIVITY_SLEEP")
        XCTAssertEqual(fid.detailName, "SUMMARY")
        XCTAssertFalse(fid.isNull)
    }

    func testFileIdFlagBitPacking() {
        // subtype = (flags & 0x7F) >> 2, detail = flags & 0x03, type = flags >> 7.
        let fid = ActivityFileId(timestamp: 0, timezone: 0, version: 4, type: 0, subtype: 0x00, detailType: 0)
        XCTAssertEqual(fid.flags, 0x00)
        let sports = ActivityFileId(timestamp: 0, timezone: 0, version: 1, type: 1, subtype: 0x0B, detailType: 2)
        XCTAssertEqual(sports.flags, (1 << 7) | (0x0B << 2) | 2)
    }

    // MARK: - Assembler

    func testAssemblerReassemblesChunks() {
        let payload: [UInt8] = Array(0..<20)
        let assembler = ActivityFileAssembler()
        // 3 chunks of [total u16][num u16][data…]
        XCTAssertNil(assembler.push([3, 0, 1, 0] + payload[0..<7]))
        XCTAssertNil(assembler.push([3, 0, 2, 0] + payload[7..<14]))
        let done = assembler.push([3, 0, 3, 0] + payload[14..<20])
        XCTAssertEqual(done, payload)
    }

    // MARK: - Sleep details (subtype 0x08) — real fixture

    func testParseSleepDetailsFixture() throws {
        let data = try readFixture("ACTIVITY_SLEEP_SUMMARY_1786583580_v5")
        let parsed = ActivityParser.parseActivityFile(data)
        XCTAssertNil(parsed.error, "unexpected error: \(parsed.error ?? "")")

        let s = try XCTUnwrap(parsed.sleepSession)
        XCTAssertEqual(s.bedTime, UInt32(1786583580))
        XCTAssertEqual(s.wakeupTime, UInt32(1786612680))
        XCTAssertTrue(s.isAwake)
        XCTAssertEqual(s.sleepQuality, .some(0))
        XCTAssertEqual(s.sleepDurationMinutes, .some(482))
        XCTAssertEqual(s.deepMinutes, .some(168))
        XCTAssertEqual(s.lightMinutes, .some(182))
        XCTAssertEqual(s.remMinutes, .some(132))
        XCTAssertEqual(s.awakeMinutes, .some(3))
        XCTAssertEqual(s.wakeCount, .some(1))
        XCTAssertEqual(s.stages?.count, .some(33))
        // 24730 beats + 4 resync beats (one per `type == 1` packet, Gadgetbridge
        // continuity — see docs/hrv-rr.md) = 24734.
        XCTAssertEqual(s.heartPulses?.count, .some(24734))
        XCTAssertEqual(s.heartRateSeries?.samples.count, .some(567))
        XCTAssertNil(s.spo2Series)
    }

    func testParseSleepDetailsEmptyFixture() throws {
        let data = try readFixture("ACTIVITY_SLEEP_SUMMARY_1786616700_v5")
        let parsed = ActivityParser.parseActivityFile(data)
        let s = try XCTUnwrap(parsed.sleepSession)
        XCTAssertEqual(s.bedTime, UInt32(1786616700))
        XCTAssertEqual(s.wakeupTime, UInt32(1786618320))
        XCTAssertEqual(s.sleepDurationMinutes, .some(27))
        XCTAssertEqual(s.heartRateSeries?.samples.count, .some(71))
        XCTAssertEqual(s.stages?.count ?? 0, 0)
        XCTAssertEqual(s.heartPulses?.count ?? 0, 0)
    }

    // MARK: - Daily summary (detail 1, v5) — real fixture

    func testParseDailySummaryFixture() throws {
        let data = try readFixture("ACTIVITY_DAILY_SUMMARY_1786572000_v5")
        let parsed = ActivityParser.parseActivityFile(data)
        let s = try XCTUnwrap(parsed.dailySummary)

        XCTAssertEqual(s.steps, .some(530))
        XCTAssertEqual(s.activeCalories, .some(145))
        XCTAssertEqual(s.heartRateResting, .some(41))
        XCTAssertEqual(s.heartRateMax, .some(106))
        XCTAssertEqual(s.heartRateMaxTimestamp, .some(1786626740))
        XCTAssertEqual(s.heartRateMin, .some(75))
        XCTAssertEqual(s.heartRateMinTimestamp, .some(1786626980))
        XCTAssertEqual(s.heartRateAvg, .some(91))
        XCTAssertEqual(s.standing, .some(32768))
        XCTAssertEqual(s.calories, .some(145))
        XCTAssertEqual(s.spo2Max, .some(96))
        XCTAssertEqual(s.spo2MaxTimestamp, .some(1786627017))
        XCTAssertEqual(s.spo2Min, .some(96))
        XCTAssertEqual(s.spo2MinTimestamp, .some(1786627017))
        XCTAssertEqual(s.spo2Avg, .some(96))
        XCTAssertEqual(s.vitalityCurrent, .some(82))
    }

    // MARK: - Daily details (detail 0, v4) — real fixture

    func testParseDailyDetailsFixture() throws {
        let data = try readFixture("ACTIVITY_DAILY_DETAILS_1786621200_v4")
        let parsed = ActivityParser.parseActivityFile(data)
        let d = try XCTUnwrap(parsed.dailyDetails)

        XCTAssertEqual(d.samples.count, 85)
        let first = try XCTUnwrap(d.samples.first)
        XCTAssertEqual(first.timestamp, UInt32(1786621200))
        XCTAssertEqual(first.steps, .some(0))
        XCTAssertEqual(first.activeCalories, .some(0))
        XCTAssertEqual(first.distanceCm, .some(0))
        XCTAssertEqual(first.heartRate, .some(64))
        XCTAssertNil(first.energy)
        XCTAssertEqual(first.spo2, .some(0))
        XCTAssertEqual(first.stress, .some(0))
    }

    func testParseDailyDetailsLargerFixture() throws {
        let data = try readFixture("ACTIVITY_DAILY_DETAILS_1786581300_v4")
        let parsed = ActivityParser.parseActivityFile(data)
        let d = try XCTUnwrap(parsed.dailyDetails)

        XCTAssertEqual(d.samples.count, 665)
        let first = try XCTUnwrap(d.samples.first)
        XCTAssertEqual(first.timestamp, UInt32(1786581300))
        XCTAssertEqual(first.heartRate, .some(59))
        XCTAssertEqual(first.activeCalories, .some(1))
    }

    func testDailySummaryRejectsLowHeartRateValues() {
        let fileId = ActivityFileId(timestamp: 1786572000, timezone: 0, version: 5, type: 0, subtype: 0x00, detailType: 1)
        var data: [UInt8] = fileId.bytes
        data.append(0x00) // padding
        // Header: 4 bytes bitmask (all slots valid)
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        // Slot 0: steps (i32) -> 100
        data.append(contentsOf: [100, 0, 0, 0])
        // Slot 1: active_calories (u16) -> 50
        data.append(contentsOf: [50, 0])
        // Slot 2: nil (u8)
        data.append(0)
        // Slot 3: hr_resting (u8) -> 0 (should be rejected -> nil)
        data.append(0)
        // Slot 4: hr_max (u8) -> 120 (valid)
        data.append(120)
        // Slot 5: hr_max_ts (i32) -> 1786572100
        data.append(contentsOf: [0x50, 0x00, 0x00, 0x00])
        // Slot 6: hr_min (u8) -> 5 (should be rejected -> nil)
        data.append(5)
        // Slot 7: hr_min_ts (i32) -> 0
        data.append(contentsOf: [0, 0, 0, 0])
        // Slot 8: hr_avg (u8) -> 9 (should be rejected -> nil)
        data.append(9)
        // Remaining slots padding so buffer doesn't underrun
        data.append(contentsOf: [UInt8](repeating: 0, count: 100))

        let parsed = ActivityParser.parseDailySummary(data, fileId: fileId)
        XCTAssertNotNil(parsed)
        XCTAssertNil(parsed?.heartRateResting, "RHR < 10 bpm must be rejected and stay nil")
        XCTAssertNil(parsed?.heartRateMin, "Min HR < 10 bpm must be rejected and stay nil")
        XCTAssertNil(parsed?.heartRateAvg, "Avg HR < 10 bpm must be rejected and stay nil")
        XCTAssertEqual(parsed?.heartRateMax, 120, "Valid HR >= 10 bpm should be retained")
    }
}
