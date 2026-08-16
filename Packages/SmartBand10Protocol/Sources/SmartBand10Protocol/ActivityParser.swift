import Foundation

/// Parsers for activity/sleep files received on channel 5 (faithful port of
/// `xiaomi_band/activity.py`, itself ported from Gadgetbridge).
///
/// A complete file is `[fileId 7][padding 1][payload…][CRC32 4]`. Parsers receive
/// the whole file and skip fileId + padding themselves, exactly like the reference.
public enum ActivityParser {

    // MARK: - Dispatch

    /// Parse one complete activity file (with trailing CRC). Repairs a lost
    /// padding byte via Gadgetbridge `fixAndWrap` before parsing.
    public static func parseActivityFile(_ data: [UInt8]) -> ParsedActivityFile {
        // A well-formed file is `fileId(7) + padding(1) + payload(≥0) + CRC(4)`,
        // so 12 bytes is the smallest valid file — an EMPTY payload. The band
        // sends these for days with no minute data yet (e.g. today's unfinished
        // daily-details); treat them as valid-but-empty, not as a parse error.
        guard data.count >= 12 else {
            return ParsedActivityFile(
                fileId: .empty,
                isRaw: true,
                error: "too short (\(data.count) bytes)"
            )
        }

        let fixed = ActivityCRC.fixed(data)
        guard let fileId = ActivityFileId(bytes: Array(fixed.prefix(7))) else {
            return ParsedActivityFile(fileId: .empty, isRaw: true, error: "bad file id")
        }

        var result = ParsedActivityFile(fileId: fileId)

        // Empty payload: nothing to parse, but not an error — just an empty file.
        if fixed.count == 12 {
            return result
        }

        if fileId.type == ActivityConstants.typeActivity {
            if fileId.subtype == 0x00 && fileId.detailType == 0 {
                result.dailyDetails = parseDailyDetails(fixed, fileId: fileId)
            } else if fileId.subtype == 0x00 && fileId.detailType == 1 {
                result.dailySummary = parseDailySummary(fixed, fileId: fileId)
            } else if fileId.subtype == 0x03 {
                result.sleepStages = parseSleepStages(fixed, fileId: fileId)
            } else if fileId.subtype == 0x06 {
                result.manualSamples = parseManualSamples(fixed, fileId: fileId)
            } else if fileId.subtype == 0x08 {
                result.sleepSession = parseSleepDetails(fixed, fileId: fileId)
            } else {
                result.isRaw = true
            }
        } else {
            // Sports files are kept raw for now (see `activity.py`).
            result.isRaw = true
        }

        return result
    }

    // MARK: - Daily details (minute by minute)

    public static func parseDailyDetails(_ data: [UInt8], fileId: ActivityFileId) -> DailyDetails? {
        let version = fileId.version
        let headerSize: Int
        switch version {
        case 1, 2: headerSize = 4
        case 3: headerSize = 5
        case 4: headerSize = 6
        default: return nil
        }

        let buf = ByteReader(data, limit: data.count - 4) // trailing CRC ignored
        _ = buf.read(7)  // fileId
        _ = buf.read(1)  // padding
        let header = buf.read(headerSize)

        let cp = ComplexParser(header: header, buf: buf)
        var ts = fileId.timestamp
        var samples: [DailyDetailSample] = []

        while buf.remaining > 0 {
            cp.reset()
            let startPos = buf.pos
            var sample = DailyDetailSample(timestamp: ts)

            var includeExtraEntry: UInt32 = 0
            if cp.nextGroup(16) {
                if cp.has(1) { includeExtraEntry = cp.get(1, 1) }
                if cp.has(2) { sample.steps = cp.get(2, 14) }
            }
            if cp.nextGroup(8) {
                if cp.has(1) { sample.activeCalories = UInt8(cp.get(2, 6)) }
            }
            _ = cp.nextGroup(8)  // TODO activity?
            if cp.nextGroup(16) {
                if cp.has(0) { sample.distanceCm = cp.get(0, 16) * 100 }
            }
            if cp.nextGroup(8) {
                if cp.has(0) { sample.heartRate = UInt8(cp.get(0, 8)) }
            }
            if cp.nextGroup(8) {
                if cp.has(0) { sample.energy = UInt8(cp.get(0, 8)) }
            }
            _ = cp.nextGroup(16)  // TODO
            if version >= 3 {
                if cp.nextGroup(8) {
                    if cp.has(0) { sample.spo2 = UInt8(cp.get(0, 8)) }
                }
                if cp.nextGroup(8) {
                    if cp.has(0) {
                        let stress = UInt8(cp.get(0, 8))
                        if stress != 255 { sample.stress = stress }
                    }
                }
            }
            if includeExtraEntry == 1 { _ = buf.read(1) }
            if version >= 4 {
                _ = cp.nextGroup(16)  // TODO light
                _ = cp.nextGroup(16)  // TODO momentum
            }

            if buf.pos == startPos { break } // no progress → avoid infinite loop
            samples.append(sample)
            ts += 60 // one minute per sample
        }

        return DailyDetails(samples: samples)
    }

