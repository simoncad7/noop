import Foundation
import CryptoSwift

/// Xiaomi/Zepp SPPv2 crypto (port of `xiaomi_band/crypto.py`).
///
/// Only the working path is implemented:
///   - HKDF-style key derivation (`miwear-auth` info string)
///   - AES-CCM for the auth step-3 `AuthDeviceInfo`
///   - AES-CTR "V2" (key reused as IV) for the encrypted session
///
/// The legacy `encrypt_payload`/`decrypt_payload` (session-key CCM) from the
/// Python module are intentionally omitted — the encrypted session uses
/// `encryptV2`/`decryptV2` exclusively.
public struct XiaomiCrypto {
    public enum CryptoError: Error {
        case invalidTokenFormat
    }

    public let authKey: [UInt8]

    public private(set) var decryptionKey: [UInt8] = []
    public private(set) var encryptionKey: [UInt8] = []
    public private(set) var decryptionNonce: [UInt8] = []
    public private(set) var encryptionNonce: [UInt8] = []

    // Persistent AES-CTR keystreams (one per direction). The CTR counter and
    // keystream position must carry across packets — see `CTRStream`.
    private var encryptionStream: CTRStream?
    private var decryptionStream: CTRStream?

    public var hasSessionKeys: Bool { !encryptionKey.isEmpty && !decryptionKey.isEmpty }

    /// - Parameter authKeyHex: 32-char hex auth key (optionally `0x`-prefixed).
    public init(authKeyHex: String) throws {
        var clean = authKeyHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("0x") { clean.removeFirst(2) }
        guard clean.count == 32 else {
            throw CryptoError.invalidTokenFormat
        }

        var key: [UInt8] = []
        key.reserveCapacity(16)
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let end = clean.index(idx, offsetBy: 2)
            guard let byte = UInt8(clean[idx..<end], radix: 16) else {
                throw CryptoError.invalidTokenFormat
            }
            key.append(byte)
            idx = end
        }
        self.authKey = key
    }

    /// 16-byte random client nonce for the auth challenge.
    public func generateClientNonce() -> [UInt8] {
        return AES.randomIV(16)
    }

    /// Verify the watch HMAC AFTER deriving keys (matches
    /// `XiaomiBLEAuth.processWatchNonce`): derive keys from
    /// `(clientNonce, deviceNonce)`, then compare
    /// `HMAC-SHA256(key=decryptionKey, msg=deviceNonce+clientNonce)`.
    public mutating func verifyDeviceHmac(clientNonce: [UInt8], deviceNonce: [UInt8], deviceHmac: [UInt8]) -> Bool {
        deriveSessionKeys(clientNonce: clientNonce, deviceNonce: deviceNonce)
        let dataToVerify = deviceNonce + clientNonce
        let expected = (try? HMAC(key: decryptionKey, variant: .sha2(.sha256)).authenticate(dataToVerify)) ?? []
        print("[AUTH] authKey=\(authKey.hex())")
        print("[AUTH] decryptionKey=\(decryptionKey.hex()) encryptionKey=\(encryptionKey.hex())")
        print("[AUTH] expectedHmac=\(expected.hex())")
        print("[AUTH] deviceHmac   =\(deviceHmac.hex())")
        return expected == deviceHmac
    }

    /// Derive session keys via HKDF (extract + expand with `miwear-auth`).
    public mutating func deriveSessionKeys(clientNonce: [UInt8], deviceNonce: [UInt8]) {
        // 1. Extract: PRK = HMAC-SHA256(key=clientNonce+deviceNonce, msg=authKey)
        let prk = (try? HMAC(key: clientNonce + deviceNonce, variant: .sha2(.sha256)).authenticate(authKey)) ?? []

        // 2. Expand
        let info = Array("miwear-auth".utf8)
        var output: [UInt8] = []
        var tmp: [UInt8] = []
        var counter: UInt8 = 1
        while output.count < 64 {
            let hmacInput = tmp + info + [counter]
            tmp = (try? HMAC(key: prk, variant: .sha2(.sha256)).authenticate(hmacInput)) ?? []
            let needed = min(tmp.count, 64 - output.count)
            output.append(contentsOf: tmp.prefix(needed))
            counter += 1
        }

        decryptionKey = Array(output[0..<16])
        encryptionKey = Array(output[16..<32])
        decryptionNonce = Array(output[32..<36])
        encryptionNonce = Array(output[36..<40])

        // New session keys → fresh keystreams. Each handshake derives new keys,
        // so the CTR counter must start back at the key (IV) for the new session.
        encryptionStream = nil
        decryptionStream = nil
    }

    /// Auth step 3: encrypted nonces + AES-CCM-encrypted `AuthDeviceInfo`.
    ///
    /// - Returns: `(encryptedNonces, encryptedDeviceInfo)`.
    public func generateAuthStep3Data(
        clientNonce: [UInt8],
        deviceNonce: [UInt8],
        phoneName: String = "iPhone",
        phoneApiLevel: Float = Float(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    ) throws -> (encryptedNonces: [UInt8], encryptedDeviceInfo: [UInt8]) {
        // 1. Nonces signed with HMAC-SHA256(key=encryptionKey)
        let noncesConcat = clientNonce + deviceNonce
        let encryptedNonces = (try? HMAC(key: encryptionKey, variant: .sha2(.sha256)).authenticate(noncesConcat)) ?? []

        // 2. AuthDeviceInfo — must identify as an iOS companion, not Android.
        // The Band 10 (BLE V2) uses this to decide the post-auth data path. my-band
        // (hardware-validated iOS BLE V2) sends: device_type=iOS(1), phoneApiLevel =
        // iOS major version, app_capability=all(0xFFFFFFFF). Sending the Android
        // values (0 / 33 / 224) makes the band confirm auth (subtype 27) but then
        // drop the BLE link (CBError code=7) on the first post-auth command.
        var deviceInfo = Xiaomi_AuthDeviceInfo()
        deviceInfo.unknown1 = 1   // AstroBox DeviceType::Ios = 1
        deviceInfo.phoneApiLevel = phoneApiLevel
        deviceInfo.phoneName = phoneName
        deviceInfo.unknown3 = 0xFFFF_FFFF   // app_capability: all features enabled
        deviceInfo.region = "FR"
        let deviceInfoBytes = try deviceInfo.serializedData()

        // 3. AES-CCM (tag 4 bytes). Nonce 12 bytes: encryptionNonce(4) + zeros(4) + counter(4 LE = 0)
        let aesIv = encryptionNonce + [0, 0, 0, 0] + [0, 0, 0, 0]
        let ccm = CCM(iv: aesIv, tagLength: 4, messageLength: deviceInfoBytes.count, additionalAuthenticatedData: [])
        let aes = try AES(key: encryptionKey, blockMode: ccm, padding: .noPadding)
        let encryptedDeviceInfo = try aes.encrypt([UInt8](deviceInfoBytes))

        return (encryptedNonces, encryptedDeviceInfo)
    }

    public mutating func encryptV2(_ data: [UInt8]) throws -> [UInt8] {
        var stream = try CTRStream(key: encryptionKey)
        return stream.xor(data)
    }

    public mutating func decryptV2(_ data: [UInt8]) throws -> [UInt8] {
        var stream = try CTRStream(key: decryptionKey)
        return stream.xor(data)
    }
}

