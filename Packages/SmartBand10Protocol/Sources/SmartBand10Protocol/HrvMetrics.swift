import Foundation

/// Heart-rate-variability metrics computed from the sleep R-R stream.
///
/// Full rationale + measured noise floor in `docs/hrv-rr.md`. Summary: the band
/// records beat-to-beat (R-R) intervals *only* inside the sleep-details file
/// (`subtype 0x08`), as 1 byte per beat = delta × 10 ms. From those we can compute
/// the two time-domain HRV indices Apple Health / Bevel consume:
///
///   - **SDNN**  — std dev of R-R intervals → `heartRateVariabilitySDNN` (Apple Health).
///   - **RMSSD** — RMS of successive differences → no Apple Health type, keep internal.
///
/// The R-R stream is *noisier than ECG* (PPG beat-detection jitter ~115–155 ms), so
/// a raw value is inflated ~2–3×. `HrvCalculator` applies the two lossless cleaning
/// steps from the doc — physiological band + ectopic/missed-beat removal — and stops
/// there: the median-filter smoothing step is deliberately NOT applied because it is
/// a dial that also crushes genuine HRV. Treat the result as a *relative recovery
/// index* (compare to the user's own baseline), not a clinical absolute.
public struct HrvMetrics: Codable, Equatable, Sendable {
    /// SDNN — std dev of cleaned R-R intervals, in ms (Apple Health's HRV type).
    public let sdnnMs: Double
    /// RMSSD — RMS of successive differences, in ms (internal only).
    public let rmssdMs: Double
    /// Median absolute difference of successive R-R intervals, in ms (robust to outliers).
    public let medianAbsDiffMs: Double
    /// Mean R-R interval over the cleaned series, in ms.
    public let meanRrMs: Double
    /// Mean heart rate derived from the cleaned series, in bpm.
    public let meanBpm: Double
    /// Beats that survived cleaning (== intervals used + number of segments).
    public let beatCount: Int
    /// Raw beat count before cleaning.
    public let rawBeatCount: Int
    /// Continuous segments after splitting on recording gaps.
    public let segmentCount: Int

    public init(
        sdnnMs: Double,
        rmssdMs: Double,
        medianAbsDiffMs: Double,
        meanRrMs: Double,
        meanBpm: Double,
        beatCount: Int,
        rawBeatCount: Int,
        segmentCount: Int
    ) {
        self.sdnnMs = sdnnMs
        self.rmssdMs = rmssdMs
        self.medianAbsDiffMs = medianAbsDiffMs
        self.meanRrMs = meanRrMs
        self.meanBpm = meanBpm
        self.beatCount = beatCount
        self.rawBeatCount = rawBeatCount
        self.segmentCount = segmentCount
    }
}

/// Computes HRV from absolute beat timestamps (epoch **milliseconds**, as produced
/// by `SleepSession.heartPulses`).
public enum HrvCalculator {
    /// Physiological band: 300–2000 ms == 30–200 bpm.
    static let rrMinMs = 300.0
    static let rrMaxMs = 2000.0
    /// An R-R jump larger than this is a recording gap, not a real beat — split the
    /// series so we never compute a successive difference across a gap.
    static let gapThresholdMs = 30_000.0
    /// Ectopic / missed beat: an RR more than this multiple of the local median.
    static let ectopicFactor = 1.6
    /// Decoded sleep stages kept for HRV: deep (2) + light (3) have the most stable
    /// PPG and the least motion artifact (see `docs/hrv-rr.md`). Awake (5), REM (4)
    /// and off (0) are excluded.
    public static let hrvKeepStages: Set<UInt8> = [2, 3]