    // MARK: - Daily summary

    public static func parseDailySummary(_ data: [UInt8], fileId: ActivityFileId) -> DailySummary? {
        let version = fileId.version
        let headerSize: Int
        let slotCount: Int
        if version == 3 || version == 4 {
            headerSize = 3
            slotCount = 21
        } else if version == 5 {
            headerSize = 4
            slotCount = 32
        } else {
            return nil
        }

        let buf = ByteReader(data)
        _ = buf.read(7)  // fileId
        _ = buf.read(1)  // padding
        let header = buf.read(headerSize)

        var s = DailySummary(timestamp: fileId.timestamp, timezone: fileId.timezone)

        // Slot table: (field name, wire width). Widths: i32/u16/u8/u24.
        let readers: [(name: String?, format: String)] = [
            ("steps", "i32"), ("active_calories", "u16"), (nil, "u8"),
            ("hr_resting", "u8"), ("hr_max", "u8"), ("hr_max_ts", "i32"),
            ("hr_min", "u8"), ("hr_min_ts", "i32"), ("hr_avg", "u8"),
            ("stress_avg", "u8"), ("stress_max", "u8"), ("stress_min", "u8"),
            ("standing", "u24"), ("calories", "u16"), ("recovery_hours", "u16"),
            (nil, "u8"),
            ("spo2_max", "u8"), ("spo2_max_ts", "i32"), ("spo2_min", "u8"),
            ("spo2_min_ts", "i32"), ("spo2_avg", "u8"),
            ("training_load_day", "u16"), ("training_load_week", "u16"),
            ("training_load_level", "u8"),
            ("vitality_light", "u8"), ("vitality_moderate", "u8"),
            ("vitality_high", "u8"), ("vitality_current", "u16"),
            (nil, "u8"), (nil, "u8"), (nil, "u16"), (nil, "u16"),
        ]

        for i in 0..<slotCount {
            let (name, format) = readers[i]
            let valid = validData(header, i)

            // Always consume the slot's fixed width, even when its bit is 0.
            let val: UInt32
            switch format {
            case "i32": val = buf.getUInt32LE()
            case "u16": val = UInt32(buf.getUInt16LE())
            case "u8": val = UInt32(buf.getUInt8())
            case "u24": val = buf.getUInt24LE()
            default: val = 0
            }

            guard valid, let name else { continue }
            assignSummaryField(&s, name: name, value: val)
        }

        return s
    }

