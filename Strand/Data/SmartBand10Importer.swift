import Foundation
import WhoopStore
import SmartBand10Protocol

/// Maps the parsed Smart Band 10 activity channel (the `[ParsedActivityFile]` the live source's
/// `persistFiles` closure hands over) into the SAME WhoopStore tables the UI reads — `dailyMetric`,
/// `sleepSession` (with the band's real per-epoch hypnogram), and the generic `metricSeries` — under
/// the registered device's OWN id (`deviceId` partition), so a synced night lights up History exactly
/// like a WHOOP or imported night. WHOOP-FIRST: this is the band's PROVIDED data, not a NOOP-computed
/// derivation; NOOP never reads a Xiaomi score (the Mi Fitness app's readiness/stress scores never
/// leave the phone, and only the raw channel is pulled).
///
/// HRV is the ONE thing computed here (not read off the band): `HrvCalculator` derives SDNN / RMSSD
/// from the sleep file's R-R beat stream (`heartPulses`) gated to deep+light stages — the same
/// documented method the WHOOP path uses (docs/hrv-rr.md), so the `avgHrv`/`avgSdnn` columns carry a
/// NOOP-consistent value rather than a Xiaomi estimate. Everything else (steps, resting HR, SpO2 %,
/// stress, stage minutes, the hypnogram itself) is the band's own measured value, mapped field-for-field.
enum SmartBand10Importer {

    /// Ingest one sync run's parsed files. Idempotent: every table upserts on its natural key
    /// (deviceId, day) / (deviceId, startTs) / (deviceId, day, key), so re-syncing the same files (the
    /// band keeps them un-acked) refreshes in place instead of duplicating. Returns the summed
    /// SQLite changes across the three writes (0 when nothing changed).
    @discardableResult
    static func ingest(_ files: [ParsedActivityFile], into store: WhoopStore,
                       deviceId: String) async throws -> Int {
        var changes = 0

        // 1. Daily rollups ← ACTIVITY_DAILY summary + the sleep totals of any night on that day.
        var daily: [DailyMetric] = []
        for summary in files.compactMap(\.dailySummary) {
            let day = Self.dayKey(timestamp: Int(summary.timestamp))
            // A night's stage minutes (from the same day's sleep file) feed totalSleepMin/deep/rem/light
            // so the daily row is complete even before a sleep session is read.
            var totalSleep: Double? = nil
            var deep = 0.0, rem = 0.0, light = 0.0, awake = 0.0
            for s in files.compactMap(\.sleepSession) {
                if Self.dayKey(timestamp: Int(s.wakeupTime)) == day {
                    let m = SleepStageVocabulary.minutes(s)
                    totalSleep = m.total; deep = m.deep; rem = m.rem; light = m.light; awake = m.awake
                }
            }
            daily.append(DailyMetric(
                day: day,
                totalSleepMin: totalSleep,
                efficiency: totalSleep.map { min(100, $0 / max(1, $0 + awake) * 100) },
                deepMin: deep > 0 ? deep : nil,
                remMin: rem > 0 ? rem : nil,
                lightMin: light > 0 ? light : nil,
                disturbances: nil,
                restingHr: summary.heartRateResting.map(Int.init),
                avgHrv: nil,        // set from the sleep file's R-R below, when the same day has one
                recovery: nil,
                strain: nil,
                exerciseCount: nil,
                spo2Pct: summary.spo2Avg.map(Double.init),
                skinTempDevC: nil,
                respRateBpm: nil,
                steps: summary.steps.map(Int.init),
                activeKcalEst: summary.calories.map(Double.init)))
        }
        changes += try await store.upsertDailyMetrics(daily, deviceId: deviceId)

        // 2. Sleep sessions ← ACTIVITY_SLEEP (0x08, the RICH file: hypnogram + R-R + HR/SpO2 series) and
        // ACTIVITY_SLEEP_STAGES (0x03, the stage-only file). HRV comes from the night's R-R via HrvCalculator.
        var sessions: [CachedSleepSession] = []
        for s in files.compactMap(\.sleepSession) {
            sessions.append(Self.session(fromSleepSession: s))
        }
        for s in files.compactMap(\.sleepStages) {
            sessions.append(Self.session(fromSleepStages: s))
        }
        changes += try await store.upsertSleepSessions(sessions, deviceId: deviceId)

        // 3. Generic metric series — every scalar keyed, for the Metric Explorer + correlations.
        var points: [MetricPoint] = []
        func add(_ day: String, _ key: String, _ v: Double?) {
            if let v { points.append(MetricPoint(day: day, key: key, value: v)) }
        }
        for summary in files.compactMap(\.dailySummary) {
            let day = Self.dayKey(timestamp: Int(summary.timestamp))
            add(day, "steps", summary.steps.map(Double.init))
            add(day, "rhr", summary.heartRateResting.map(Double.init))
            add(day, "hr_avg", summary.heartRateAvg.map(Double.init))
            add(day, "hr_min", summary.heartRateMin.map(Double.init))
            add(day, "hr_max", summary.heartRateMax.map(Double.init))
            add(day, "spo2", summary.spo2Avg.map(Double.init))
            add(day, "spo2_min", summary.spo2Min.map(Double.init))
            add(day, "spo2_max", summary.spo2Max.map(Double.init))
            add(day, "stress", summary.stressAvg.map(Double.init))
            add(day, "stress_max", summary.stressMax.map(Double.init))
            add(day, "energy_kcal", summary.calories.map(Double.init))
            add(day, "training_load_day", summary.trainingLoadDay.map(Double.init))
            // The night's HRV lands on the day the night ENDED (the morning it's measured for).
            if let s = files.compactMap(\.sleepSession).first(where: {
                Self.dayKey(timestamp: Int($0.wakeupTime)) == day
            }), let hrv = Self.hrv(for: s) {
                add(day, "hrv_sdnn", hrv.sdnnMs)
                add(day, "hrv_rmssd", hrv.rmssdMs)
            }
        }
        for m in files.compactMap(\.manualSamples).flatMap({ $0 }) {
            add(Self.dayKey(timestamp: Int(m.timestamp)), m.type.lowercased(),
                Double(m.value))
        }
        changes += try await store.upsertMetricSeries(points, deviceId: deviceId)

        return changes
    }

