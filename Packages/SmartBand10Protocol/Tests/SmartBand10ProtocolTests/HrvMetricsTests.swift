import XCTest
@testable import SmartBand10Protocol

final class HrvMetricsTests: XCTestCase {

    func testSyntheticConstantRR() throws {
        // 5 beats exactly 1000 ms apart → no variability.
        let pulses: [Int64] = [0, 1000, 2000, 3000, 4000]
        let h = try XCTUnwrap(HrvCalculator.compute(heartPulses: pulses))
        XCTAssertEqual(h.sdnnMs, 0, accuracy: 0.001)
        XCTAssertEqual(h.rmssdMs, 0, accuracy: 0.001)
        XCTAssertEqual(h.meanRrMs, 1000, accuracy: 0.001)
        XCTAssertEqual(h.meanBpm, 60, accuracy: 0.001)
        XCTAssertEqual(h.beatCount, 5)
        XCTAssertEqual(h.rawBeatCount, 5)
        XCTAssertEqual(h.segmentCount, 1)
    }

    func testSyntheticKnownVariance() throws {
        // RR = [800, 1000, 1200] → mean 1000, SDNN ≈ 163.3, RMSSD = 200.
        let pulses: [Int64] = [0, 800, 1800, 3000]
        let h = try XCTUnwrap(HrvCalculator.compute(heartPulses: pulses))
        XCTAssertEqual(h.meanRrMs, 1000, accuracy: 0.001)
        XCTAssertEqual(h.sdnnMs, 163.299, accuracy: 0.1)
        XCTAssertEqual(h.rmssdMs, 200, accuracy: 0.1)
        XCTAssertEqual(h.meanBpm, 60, accuracy: 0.01)
    }

    func testSplitsOnRecordingGap() throws {
        // Two 3-beat clusters separated by a 20-minute gap.
        var pulses: [Int64] = [0, 1000, 2000]
        let gap = Int64(20 * 60 * 1000) // 20 minutes in ms
        pulses += [gap, gap + 1000, gap + 2000]
        let h = try XCTUnwrap(HrvCalculator.compute(heartPulses: pulses))
        XCTAssertEqual(h.segmentCount, 2)
        XCTAssertEqual(h.sdnnMs, 0, accuracy: 0.001) // each segment is perfectly regular
    }

    func testRejectsOutOfBandEctopicBeats() throws {
        // A 5000 ms gap is a "missed beat" artifact, not physiological.
        var pulses: [Int64] = [0, 1000, 2000, 3000]
        pulses += [8000]      // +5000 ms — outside 300..2000 band
        pulses += [9000, 10000]
        let h = try XCTUnwrap(HrvCalculator.compute(heartPulses: pulses))
        // The 5000 ms interval is dropped, the rest stays regular.
        XCTAssertEqual(h.rawBeatCount, 7)
        XCTAssertLessThan(h.beatCount, 7)
        XCTAssertEqual(h.sdnnMs, 0, accuracy: 0.001)
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(HrvCalculator.compute(heartPulses: []))
        XCTAssertNil(HrvCalculator.compute(heartPulses: [1000]))
    }

    // MARK: - Real fixture (docs/hrv-rr.md cross-check)

    func testHrvOnRealSleepFixture() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "ACTIVITY_SLEEP_SUMMARY_1786583580_v5",
                              withExtension: "bin", subdirectory: "Fixtures")
        )
        let data = [UInt8](try Data(contentsOf: url))
        let s = try XCTUnwrap(ActivityParser.parseActivityFile(data).sleepSession)
        let h = try XCTUnwrap(HrvCalculator.compute(heartPulses: s.heartPulses ?? []))

        // Matches the numbers measured in docs/hrv-rr.md:
        //   full-night SDNN ≈ 217 ms, cleaned RMSSD ≈ 180 ms, 4 segments.
        XCTAssertEqual(h.segmentCount, 4)
        XCTAssertEqual(h.sdnnMs, 200.1, accuracy: 2)
        XCTAssertEqual(h.rmssdMs, 167.3, accuracy: 5)
        XCTAssertEqual(h.meanBpm, 51.0, accuracy: 0.5)
        // ~24 400 cleaned beats out of ~24 700 raw (band + ectopic rejection).
        XCTAssertGreaterThan(h.beatCount, 24_000)
        XCTAssertLessThan(h.beatCount, h.rawBeatCount)
    }
}