    private static func assignSummaryField(_ s: inout DailySummary, name: String, value: UInt32) {
        switch name {
        case "steps": s.steps = value
        case "active_calories": s.activeCalories = UInt16(value)
        case "hr_resting": s.heartRateResting = UInt8(value)
        case "hr_max": s.heartRateMax = UInt8(value)
        case "hr_max_ts": s.heartRateMaxTimestamp = value
        case "hr_min": s.heartRateMin = UInt8(value)
        case "hr_min_ts": s.heartRateMinTimestamp = value
        case "hr_avg": s.heartRateAvg = UInt8(value)
        case "stress_avg": s.stressAvg = UInt8(value)
        case "stress_max": s.stressMax = UInt8(value)
        case "stress_min": s.stressMin = UInt8(value)
        case "standing": s.standing = value
        case "calories": s.calories = UInt16(value)
        case "recovery_hours": s.recoveryHours = UInt16(value)
        case "spo2_max": s.spo2Max = UInt8(value)
        case "spo2_max_ts": s.spo2MaxTimestamp = value
        case "spo2_min": s.spo2Min = UInt8(value)
        case "spo2_min_ts": s.spo2MinTimestamp = value
        case "spo2_avg": s.spo2Avg = UInt8(value)
        case "training_load_day": s.trainingLoadDay = UInt16(value)
        case "training_load_week": s.trainingLoadWeek = UInt16(value)
        case "training_load_level": s.trainingLoadLevel = UInt8(value)
        case "vitality_light": s.vitalityLight = UInt8(value)
        case "vitality_moderate": s.vitalityModerate = UInt8(value)
        case "vitality_high": s.vitalityHigh = UInt8(value)
        case "vitality_current": s.vitalityCurrent = UInt16(value)
        default: break
        }
    }

    // MARK: - Sleep stages (subtype 0x03)

    public static func parseSleepStages(_ data: [UInt8], fileId: ActivityFileId) -> SleepStages? {
        guard fileId.version == 2 else { return nil }

        let buf = ByteReader(data)
        _ = buf.read(7)  // fileId
        _ = buf.read(1)  // padding
        _ = buf.read(7)  // unk1

        let sleepDuration = buf.getUInt16LE()
        let bedTime = buf.getUInt32LE()
        let wakeupTime = buf.getUInt32LE()
        _ = buf.read(3)  // unk2

        let deep = buf.getUInt16LE()
        let light = buf.getUInt16LE()
        let rem = buf.getUInt16LE()
        let wake = buf.getUInt16LE()

        if bedTime == 0 || wakeupTime == 0 || sleepDuration == 0 { return nil }

        _ = buf.read(1)  // unk3
        var stages: [SleepStage] = []
        while buf.remaining >= 5 {
            let t = buf.getUInt32LE()
            let phase = buf.getUInt8()
            stages.append(SleepStage(timestampSeconds: Int64(t), stage: phase))
        }

        return SleepStages(
            bedTime: bedTime,
            wakeupTime: wakeupTime,
            sleepDurationMinutes: sleepDuration,
            deepMinutes: deep,
            lightMinutes: light,
            remMinutes: rem,
            awakeMinutes: wake,
            stages: stages
        )
    }

    // MARK: - Sleep details (subtype 0x08)

    /// Gadgetbridge's stage mapping for `ptype == 17` hypnogram packets.
    private static let sleepStageDecode: [UInt32: UInt8] = [0: 5, 1: 3, 2: 2, 3: 4, 4: 0]

    private static func decodeSleepStage(_ raw: UInt32) -> UInt8 {
        sleepStageDecode[raw] ?? 1
    }

