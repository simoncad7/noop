import Foundation

/// Incremental SPPv2 de-framer: accumulates raw bytes and emits complete
/// SPP packets as they arrive (port of `ble_client.py` `_rfcomm_reader`).
///
/// Handles partial packets and re-synchronizes on the `A5 A5` preamble when the
/// stream contains leading garbage. CRC is not checked here (matching the
/// Python reference); the packet payload is returned verbatim.
public final class Framer {
    public struct Packet: Equatable {
        public let type: UInt8
        public let sequence: UInt8
        public let payload: Data

        public init(type: UInt8, sequence: UInt8, payload: Data) {
            self.type = type
            self.sequence = sequence
            self.payload = payload
        }
    }

    private var buffer = Data()

    public init() {}

    public func reset() {
        buffer.removeAll()
    }

    /// Feed received bytes; returns any complete packets parsed so far.
    @discardableResult
    public func push(_ data: Data) -> [Packet] {
        buffer.append(data)
        var packets: [Packet] = []

        while buffer.count >= 8 {
            let start = buffer.startIndex

            // Re-synchronize: drop leading bytes until the A5 A5 preamble.
            if buffer[start] != 0xA5 || buffer[start + 1] != 0xA5 {
                var found = false
                for i in 1..<(buffer.count - 1) {
                    if buffer[start + i] == 0xA5 && buffer[start + i + 1] == 0xA5 {
                        buffer.removeSubrange(start..<(start + i))
                        found = true
                        break
                    }
                }
                if !found {
                    buffer.removeAll()
                    break
                }
                continue
            }

            let payloadLen = Int(buffer[start + 4]) | (Int(buffer[start + 5]) << 8)
            let packetLen = 8 + payloadLen
            guard buffer.count >= packetLen else { break } // incomplete packet

            let packet = Packet(
                type: buffer[start + 2] & 0x0F,
                sequence: buffer[start + 3],
                payload: buffer.subdata(in: (start + 8)..<(start + packetLen))
            )
            packets.append(packet)
            buffer.removeSubrange(start..<(start + packetLen))
        }

        return packets
    }
}
