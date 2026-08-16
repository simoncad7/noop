import Foundation
import CryptoSwift

/// Auto-advancing byte reader with little-/big-endian primitive access
/// (port of `xiaomi_band/activity.py` `_Reader`). Reference semantics, like the
/// Python class, so parsers share a cursor without `inout` plumbing.
public final class ByteReader {
    public let data: [UInt8]
    public private(set) var pos: Int
    public let limit: Int

    public init(_ data: [UInt8], pos: Int = 0, limit: Int? = nil) {
        self.data = data
        self.pos = pos
        self.limit = limit ?? data.count
    }

    public var remaining: Int { limit - pos }

    @discardableResult
    public func getUInt8() -> UInt8 {
        let v = data[pos]
        pos += 1
        return v
    }

    public func getUInt16LE() -> UInt16 {
        let v = UInt16(data[pos]) | (UInt16(data[pos + 1]) << 8)
        pos += 2
        return v
    }

    public func getUInt16BE() -> UInt16 {
        let v = (UInt16(data[pos]) << 8) | UInt16(data[pos + 1])
        pos += 2
        return v
    }

    public func getUInt32LE() -> UInt32 {
        let v = UInt32(data[pos])
            | (UInt32(data[pos + 1]) << 8)
            | (UInt32(data[pos + 2]) << 16)
            | (UInt32(data[pos + 3]) << 24)
        pos += 4
        return v
    }

    public func getUInt64LE() -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(data[pos + i]) << (8 * i) }
        pos += 8
        return v
    }

    /// 3-byte little-endian unsigned integer (`read_u24` in the Python port).
    public func getUInt24LE() -> UInt32 {
        let v = UInt32(data[pos]) | (UInt32(data[pos + 1]) << 8) | (UInt32(data[pos + 2]) << 16)
        pos += 3
        return v
    }

    public func getFloat32LE() -> Float {
        let bits = getUInt32LE()
        return Float(bitPattern: bits)
    }

    @discardableResult
    public func read(_ n: Int) -> [UInt8] {
        let v = Array(data[pos..<(pos + n)])
        pos += n
        return v
    }

    public func skip(_ n: Int) { pos += n }
}

/// The 7-byte file id that prefixes every activity file pulled on channel 5.
///
/// Layout (little-endian): `timestamp u32 | timezone u8 | version u8 | flags u8`.
/// The `flags` byte: bit 7 = `type` (0 activity, 1 sports), bits 6..2 = `subtype`,
/// bits 1..0 = `detailType`.
public struct ActivityFileId: Equatable, Hashable, Sendable, Codable {
    public let timestamp: UInt32
    public let timezone: UInt8
    public let version: UInt8
    public let type: UInt8
    public let subtype: UInt8
    public let detailType: UInt8

    public init(timestamp: UInt32, timezone: UInt8, version: UInt8, type: UInt8, subtype: UInt8, detailType: UInt8) {
        self.timestamp = timestamp
        self.timezone = timezone
        self.version = version
        self.type = type
        self.subtype = subtype
        self.detailType = detailType
    }

    /// A sentinel for unparseable / too-short files (never sent on the wire).
    public static let empty = ActivityFileId(timestamp: 0, timezone: 0, version: 0, type: 0, subtype: 0, detailType: 0)

    /// Parse from the leading 7 bytes of a file.
    public init?(bytes: [UInt8]) {
        guard bytes.count >= 7 else { return nil }
        let r = ByteReader(bytes)
        let ts = r.getUInt32LE()
        let tz = r.getUInt8()
        let version = r.getUInt8()
        let flags = r.getUInt8()
        self.init(
            timestamp: ts,
            timezone: tz,
            version: version,
            type: (flags >> 7) & 1,
            subtype: (flags & 0x7F) >> 2,
            detailType: flags & 0x03
        )
    }

    public var flags: UInt8 { (type << 7) | (subtype << 2) | detailType }

    public var bytes: [UInt8] {
        var out: [UInt8] = []
        out.append(UInt8(timestamp & 0xFF))
        out.append(UInt8((timestamp >> 8) & 0xFF))
        out.append(UInt8((timestamp >> 16) & 0xFF))
        out.append(UInt8((timestamp >> 24) & 0xFF))
        out.append(timezone)
        out.append(version)
        out.append(flags)
        return out
    }

    public var typeName: String { type == 1 ? "SPORTS" : "ACTIVITY" }
    public var subtypeName: String { ActivityConstants.subtypeName(type: type, subtype: subtype) }
    public var detailName: String { ActivityConstants.detailName(detailType) }

    /// `timestamp == 0 && version == 0` marks an empty/padding file id that the
    /// watch uses to terminate a file list — the Python client skips these.
    public var isNull: Bool { timestamp == 0 && version == 0 }
}

public enum ActivityConstants {
    public static let typeActivity: UInt8 = 0
    public static let typeSports: UInt8 = 1