    public static func parseSleepDetails(_ data: [UInt8], fileId: ActivityFileId) -> SleepSession? {
        let version = fileId.version
        let headerSize: Int
        switch version {
        case 1, 2, 3, 4: headerSize = 1
        case 5: headerSize = 2
        default: return nil
        }

        let buf = ByteReader(data)
        _ = buf.read(7)  // fileId
        _ = buf.read(1)  // padding
        let header = buf.read(headerSize)

        let isAwake = buf.getUInt8()         // headerIdx → 1
        let bedTime = buf.getUInt32LE()      // → 2
        let wakeupTime = buf.getUInt32LE()   // → 3

        var headerIdx = 3

        var sleepQuality: UInt8?
        if version >= 4 {
            if validData(header, headerIdx) { sleepQuality = buf.getUInt8() }
            headerIdx += 1 // → 4
        }

        if version >= 5 {
            _ = buf.read(9)
            _ = buf.getUInt32LE() // bedTime2 (~30 min before bedTime)
            _ = buf.getUInt32LE() // wakeupTime2 (== wakeupTime)
            headerIdx += 5        // → 9
        }

        func readSampleSeries() -> SampleSeries<UInt8> {
            let unit = buf.getUInt16LE()
            let count = buf.getUInt16LE()
            var firstRecordTime: UInt32?
            if count > 0 && version >= 2 { firstRecordTime = buf.getUInt32LE() }
            var samples: [UInt8] = []
            for _ in 0..<count { samples.append(buf.getUInt8()) }
            return SampleSeries(unit: unit, count: count, firstRecordTime: firstRecordTime, samples: samples)
        }

        var heartRateSeries: SampleSeries<UInt8>?
        var spo2Series: SampleSeries<UInt8>?
        var snoreSeries: SampleSeries<Float>?

        if validData(header, headerIdx) { heartRateSeries = readSampleSeries() }
        headerIdx += 1

        if validData(header, headerIdx) { spo2Series = readSampleSeries() }
        headerIdx += 1

        if version >= 3 {
            if validData(header, headerIdx) {
                let unit = buf.getUInt16LE()
                let count = buf.getUInt16LE()
                var firstRecordTime: UInt32?
                if count > 0 { firstRecordTime = buf.getUInt32LE() }
                var values: [Float] = []
                for _ in 0..<count { values.append(buf.getFloat32LE()) }
                snoreSeries = SampleSeries(unit: unit, count: count, firstRecordTime: firstRecordTime, samples: values)
            }
            headerIdx += 1
        }

        var summary = SleepSession(bedTime: bedTime, wakeupTime: wakeupTime, isAwake: isAwake == 1)
        if let sleepQuality { summary.sleepQuality = sleepQuality }
        summary.heartRateSeries = heartRateSeries
        summary.spo2Series = spo2Series
        summary.snoreSeries = snoreSeries

        var stages: [SleepStage] = []
        var heartPulses: [Int64] = []
        // Running timestamp of the last heartbeat, carried ACROSS `type == 1`
        // packets (Gadgetbridge continuity). The band's per-packet RTC `ts` jitters
        // ±several seconds around the true sum of intervals, so resetting to `ts`
        // on every packet (the Python-port bug) inserts a spurious ~2 s gap at each
        // ~10-min boundary and inflates HRV — see `docs/hrv-rr.md`.
        var lastHeartPulseTimestamp: Int64 = 0

        // Stage / R-R packets, each prefixed by magic `fb fa fc ff`.
        while buf.remaining >= 17 {
            guard readStagePacketHeader(buf) else { break }
            _ = buf.getUInt8()        // headerLen (always 17)
            let ts = buf.getUInt64LE()
            _ = buf.getUInt8()        // parity
            let ptype = buf.getUInt8()
            let dataLen = Int(buf.getUInt16BE()) // big-endian

            // Types with no useful payload.
            if ptype == 0x2 || ptype == 0x3 || ptype == 0x9 || ptype == 0xC || ptype == 0xD || ptype == 0xE || ptype == 0xF {
                continue
            }

            guard buf.remaining >= dataLen else { break }
            let raw = buf.read(dataLen)
            let db = ByteReader(raw)

            if ptype == 1 {
                // R-R intervals: one byte per beat = delta × 10 ms. Resync to the
                // packet ts only on > 30 s drift (first packet included).
                if abs(lastHeartPulseTimestamp - Int64(ts)) > 30_000 {
                    lastHeartPulseTimestamp = Int64(ts)
                    heartPulses.append(lastHeartPulseTimestamp)
                }
                while db.remaining > 0 {
                    let delta = Int64(db.getUInt8())
                    lastHeartPulseTimestamp += 10 * delta
                    heartPulses.append(lastHeartPulseTimestamp)
                }
            } else if ptype == 16 {
                let data0 = db.getUInt8()
                summary.wakeCount = data0 & 0x0F
                summary.sleepDurationMinutes = db.getUInt16BE()
                summary.awakeMinutes = db.getUInt16BE()
                summary.lightMinutes = db.getUInt16BE()
                summary.remMinutes = db.getUInt16BE()
                summary.deepMinutes = db.getUInt16BE()
            } else if ptype == 17 {
                // Incremental hypnogram: each packet restarts at bed_time with a
                // refined split. Keep only the last (most complete) one.
                stages = []
                var current = Int64(ts) * 1000
                while db.remaining >= 2 {
                    let val = db.getUInt16BE()
                    let stage = (val >> 12) & 0xF
                    let offsetMin = val & 0xFFF
                    stages.append(SleepStage(timestampSeconds: current / 1000, stage: decodeSleepStage(UInt32(stage))))
                    current += Int64(offsetMin) * 60000
                }
            }
        }

        if !stages.isEmpty { summary.stages = stages }
        if !heartPulses.isEmpty { summary.heartPulses = heartPulses }

        return summary
    }

