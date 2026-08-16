import Foundation

/// Public `Codable` models for every piece of health data pulled on the activity
/// channel (5). They mirror the Python `activity.py` parser output 1:1, so the app
/// can persist them as JSON and later export them to Apple Health without a schema
/// change.

/// A homogeneous sample series (`unit` + `count` + optional first-record epoch +
/// samples), as read by `parse_sleep_details`.
public struct SampleSeries<T: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let unit: UInt16
    public let count: UInt16
    /// Epoch seconds of the first record (present for v≥2 series with count > 0).
    public let firstRecordTime: UInt32?
    public let samples: [T]

    public init(unit: UInt16, count: UInt16, firstRecordTime: UInt32?, samples: [T]) {
        self.unit = unit
        self.count = count
        self.firstRecordTime = firstRecordTime
        self.samples = samples
    }
}

/// One hypnogram point: the sleep stage active at `timestampSeconds`.
public struct SleepStage: Codable, Equatable, Sendable {
    /// Epoch seconds at which this stage window starts.
    public let timestampSeconds: Int64
    /// Stage code. The meaning depends on the source (see the owning model):
    /// sleep-details (`0x08`) stages are decoded via Gadgetbridge's mapping, while
    /// sleep-stages (`0x03`) stages are the raw byte.
    public let stage: UInt8

    public init(timestampSeconds: Int64, stage: UInt8) {
        self.timestampSeconds = timestampSeconds
        self.stage = stage
    }
}

/// Sleep details — `ACTIVITY_SLEEP` (subtype `0x08`), any supported version.
/// This is the richest sleep file: R-R intervals, HR/SpO₂ series, and hypnogram.
public struct SleepSession: Codable, Equatable, Sendable {
    public let bedTime: UInt32
    public let wakeupTime: UInt32
    public let isAwake: Bool

    public var sleepQuality: UInt8?
    public var sleepDurationMinutes: UInt16?
    public var deepMinutes: UInt16?
    public var lightMinutes: UInt16?
    public var remMinutes: UInt16?
    public var awakeMinutes: UInt16?
    public var wakeCount: UInt8?

    /// Minute-resolution heart-rate series over the night (u8 per sample).
    public var heartRateSeries: SampleSeries<UInt8>?
    /// Minute-resolution SpO₂ series over the night (u8 per sample).
    public var spo2Series: SampleSeries<UInt8>?
    /// Snore series (v≥3), f32 per sample.
    public var snoreSeries: SampleSeries<Float>?

    /// Hypnogram (ptype 17 packets), stage decoded via Gadgetbridge's mapping.
    public var stages: [SleepStage]?
    /// Absolute beat timestamps (epoch **milliseconds**) from the R-R packets
    /// (ptype 1, delta × 10 ms). One entry per detected heartbeat.
    public var heartPulses: [Int64]?

    public init(bedTime: UInt32, wakeupTime: UInt32, isAwake: Bool) {
        self.bedTime = bedTime
        self.wakeupTime = wakeupTime
        self.isAwake = isAwake
    }
}

/// Sleep stages — `ACTIVITY_SLEEP_STAGES` (subtype `0x03`, version 2).
public struct SleepStages: Codable, Equatable, Sendable {
    public let bedTime: UInt32
    public let wakeupTime: UInt32
    public let sleepDurationMinutes: UInt16
    public let deepMinutes: UInt16
    public let lightMinutes: UInt16
    public let remMinutes: UInt16
    public let awakeMinutes: UInt16
    public let stages: [SleepStage]

    public init(
        bedTime: UInt32,
        wakeupTime: UInt32,
        sleepDurationMinutes: UInt16,
        deepMinutes: UInt16,
        lightMinutes: UInt16,
        remMinutes: UInt16,
        awakeMinutes: UInt16,
        stages: [SleepStage]
    ) {
        self.bedTime = bedTime
        self.wakeupTime = wakeupTime
        self.sleepDurationMinutes = sleepDurationMinutes
        self.deepMinutes = deepMinutes
        self.lightMinutes = lightMinutes
        self.remMinutes = remMinutes
        self.awakeMinutes = awakeMinutes
        self.stages = stages
    }
}

/// Daily summary — `ACTIVITY_DAILY` detail `1` (version 3/4/5). 21 or 32 slots
/// gated by a validity bitmap; every slot is read at fixed width even when its
/// bit is 0.
public struct DailySummary: Codable, Equatable, Sendable {
    public let timestamp: UInt32
    public let timezone: UInt8

    public var steps: UInt32?
    public var activeCalories: UInt16?
    public var heartRateResting: UInt8?
    public var heartRateMax: UInt8?
    public var heartRateMaxTimestamp: UInt32?
    public var heartRateMin: UInt8?
    public var heartRateMinTimestamp: UInt32?
    public var heartRateAvg: UInt8?
    public var stressAvg: UInt8?
    public var stressMax: UInt8?
    public var stressMin: UInt8?
    public var standing: UInt32?
    public var calories: UInt16?
    public var recoveryHours: UInt16?
    public var spo2Max: UInt8?
    public var spo2MaxTimestamp: UInt32?
    public var spo2Min: UInt8?
    public var spo2MinTimestamp: UInt32?
    public var spo2Avg: UInt8?
    public var trainingLoadDay: UInt16?
    public var trainingLoadWeek: UInt16?
    public var trainingLoadLevel: UInt8?
    public var vitalityLight: UInt8?
    public var vitalityModerate: UInt8?
    public var vitalityHigh: UInt8?
    public var vitalityCurrent: UInt16?

    public init(timestamp: UInt32, timezone: UInt8) {
        self.timestamp = timestamp
        self.timezone = timezone
    }
}

/// One minute-by-minute sample — `ACTIVITY_DAILY` detail `0`.
public struct DailyDetailSample: Codable, Equatable, Sendable {
    public let timestamp: UInt32
    public var steps: UInt32?
    public var activeCalories: UInt8?
    public var distanceCm: UInt32?
    public var heartRate: UInt8?
    public var energy: UInt8?
    public var spo2: UInt8?
    public var stress: UInt8?

    public init(timestamp: UInt32) { self.timestamp = timestamp }
}

public struct DailyDetails: Codable, Equatable, Sendable {
    public let samples: [DailyDetailSample]
    public init(samples: [DailyDetailSample]) { self.samples = samples }
}

/// A manual measurement — `ACTIVITY_MANUAL_SAMPLES` (subtype `0x06`, version 2).
public struct ManualSample: Codable, Equatable, Sendable {
    public let timestamp: UInt32
    /// One of `"hr"`, `"spo2"`, `"stress"`, `"temperature"`, or a hex `"0xNN"`.
    public let type: String
    public let value: UInt32

    public init(timestamp: UInt32, type: String, value: UInt32) {
        self.timestamp = timestamp
        self.type = type
        self.value = value
    }
}

/// The result of parsing one complete activity file. Exactly one of the typed
/// payloads is non-nil for a known file; `isRaw` is set for sports/unknown files
/// (kept unparsed), and `error` is set when the file could not be parsed.
public struct ParsedActivityFile: Codable, Equatable, Sendable {
    public let fileId: ActivityFileId
    public var sleepSession: SleepSession?
    public var sleepStages: SleepStages?
    public var dailySummary: DailySummary?
    public var dailyDetails: DailyDetails?
    public var manualSamples: [ManualSample]?
    public var isRaw: Bool
    public var error: String?

    public init(fileId: ActivityFileId, isRaw: Bool = false, error: String? = nil) {
        self.fileId = fileId
        self.isRaw = isRaw
        self.error = error
    }
}
