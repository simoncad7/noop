import Foundation
@testable import SmartBand10Protocol

/// Decode a lowercase hex string into bytes.
func hexBytes(_ s: String) -> [UInt8] {
    var result: [UInt8] = []
    var idx = s.startIndex
    while idx < s.endIndex {
        let end = s.index(idx, offsetBy: 2)
        result.append(UInt8(s[idx..<end], radix: 16)!)
        idx = end
    }
    return result
}

func hexData(_ s: String) -> Data {
    Data(hexBytes(s))
}

extension Array where Element == UInt8 {
    func hexString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}

extension Data {
    var hexString: String {
        [UInt8](self).hexString()
    }
}

/// De-frame a full SPP packet into `(type, sequence, payload)`.
func deframe(_ packet: Data) -> (type: UInt8, sequence: UInt8, payload: Data)? {
    guard packet.count >= 8, packet[0] == 0xA5, packet[1] == 0xA5 else { return nil }
    let type = packet[2]
    let sequence = packet[3]
    let len = Int(packet[4]) | (Int(packet[5]) << 8)
    guard packet.count >= 8 + len else { return nil }
    let payload = packet.subdata(in: 8..<(8 + len))
    return (type, sequence, payload)
}

/// Extract the protobuf `Xiaomi_Command` carried by a DATA packet.
func commandFromDataPacket(_ packet: Data) throws -> Xiaomi_Command {
    guard let (type, _, payload) = deframe(packet), type == Spp.packetTypeData,
          let (_, _, inner) = Spp.parseDataPacket(payload) else {
        throw NSError(domain: "SmartBand10Tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "not a data packet"])
    }
    return try Xiaomi_Command(serializedBytes: [UInt8](inner))
}