    // MARK: - Sleep session mapping

    /// CachedSleepSession from the RICH sleep-details file. HRV is NOOP-computed from the night's R-R
    /// (never a Xiaomi number); restingHr is the night's minimum HR from the per-minute series (nil if
    /// the series is missing); the hypnogram is the band's decoded `0x08` stages.
    static func session(fromSleepSession s: SleepSession) -> CachedSleepSession {
        let startTs = Int(s.bedTime)
        let endTs = Int(s.wakeupTime)
        let segs = stageSegments(s)
        let hrv = Self.hrv(for: s)
        return CachedSleepSession(
            startTs: startTs,
            endTs: endTs,
            efficiency: efficiency(segs: segs, start: startTs, end: endTs),
            restingHr: s.heartRateSeries?.samples.min().map(Int.init),
            avgHrv: hrv?.rmssdMs,
            stagesJSON: segs.isEmpty ? nil : Self.stagesJSON(segs))
    }

    /// CachedSleepSession from the stage-only file (`0x03`). No R-R/HR series here, so HRV and resting
    /// HR stay nil (NOOP never fabricates them); the hypnogram is the raw decoded stages.
    static func session(fromSleepStages s: SleepStages) -> CachedSleepSession {
        let startTs = Int(s.bedTime)
        let endTs = Int(s.wakeupTime)
        let segs = stageSegments(fromStages: s.stages, wakeupTime: endTs)
        return CachedSleepSession(
            startTs: startTs,
            endTs: endTs,
            efficiency: efficiency(segs: segs, start: startTs, end: endTs),
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: segs.isEmpty ? nil : Self.stagesJSON(segs))
    }

    /// The night's NOOP-computed HRV from the R-R beat stream, gated to deep+light stages. nil when the
    /// file has no beats or nothing survives cleaning — never a fabricated number.
    static func hrv(for s: SleepSession) -> HrvMetrics? {
        guard let pulses = s.heartPulses, !pulses.isEmpty else { return nil }
        return HrvCalculator.compute(heartPulses: pulses, stages: s.stages)
    }

    // MARK: - Hypnogram → stagesJSON ({start,end,stage} segments, the same shape the WHOOP stager writes)