    /// Scan forward for the `fb fa fc ff` stage-packet magic; skips it on a match.
    private static func readStagePacketHeader(_ buf: ByteReader) -> Bool {
        while buf.remaining >= 17 {
            let b = buf.data
            if b[buf.pos] == 0xFB && b[buf.pos + 1] == 0xFA && b[buf.pos + 2] == 0xFC && b[buf.pos + 3] == 0xFF {
                buf.skip(4)
                return true
            }
            buf.skip(1)
        }
        return false
    }

    // MARK: - Manual samples (subtype 0x06)

    public static func parseManualSamples(_ data: [UInt8], fileId: ActivityFileId) -> [ManualSample]? {
        guard fileId.version == 2 else { return nil }

        let buf = ByteReader(data, limit: data.count - 4)
        _ = buf.read(7)  // fileId
        _ = buf.read(1)  // padding

        var samples: [ManualSample] = []
        while buf.remaining >= 5 {
            let timestamp = buf.getUInt32LE()
            let stype = buf.getUInt8()

            let value: UInt32
            if stype == 0x11 || stype == 0x12 || stype == 0x13 {
                value = UInt32(buf.getUInt8())
            } else if stype == 0x44 {
                value = buf.getUInt32LE()
            } else {
                break // unknown type, size unknowable
            }

            if value == 0 { continue }

            let typeName: String
            switch stype {
            case 0x11: typeName = "hr"
            case 0x12: typeName = "spo2"
            case 0x13: typeName = "stress"
            case 0x44: typeName = "temperature"
            default: typeName = String(format: "0x%02X", stype)
            }
            samples.append(ManualSample(timestamp: timestamp, type: typeName, value: value))
        }

        return samples
    }

    // MARK: - Helpers

    /// Validity bitmap lookup: bit `i` of `header` (MSB-first per byte).
    private static func validData(_ header: [UInt8], _ i: Int) -> Bool {
        (header[i / 8] & (1 << (7 - (i % 8)))) != 0
    }
}

/// Grouped nibble-presence field reader (port of Gadgetbridge
/// `XiaomiComplexActivityParser` / Python `_ComplexParser`).
private final class ComplexParser {
    private let header: [UInt8]
    private let buf: ByteReader
    private var currentGroup = -1
    private var currentGroupBits = 0
    private var currentVal: UInt32 = 0

    init(header: [UInt8], buf: ByteReader) {
        self.header = header
        self.buf = buf
    }

    func reset() {
        currentGroup = -1
        currentGroupBits = 0
        currentVal = 0
    }

    private func nibble() -> Int {
        let byte = Int(header[currentGroup / 2])
        if currentGroup % 2 == 0 { return (byte & 0xF0) >> 4 }
        return byte & 0x0F
    }

    private func consume(_ nBits: Int) -> UInt32 {
        switch nBits {
        case 8: return UInt32(buf.getUInt8())
        case 16: return UInt32(buf.getUInt16LE())
        case 32: return buf.getUInt32LE()
        default: return 0
        }
    }

    func nextGroup(_ nBits: Int) -> Bool {
        currentGroup += 1
        if currentGroup >= header.count * 2 {
            _ = consume(nBits) // advance the buffer to avoid an infinite loop
            return false
        }
        if (nibble() & 8) == 0 { return false } // group absent, nothing to consume
        currentGroupBits = nBits
        currentVal = consume(nBits)
        return true
    }

    func has(_ idx: Int) -> Bool {
        (nibble() & (1 << (2 - idx))) != 0
    }

    func get(_ idx: Int, _ nBits: Int) -> UInt32 {
        let shift = currentGroupBits - idx - nBits
        return (currentVal & (((1 << nBits) - 1) << shift)) >> shift
    }
}