    public static func subtypeName(type: UInt8, subtype: UInt8) -> String {
        switch (type, subtype) {
        case (0, 0x00): return "ACTIVITY_DAILY"
        case (0, 0x03): return "ACTIVITY_SLEEP_STAGES"
        case (0, 0x06): return "ACTIVITY_MANUAL_SAMPLES"
        case (0, 0x08): return "ACTIVITY_SLEEP"
        case (1, 0x01): return "SPORTS_OUTDOOR_RUNNING"
        case (1, 0x02): return "SPORTS_OUTDOOR_WALKING_V1"
        case (1, 0x03): return "SPORTS_TREADMILL"
        case (1, 0x06): return "SPORTS_OUTDOOR_CYCLING_V2"
        case (1, 0x07): return "SPORTS_INDOOR_CYCLING"
        case (1, 0x08): return "SPORTS_FREESTYLE"
        case (1, 0x09): return "SPORTS_POOL_SWIMMING"
        case (1, 0x10): return "SPORTS_HIIT"
        case (1, 0x0B): return "SPORTS_ELLIPTICAL"
        case (1, 0x0D): return "SPORTS_ROWING"
        case (1, 0x0E): return "SPORTS_JUMP_ROPING"
        case (1, 0x16): return "SPORTS_OUTDOOR_WALKING_V2"
        case (1, 0x17): return "SPORTS_OUTDOOR_CYCLING"
        default: return String(format: "UNKNOWN_0x%02X", subtype)
        }
    }

    public static func detailName(_ detail: UInt8) -> String {
        switch detail {
        case 0: return "DETAILS"
        case 1: return "SUMMARY"
        case 2: return "GPS_TRACK"
        default: return String(format: "UNKNOWN_0x%02X", detail)
        }
    }
}

/// Reassembles a single activity file from channel-5 chunks of the form
/// `[total u16 LE][num u16 LE][data…]`. A new file starts at `num == 1`; the file
/// is complete when `num == total`. Port of `ble_client.py` `_handle_activity_chunk`.
public final class ActivityFileAssembler {
    private var buffer: [UInt8] = []
    private var total = 0

    public init() {}

    public func reset() {
        buffer = []
        total = 0
    }

    /// Feed one chunk. Returns the fully reassembled file bytes when `num == total`,
    /// otherwise `nil`.
    public func push(_ chunk: [UInt8]) -> [UInt8]? {
        guard chunk.count >= 4 else { return nil }
        let total = Int(UInt16(chunk[0]) | (UInt16(chunk[1]) << 8))
        let num = Int(UInt16(chunk[2]) | (UInt16(chunk[3]) << 8))
        if num == 1 {
            buffer = []
            self.total = total
        }
        buffer.append(contentsOf: chunk[4...])
        guard num == total else { return nil }
        let data = buffer
        buffer = []
        return data
    }
}

public enum ActivityCRC {
    /// CRC-32/ISO-HDLC — identical to `zlib.crc32` and Java `java.util.zip.CRC32`
    /// (check value `0xCBF43926` for `"123456789"`).
    public static func crc32(_ data: [UInt8]) -> UInt32 {
        Checksum.crc32(data)
    }

    /// Verify the trailing 4-byte CRC, repairing the one known failure mode (a
    /// lost padding byte after the 7-byte file id — Gadgetbridge `fixAndWrap`).
    /// Returns the verified (possibly repaired) file bytes, or `nil` when the
    /// data is genuinely corrupt — e.g. tail chunks from another file's transfer
    /// interleaved mid-stream. my-band validates the raw CRC the same way; the
    /// padding repair only *adds* acceptance cases, so this never rejects a file
    /// the raw check would have passed.
    public static func verified(_ data: [UInt8]) -> [UInt8]? {
        guard data.count >= 12 else { return nil }
        let stored = UInt32(data[data.count - 4])
            | (UInt32(data[data.count - 3]) << 8)
            | (UInt32(data[data.count - 2]) << 16)
            | (UInt32(data[data.count - 1]) << 24)
        let body = Array(data[0..<(data.count - 4)])

        // Happy path: the stored CRC covers the file as-is.
        if crc32(body) == stored { return data }

        // Lost-padding recovery: fileId(7) + padding(1) + payload + CRC(4). When
        // the band drops the padding byte the stored CRC covers id+0x00+payload.
        guard data.count >= 12 else { return nil }
        let paddedBody = Array(data[0..<7]) + [0x00] + Array(data[7..<(data.count - 4)])
        guard crc32(paddedBody) == stored else { return nil }
        var out = paddedBody
        out.append(UInt8(stored & 0xFF))
        out.append(UInt8((stored >> 8) & 0xFF))
        out.append(UInt8((stored >> 16) & 0xFF))
        out.append(UInt8((stored >> 24) & 0xFF))
        return out
    }

    /// Verify the trailing 4-byte CRC over `data[0..<count-4]`. On mismatch,
    /// re-insert a lost padding byte (Gadgetbridge `fixAndWrap`), recompute the
    /// CRC, and return the repaired bytes. Idempotent when the CRC already matches.
    public static func fixed(_ data: [UInt8]) -> [UInt8] {
        guard data.count >= 13 else { return data }
        let body = Array(data[0..<(data.count - 4)])
        let expected = UInt32(data[data.count - 4])
            | (UInt32(data[data.count - 3]) << 8)
            | (UInt32(data[data.count - 2]) << 16)
            | (UInt32(data[data.count - 1]) << 24)
        if crc32(body) == expected { return data }

        // Lost-padding recovery: fileId(7) + padding(1) + payload + CRC(4).
        let fixedBody = Array(data[0..<7]) + [0x00] + Array(data[7..<(data.count - 4)])
        let fixedCrc = crc32(fixedBody)
        var out = fixedBody
        out.append(UInt8(fixedCrc & 0xFF))
        out.append(UInt8((fixedCrc >> 8) & 0xFF))
        out.append(UInt8((fixedCrc >> 16) & 0xFF))
        out.append(UInt8((fixedCrc >> 24) & 0xFF))
        return out
    }
}
