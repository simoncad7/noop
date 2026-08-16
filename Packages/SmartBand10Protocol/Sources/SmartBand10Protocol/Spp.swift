import Foundation

/// SPPv2 framing (port of `xiaomi_band/spp.py`).
///
/// Packet layout (little-endian header, 8 bytes):
///   `A5 A5 | type | seq | len_lo len_hi | crc_lo crc_hi | payload`
///
/// DataPacket V2 payload: `[channel & 0xf][opcode][payload]`.
/// NOTE: no 2-byte endpoint id. The Band 10's SPP is the Classic-style framing
/// (Gadgetbridge connects via BT_CLASSIC and omits the endpoint id; the Python
/// RFCOMM client omits it too). Empirically, inserting `0x0000` on TX makes the
/// band ACK the phone nonce but never answer with the watch nonce — so the
/// endpoint id must be omitted on this firmware.
public enum Spp {
    public static let packetPreamble: [UInt8] = [0xA5, 0xA5]

    public static let packetTypeAck: UInt8 = 1
    public static let packetTypeSessionConfig: UInt8 = 2
    public static let packetTypeData: UInt8 = 3

    public static let channelProtobuf: UInt8 = 1
    public static let channelData: UInt8 = 2
    public static let channelActivity: UInt8 = 5

    public static let opcodeSendPlaintext: UInt8 = 1
    public static let opcodeSendEncrypted: UInt8 = 2

    public static let opcodeStartSessionRequest: UInt8 = 1
    public static let opcodeStartSessionResponse: UInt8 = 2

    /// CRC-16/ARC over the payload, computed the same way as
    /// Gadgetbridge's Java `calculatePayloadChecksum()` (bit-reversal of the
    /// 32-bit CRC, then take the high 16 bits). Check value `0xBB3D` for
    /// `"123456789"`.
    public static func calculateChecksum(_ payload: [UInt8]) -> UInt16 {
        var crc: UInt32 = 0
        for byte in payload {
            for j in 0..<8 {
                crc = (crc << 1) & 0xFFFF_FFFF
                let bit16 = (crc >> 16) & 1
                let bitB = UInt32(byte >> j) & 1
                if (bit16 ^ bitB) == 1 {
                    crc ^= 0x8005
                }
            }
        }

        var v = crc
        v = ((v >> 1) & 0x5555_5555) | ((v & 0x5555_5555) << 1)
        v = ((v >> 2) & 0x3333_3333) | ((v & 0x3333_3333) << 2)
        v = ((v >> 4) & 0x0F0F_0F0F) | ((v & 0x0F0F_0F0F) << 4)
        v = ((v >> 8) & 0x00FF_00FF) | ((v & 0x00FF_00FF) << 8)
        v = ((v >> 16) & 0x0000_FFFF) | ((v & 0x0000_FFFF) << 16)

        return UInt16(v >> 16)
    }

    /// Build a full SPP packet: preamble + header + payload.
    public static func buildPacket(type: UInt8, sequence: UInt8, payload: Data) -> Data {
        let length = UInt16(payload.count)
        let crc = calculateChecksum([UInt8](payload))

        var out = Data(capacity: 8 + payload.count)
        out.append(contentsOf: packetPreamble)      // A5 A5
        out.append(type & 0x0F)
        out.append(sequence)
        out.append(UInt8(length & 0xFF))            // length LSB
        out.append(UInt8((length >> 8) & 0xFF))     // length MSB
        out.append(UInt8(crc & 0xFF))               // crc LSB
        out.append(UInt8((crc >> 8) & 0xFF))        // crc MSB
        out.append(payload)
        return out
    }

    /// Session config V2 with 4 TLVs (opcode START_SESSION_REQUEST by default).
    public static func buildSessionConfig(opcode: UInt8 = opcodeStartSessionRequest) -> Data {
        let payload: [UInt8] = [
            opcode,
            // VERSION (type 1) = 01.00.00
            1, 0x03, 0x00, 0x01, 0x00, 0x00,
            // MAX_PACKET_SIZE (type 2) = 0xFC00
            2, 0x02, 0x00, 0x00, 0xFC,
            // TX_WIN (type 3) = 0x0020
            3, 0x02, 0x00, 0x20, 0x00,
            // SEND_TIMEOUT (type 4) = 0x2710
            4, 0x02, 0x00, 0x10, 0x27,
        ]
        return buildPacket(type: packetTypeSessionConfig, sequence: 0, payload: Data(payload))
    }

    /// Build a DataPacket V2: `[channel & 0xf][opcode][payload]`.
    public static func buildDataPacket(sequence: UInt8, channel: UInt8, opcode: UInt8, payload: Data) -> Data {
        var data = Data(capacity: 2 + payload.count)
        data.append(channel & 0x0F)
        data.append(opcode & 0xFF)
        data.append(payload)
        return buildPacket(type: packetTypeData, sequence: sequence, payload: data)
    }

    /// Parse a DataPacket V2 payload. Returns `(channel, opcode, payload)`.
    public static func parseDataPacket(_ payload: Data) -> (channel: UInt8, opcode: UInt8, payload: Data)? {
        guard payload.count >= 2 else { return nil }
        let channel = payload[payload.startIndex] & 0x0F
        let opcode = payload[payload.startIndex + 1] & 0xFF
        let inner = payload.count > 2
            ? payload.subdata(in: (payload.startIndex + 2)..<payload.endIndex)
            : Data()
        return (channel, opcode, inner)
    }

    /// Build an ACK packet (empty payload) for a received sequence number.
    public static func buildAckPacket(sequence: UInt8) -> Data {
        return buildPacket(type: packetTypeAck, sequence: sequence, payload: Data())
    }
}

extension Array where Element == UInt8 {
    /// Lowercase hex dump (diagnostic).
    func hex() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