/// A stateful AES-CTR keystream. CryptoSwift's `CTR(iv:)` builds a fresh counter
/// (reset to the IV) on every call, so invoking it per-packet reuses the same
/// keystream block. This keeps the running 128-bit big-endian counter and the
/// keystream position across packets, matching Python `cryptography`'s persistent
/// `modes.CTR(iv=key)` context (one cipher context per direction, per the SPPv2
/// "V2" spec).
private struct CTRStream {
    private let cipher: AES
    private var counterBlock: [UInt8]
    private var keystream: [UInt8] = []
    private var pos = 0

    init(key: [UInt8]) throws {
        // SPPv2 "V2" reuses the key bytes directly as the IV / counter start.
        cipher = try AES(key: key, blockMode: ECB(), padding: .noPadding)
        counterBlock = key
    }

    mutating func xor(_ data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count)
        for i in 0..<data.count {
            if pos == keystream.count {
                // A full 16-byte ECB block cannot fail.
                keystream = (try? cipher.encrypt(counterBlock)) ?? []
                incrementCounter()
                pos = 0
            }
            out[i] = data[i] ^ keystream[pos]
            pos += 1
        }
        return out
    }

    /// 16-byte big-endian increment (Python `modes.CTR` semantics).
    private mutating func incrementCounter() {
        var i = counterBlock.count - 1
        while i >= 0 {
            if counterBlock[i] == 0xFF {
                counterBlock[i] = 0
                i -= 1
            } else {
                counterBlock[i] &+= 1
                break
            }
        }
    }
}