    /// A contiguous `[start,end]` hypnogram segment. `stage` is the stager-vocabulary token.
    struct Segment {
        var start: Int
        var end: Int
        let stage: String
    }

    /// Build contiguous segments from the decoded per-epoch stage array. Each entry is the start of an
    /// epoch; the end is the next entry's start (or the wakeup time for the last). Adjacent equal stages
    /// merge into one segment, exactly like `OuraSleepSessionMapping`.
    static func stageSegments(_ s: SleepSession) -> [Segment] {
        guard let stages = s.stages, !stages.isEmpty else { return [] }
        return stageSegments(fromStages: stages, wakeupTime: Int(s.wakeupTime))
    }

    static func stageSegments(fromStages stages: [SleepStage], wakeupTime: Int) -> [Segment] {
        var segs: [Segment] = []
        for (i, st) in stages.enumerated() {
            let start = Int(st.timestampSeconds)
            let end = (i + 1 < stages.count) ? Int(stages[i + 1].timestampSeconds) : wakeupTime
            let stage = Self.token(stage: st.stage)
            if var last = segs.last, last.stage == stage, last.end == start {
                last.end = max(last.end, end)
                segs[segs.count - 1] = last
            } else {
                segs.append(Segment(start: start, end: max(end, start + 1), stage: stage))
            }
        }
        return segs
    }

    /// The on-device stage-vocabulary token for a decoded protocol stage. Decoded codes (Gadgetbridge's
    /// `0x08` mapping): 5 = awake, 3 = light, 2 = deep, 4 = REM, 0 = off; anything else = unknown. All
    /// non-asleep codes map to "wake" exactly like the stager's own convention (awake is written "wake").
    static func token(stage: UInt8) -> String {
        switch stage {
        case 3: return "light"
        case 2: return "deep"
        case 4: return "rem"
        default: return "wake"
        }
    }

    /// Hand-built JSON in the stager's FIXED key order (start,end,stage) so it round-trips with the WHOOP
    /// / imported nights byte-for-byte (`SleepStageTotals.minutes` decodes exactly this shape).
    static func stagesJSON(_ segs: [Segment]) -> String? {
        let json = "[" + segs.map {
            "{\"start\":\($0.start),\"end\":\($0.end),\"stage\":\"\($0.stage)\"}"
        }.joined(separator: ",") + "]"
        return json == "[]" ? nil : json
    }

    // MARK: - Helpers

    /// Asleep fraction of in-bed time, from the hypnogram segments (same definition as `XiaomiImporter`).
    static func efficiency(segs: [Segment], start: Int, end: Int) -> Double? {
        guard end > start, !segs.isEmpty else { return nil }
        var asleep = 0
        for seg in segs {
            guard !SleepStageVocabulary.isWake(seg.stage) else { continue }
            asleep += max(0, seg.end - seg.start)
        }
        return min(100, Double(asleep) / Double(end - start) * 100)
    }

    /// UTC YYYY-MM-DD key from an epoch — the DailyMetric natural key (the band's `timezone` byte is a
    /// UTC-offset hint; NOOP stores local days, so we key on UTC like every other import).
    static func dayKey(timestamp: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let comps = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }
}

/// Minimal stage-vocabulary mirror so the importer stays decoupled from StrandAnalytics (the Xiaomi
/// importer imports it; this one is a thin, local twin — `isWake` is the only predicate used).
private enum SleepStageVocabulary {
    /// A stage token represents wake/out-of-bed (stager's convention: awake is written "wake").
    static func isWake(_ token: String) -> Bool {
        token == "wake" || token == "awake"
    }

    /// Total / deep / rem / light / awake MINUTES from a sleep-details file's stage-minute fields
    /// (the band's own rollups; nil fields treated as 0).
    static func minutes(_ s: SleepSession) -> (total: Double, deep: Double, rem: Double, light: Double, awake: Double) {
        let total = Double(s.sleepDurationMinutes ?? 0)
        let deep = Double(s.deepMinutes ?? 0)
        let rem = Double(s.remMinutes ?? 0)
        let light = Double(s.lightMinutes ?? 0)
        let awake = Double(s.awakeMinutes ?? 0)
        return (total, deep, rem, light, awake)
    }
}
