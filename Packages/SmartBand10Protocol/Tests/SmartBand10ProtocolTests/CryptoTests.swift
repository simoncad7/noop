import XCTest
@testable import SmartBand10Protocol

final class CryptoTests: XCTestCase {
    let authKeyHex = "000102030405060708090a0b0c0d0e0f"
    let clientNonceHex = "00112233445566778899aabbccddeeff"
    let deviceNonceHex = "ffeeddccbbaa99887766554433221100"

    func testInitParsesHexKey() throws {
        XCTAssertEqual(try XiaomiCrypto(authKeyHex: authKeyHex).authKey, hexBytes(authKeyHex))
        XCTAssertEqual(try XiaomiCrypto(authKeyHex: "0x" + authKeyHex).authKey, hexBytes(authKeyHex))
        XCTAssertThrowsError(try XiaomiCrypto(authKeyHex: "00ff"))
        XCTAssertThrowsError(try XiaomiCrypto(authKeyHex: ""))
    }

    func testDeriveSessionKeysMatchesPython() throws {
        var crypto = try XiaomiCrypto(authKeyHex: authKeyHex)
        crypto.deriveSessionKeys(
            clientNonce: hexBytes(clientNonceHex),
            deviceNonce: hexBytes(deviceNonceHex)
        )
        XCTAssertEqual(crypto.decryptionKey.hexString(), "40892431c57653d6756152a367c2144f")
        XCTAssertEqual(crypto.encryptionKey.hexString(), "7ca5c034b253c81caac5d66234371870")
        XCTAssertEqual(crypto.decryptionNonce.hexString(), "e29dfde0")
        XCTAssertEqual(crypto.encryptionNonce.hexString(), "38d4b6f2")
        XCTAssertTrue(crypto.hasSessionKeys)
    }

    func testVerifyDeviceHmacMatchesPython() throws {
        var crypto = try XiaomiCrypto(authKeyHex: authKeyHex)
        let ok = crypto.verifyDeviceHmac(
            clientNonce: hexBytes(clientNonceHex),
            deviceNonce: hexBytes(deviceNonceHex),
            deviceHmac: hexBytes("2fd5de8be55c663a3cd56464c401cdeff512b6f072c48a7fa8fc524c4b9b2a23")
        )
        XCTAssertTrue(ok)
    }

    func testVerifyDeviceHmacRejectsWrongHmac() throws {
        var crypto = try XiaomiCrypto(authKeyHex: authKeyHex)
        let ok = crypto.verifyDeviceHmac(
            clientNonce: hexBytes(clientNonceHex),
            deviceNonce: hexBytes(deviceNonceHex),
            deviceHmac: [UInt8](repeating: 0, count: 32)
        )
        XCTAssertFalse(ok)
    }

    func testGenerateAuthStep3DataMatchesPython() throws {
        var crypto = try XiaomiCrypto(authKeyHex: authKeyHex)
        crypto.deriveSessionKeys(
            clientNonce: hexBytes(clientNonceHex),
            deviceNonce: hexBytes(deviceNonceHex)
        )
        let (encryptedNonces, encryptedDeviceInfo) = try crypto.generateAuthStep3Data(
            clientNonce: hexBytes(clientNonceHex),
            deviceNonce: hexBytes(deviceNonceHex),
            phoneName: "iPhone",
            phoneApiLevel: 26.0
        )
        XCTAssertEqual(encryptedNonces.hexString(), "39d2a1e2e53a187cecf1f3243ec27eb660dae8450c89f653e2fa18ebfe02b700")
        XCTAssertEqual(encryptedDeviceInfo.hexString(), "d8ff8e9d57f0f3038c0e08ee5184570de9ed1aac0350dc00209d92fd3d")
    }

    func testEncryptDecryptV2MatchesPython() throws {
        var crypto = try XiaomiCrypto(authKeyHex: authKeyHex)
        crypto.deriveSessionKeys(
            clientNonce: hexBytes(clientNonceHex),
            deviceNonce: hexBytes(deviceNonceHex)
        )
        let plaintext = hexBytes("00112233445566778899aabbccddeeff")
        let ciphertext = try crypto.encryptV2(plaintext)
        XCTAssertEqual(ciphertext.hexString(), "be6f82256cf90ddac97cfe395ae189ff")

        // decryptV2 uses the decryption key (different keystream than encryptV2).
        let decrypted = try crypto.decryptV2(ciphertext)
        XCTAssertEqual(decrypted.hexString(), "54d3a6175b7d20b82d0819d1aa2b8bf0")
    }
}
