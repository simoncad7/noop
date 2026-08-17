import Foundation
import WhoopStore
import WhoopProtocol
import SmartBand10Protocol

/// Maps the parsed Smart Band 10 activity channel (the `[ParsedActivityFile]` the live source's
/// `persistFiles` closure hands over) into the SAME WhoopStore tables the UI reads — `dailyMetric`,
/// `sleepSession` (with the band's real per-epoch hypnogram), the generic `metricSeries`, and the
/// per-minute `hrSample` / `rrInterval` streams — under the registered device's OWN id (`deviceId`
/// partition), so a synced night lights up History exactly like a WHOOP or imported night.
/// WHOOP-FIRST: this is the band's PROVIDED data, not a NOOP-computed derivation; NOOP never reads a
/// Xiaomi score (the Mi Fitness app's readiness/stress scores never leave the phone, and only the raw
/// channel is pulled).
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

        // The night's HRV (NOOP-computed from the 0x08 R-R stream), keyed by the day the night ENDED —
        // shared by the daily row's avgHrv/avgSdnn and the metricSeries hrv_* keys below.
        var hrvByDay: [String: HrvMetrics] = [:]
        for s in files.compactMap(\.sleepSession) {
            if let hrv = Self.hrv(for: s) {
                let key = Self.dayKey(timestamp: Int(s.wakeupTime))
                if hrvByDay[key] == nil { hrvByDay[key] = hrv }   // first night on a day wins
            }
        }

        // 1. Daily rollups ← ACTIVITY_DAILY summary + the sleep totals of any night on that day.
        //    Sleep minutes may come from the RICH 0x08 file OR the stage-only 0x03 file (a night can
        //    exist as either — see the 0x08/0x03 preference in step 2), so the rollup reads BOTH.
        var daily: [DailyMetric] = []
        for summary in files.compactMap(\.dailySummary) {
            let day = Self.dayKey(timestamp: Int(summary.timestamp))
            var totalSleep: Double? = nil
            var deep = 0.0, rem = 0.0, light = 0.0, awake = 0.0
            for s in files.compactMap(\.sleepSession) where Self.dayKey(timestamp: Int(s.wakeupTime)) == day {
                let m = SleepStageVocabulary.minutes(s)
                totalSleep = m.total; deep = m.deep; rem = m.rem; light = m.light; awake = m.awake
            }
            if totalSleep == nil {
                for s in files.compactMap(\.sleepStages) where Self.dayKey(timestamp: Int(s.wakeupTime)) == day {
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
                avgHrv: hrvByDay[day]?.rmssdMs,
                recovery: nil,
                strain: nil,
                exerciseCount: nil,
                spo2Pct: summary.spo2Avg.map(Double.init),
                skinTempDevC: nil,
                respRateBpm: nil,
                steps: summary.steps.map(Int.init),
                activeKcalEst: summary.calories.map(Double.init),
                avgSdnn: hrvByDay[day]?.sdnnMs))
        }
        changes += try await store.upsertDailyMetrics(daily, deviceId: deviceId)

        // 2. Sleep sessions ← ACTIVITY_SLEEP (0x08, the RICH file: hypnogram + R-R + HR/SpO2 series) and
        // ACTIVITY_SLEEP_STAGES (0x03, the stage-only file). HRV comes from the night's R-R via HrvCalculator.
        //
        // ONE SESSION PER NIGHT, 0x08 PREFERRED: the channel can carry BOTH files for the same night
        // (the band banks a stage summary in 0x03 and the rich details in 0x08). If their bedTime/wakeupTime
        // match, inserting both is a harmless upsert overwrite — but the 0x03-derived session carries
        // restingHr/avgHrv = nil, and `upsertSleepSessions` is `DO UPDATE`, so the 0x03 row CLOBBERS the
        // 0x08-derived resting-HR and HRV back to NULL (silent loss of exactly the two vitals computed
        // here). If the band refined the sleep bounds between the two files, inserting both creates a
        // DUPLICATE night. So: keep 0x08 for a night, skip the 0x03 file for that same night.
        var nightKeys = Set<String>()
        var sessions: [CachedSleepSession] = []
        for s in files.compactMap(\.sleepSession) {
            nightKeys.insert(Self.dayKey(timestamp: Int(s.wakeupTime)))
            sessions.append(Self.session(fromSleepSession: s))
        }
        for s in files.compactMap(\.sleepStages) where !nightKeys.contains(Self.dayKey(timestamp: Int(s.wakeupTime))) {
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
            // The band's OWN keys — full-field, every scalar the file carries (Metric Explorer +
            // correlations can scan them even if no dedicated screen reads them).
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
            add(day, "active_calories", summary.activeCalories.map(Double.init))
            add(day, "training_load_day", summary.trainingLoadDay.map(Double.init))
            add(day, "training_load_week", summary.trainingLoadWeek.map(Double.init))
            add(day, "training_load_level", summary.trainingLoadLevel.map(Double.init))
            add(day, "recovery_hours", summary.recoveryHours.map(Double.init))
            add(day, "stress_min", summary.stressMin.map(Double.init))
            add(day, "standing_min", summary.standing.map(Double.init))
            add(day, "vitality_light", summary.vitalityLight.map(Double.init))
            add(day, "vitality_moderate", summary.vitalityModerate.map(Double.init))
            add(day, "vitality_high", summary.vitalityHigh.map(Double.init))
            // The night's HRV lands on the day the night ENDED (the morning it's measured for).
            if let hrv = hrvByDay[day] {
                add(day, "hrv_sdnn", hrv.sdnnMs)
                add(day, "hrv_rmssd", hrv.rmssdMs)
            }
            // CANONICAL keys the base band UI / Explore actually read (`MetricCatalog` defines
            // avg_hr/max_hr/vitality under source "xiaomi-band", the catalog Xbox reads by key name for
            // any source via dayOwner/dailyMetric or the generic series). Written ALONGSIDE the keys
            // above so the band's measured values surface in the same charts the Mi Fitness import
            // feeds, regardless of which source id the resolver picks. `active_kcal`/`min_hr` are the
            // `dailyColumn` names the catalog's Energy/HR rows read.
            add(day, "avg_hr", summary.heartRateAvg.map(Double.init))
            add(day, "max_hr", summary.heartRateMax.map(Double.init))
            add(day, "min_hr", summary.heartRateMin.map(Double.init))
            add(day, "active_kcal", summary.activeCalories.map(Double.init))
            add(day, "vitality", summary.vitalityCurrent.map(Double.init))
        }
        for m in files.compactMap(\.manualSamples).flatMap({ $0 }) {
            add(Self.dayKey(timestamp: Int(m.timestamp)), m.type.lowercased(),
                Double(m.value))
        }
        changes += try await store.upsertMetricSeries(points, deviceId: deviceId)

        // 4. Per-minute STREAM rows (hrSample / rrInterval) — the raw beat-level record the Deep Timeline,
        // Stress, and HRV read paths consume, under the device's own id. Idempotent: store.insert is
        // ON CONFLICT-DO-NOTHING on (deviceId, ts), so re-syncing the same files never duplicates.
        //
        // Only HR + R-R are representable here: the band's SpO2 % and per-minute step COUNTS do not fit
        // the store's raw-ADC spo2Sample / cumulative-counter stepSample shapes, so they stay at the
        // daily/rollup level (steps, spo2Pct, the metricSeries keys above) rather than corrupting a
        // stream with semantically different numbers.
        var streams = Streams()

        // Night: minute-resolution HR + beat-to-beat R-R from the sleep-details file (0x08).
        for s in files.compactMap(\.sleepSession) {
            if let series = s.heartRateSeries, let first = series.firstRecordTime,
               !series.samples.isEmpty {
                for (i, bpm) in series.samples.enumerated() {
                    streams.hr.append(HRSample(ts: Int(first) + i * 60, bpm: Int(bpm)))
                }
            }
            // R-R: absolute beat timestamps (epoch ms) → consecutive deltas, stamped at the beat that
            // completes each interval. A jump > 30 s is a recording gap, not a beat — skipped exactly
            // like HrvCalculator, so the raw stream never banks a fake beat across a gap.
            if let pulses = s.heartPulses, pulses.count >= 2 {
                for i in 0..<(pulses.count - 1) {
                    let rrMs = Int(pulses[i + 1] - pulses[i])
                    guard rrMs <= 30_000 else { continue }
                    streams.rr.append(RRInterval(ts: Int(pulses[i + 1] / 1000), rrMs: rrMs))
                }
            }
        }

        // Day: minute-resolution HR from the daily-details file (ACTIVITY_DAILY detail 0).
        for d in files.compactMap(\.dailyDetails) {
            for sample in d.samples {
                if let bpm = sample.heartRate {
                    streams.hr.append(HRSample(ts: Int(sample.timestamp), bpm: Int(bpm)))
                }
            }
        }

        if !streams.hr.isEmpty || !streams.rr.isEmpty {
            let inserted = try await store.insert(streams, deviceId: deviceId)
            changes += inserted.hr + inserted.rr
        }

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

    /// Total / deep / rem / light / awake MINUTES from the stage-only file (`0x03`)'s rollup fields —
    /// the same shape as `minutes(_: SleepSession)`, so a 0x03-only night still feeds the daily rollup.
    static func minutes(_ s: SleepStages) -> (total: Double, deep: Double, rem: Double, light: Double, awake: Double) {
        let total = Double(s.sleepDurationMinutes)
        let deep = Double(s.deepMinutes)
        let rem = Double(s.remMinutes)
        let light = Double(s.lightMinutes)
        let awake = Double(s.awakeMinutes)
        return (total, deep, rem, light, awake)
    }
}