    /// Compute HRV from a list of absolute beat timestamps (epoch ms). Returns `nil`
    /// when there are fewer than two beats, or nothing survives cleaning.
    ///
    /// Pass `stages` (the decoded `0x08` hypnogram) to gate the series to the sleep
    /// stages in `keepStages` (deep + light by default). A beat mapped to any other
    /// stage breaks the series the same way a recording gap does, so a successive
    /// difference is never computed across a stage boundary.
    public static func compute(
        heartPulses: [Int64],
        stages: [SleepStage]? = nil,
        keepStages: Set<UInt8> = hrvKeepStages
    ) -> HrvMetrics? {
        let rawBeatCount = heartPulses.count
        guard rawBeatCount >= 2 else { return nil }

        // Per-beat keep mask — `nil` means "keep every beat" (no stage gating).
        let keepMask: [Bool]?
        if let stages, !stages.isEmpty {
            keepMask = beatKeepMask(heartPulses, stages: stages, keep: keepStages)
        } else {
            keepMask = nil
        }

        // 1 + 2. R-R intervals (ms), splitting the series on recording gaps
        // (a > 30 s jump is not a heartbeat) and on stage boundaries.
        var segments: [[Double]] = []
        var current: [Double] = []
        for i in 0..<(rawBeatCount - 1) {
            let rr = Double(heartPulses[i + 1] - heartPulses[i])
            let crossesStage = keepMask.map { !($0[i] && $0[i + 1]) } ?? false
            if rr > gapThresholdMs || crossesStage {
                if !current.isEmpty { segments.append(current); current = [] }
                continue
            }
            current.append(rr)
        }
        if !current.isEmpty { segments.append(current) }

        // 3. Clean each segment: physiological band → ectopic removal.
        let cleanedSegments = segments.map(cleanSegment).filter { !$0.isEmpty }
        guard !cleanedSegments.isEmpty else { return nil }

        // 4. Pool per-segment statistics so we never diff across a gap boundary.
        var intervalCount = 0
        var sum = 0.0
        var sumSq = 0.0          // Σ rr²  (for SDNN)
        var sumSqDiff = 0.0      // Σ (rr[i+1] − rr[i])²  (for RMSSD)
        var diffCount = 0
        var absDiffs: [Double] = []

        for seg in cleanedSegments {
            let n = seg.count
            intervalCount += n
            for rr in seg {
                sum += rr
                sumSq += rr * rr
            }
            for i in 0..<(n - 1) {
                let d = seg[i + 1] - seg[i]
                sumSqDiff += d * d
                absDiffs.append(abs(d))
                diffCount += 1
            }
        }
        guard intervalCount >= 2 else { return nil }

        let mean = sum / Double(intervalCount)
        // Population variance via E[x²] − mean².
        let variance = max(0, sumSq / Double(intervalCount) - mean * mean)
        let sdnn = variance.squareRoot()
        let rmssd = diffCount > 0 ? (sumSqDiff / Double(diffCount)).squareRoot() : 0
        let mad = median(absDiffs) ?? 0

        return HrvMetrics(
            sdnnMs: sdnn,
            rmssdMs: rmssd,
            medianAbsDiffMs: mad,
            meanRrMs: mean,
            meanBpm: 60_000.0 / mean,
            beatCount: intervalCount + cleanedSegments.count,
            rawBeatCount: rawBeatCount,
            segmentCount: cleanedSegments.count
        )
    }

    /// Drop impossible and ectopic beats within one continuous segment:
    /// (a) physiological band, (b) missed/doubled-beat removal via local median.
    private static func cleanSegment(_ rrs: [Double]) -> [Double] {
        let banded = rrs.filter { $0 >= rrMinMs && $0 <= rrMaxMs }
        guard banded.count >= 3 else { return banded }

        // 1. Merge spurious doubled beats (short + short ≈ normal)
        var merged: [Double] = []
        merged.reserveCapacity(banded.count)
        var i = 0
        while i < banded.count {
            if i + 1 < banded.count {
                let a = banded[i]
                let b = banded[i + 1]
                
                let lo = max(0, i - 2)
                let hi = min(banded.count - 1, i + 3)
                let window = banded[lo...hi].sorted()
                let med = window[window.count / 2]
                
                if a < 0.8 * med && b < 0.8 * med && abs((a + b) - med) < 0.2 * med {
                    merged.append(a + b)
                    i += 2
                    continue
                }
            }
            merged.append(banded[i])
            i += 1
        }

        // 2. Remove missed beats (ectopic / > 1.6x median)
        var out: [Double] = []
        out.reserveCapacity(merged.count)
        for (j, rr) in merged.enumerated() {
            let lo = max(0, j - 2)
            let hi = min(merged.count - 1, j + 2)
            let window = merged[lo...hi].sorted()
            let med = window[window.count / 2]
            if rr <= ectopicFactor * med {
                out.append(rr)
            }
        }

        return out
    }

    /// Map each beat to whether it falls inside a kept stage. `stages` must be sorted
    /// by `timestampSeconds` (the `0x08` hypnogram is built monotonically forward).
    private static func beatKeepMask(_ beats: [Int64], stages: [SleepStage], keep: Set<UInt8>) -> [Bool] {
        var mask: [Bool] = []
        mask.reserveCapacity(beats.count)
        var si = 0
        for b in beats {
            while si + 1 < stages.count && stages[si + 1].timestampSeconds * 1000 <= b {
                si += 1
            }
            mask.append(keep.contains(stages[si].stage))
        }
        return mask
    }

    /// Per-window SDNN over fixed non-overlapping windows, for Apple Health export
    /// (one sample per window) and for a robust night score (median across windows).
    /// Returns one SDNN per window that held at least `minBeats` beats after cleaning.
    public static func windowedSdnn(
        heartPulses: [Int64],
        stages: [SleepStage]? = nil,
        keepStages: Set<UInt8> = hrvKeepStages,
        windowMs: Int64 = 5 * 60_000,
        minBeats: Int = 30
    ) -> [Double] {
        guard let first = heartPulses.first else { return [] }

        var out: [Double] = []
        var current: [Int64] = []
        var windowEnd = first + windowMs

        func flush() {
            if current.count >= minBeats,
               let h = compute(heartPulses: current, stages: stages, keepStages: keepStages) {
                out.append(h.sdnnMs)
            }
            current = []
        }

        for b in heartPulses {
            while b >= windowEnd {
                flush()
                windowEnd += windowMs
            }
            current.append(b)
        }
        flush()

        return out
    }

    /// Median of a non-empty sample — the robust aggregation for windowed SDNN
    /// (the mean is dominated by a few outlier windows).
    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
