// E2EE 跨语言互通测试:固定密钥向量由 packages/protocol(@noble)生成,
// CryptoKit 侧的推导与密文必须逐字节一致,否则 Swift 客户端连不上 TS Runtime。

import CryptoKit
import XCTest
@testable import AcroDesktop

final class E2eeInteropTests: XCTestCase {
    // 向量:clientPriv = 32×0x01,serverPriv = 32×0x02,serverEphPriv = 32×0x03
    // (由 packages/protocol 的 @noble 以相同参数推导)
    private let clientPrivBytes = Data(repeating: 1, count: 32)
    private let expectedClientPub = Data(hex: "a4e09292b651c278b9772c569f5fa9bb13d906b46ab68c9df9dc2b4409f8a209")
    private let expectedServerPub = Data(hex: "ce8d3ad1ccb633ec7b70c17814a5c76ecd029685050d344745ba05870e587d59")
    private let expectedEphPub = Data(hex: "5dfedd3b6bd47f6fa28ee15d969d5bb0ea53774d488bdaf9df1c6e0124b3ef22")
    private let expectedC2S = Data(hex: "86fbc5b213bf0fb2390950e8649a0b294de46fade50afb07d3c5239c1d85fce0")
    private let expectedS2C = Data(hex: "cf1bac08265bff49a391d1ec0a4d81c0119c5e0bf4f35e04b307edde5339c465")
    private let sealedC2S = Data(hex: "4610a39cc3c1cf846757174d4874ac84e22cf28066fd1719cf0436c1")
    private let sealedS2C = Data(hex: "80e55c7834dec038c823e7c488ef5e9d7cc5a1a9")

    private func deriveKeys() throws -> (c2s: Data, s2c: Data) {
        let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: clientPrivBytes)
        XCTAssertEqual(priv.publicKey.rawRepresentation, expectedClientPub)
        let staticKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: expectedServerPub)
        let ephKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: expectedEphPub)
        let sharedStatic = try priv.sharedSecretFromKeyAgreement(with: staticKey)
        let sharedEph = try priv.sharedSecretFromKeyAgreement(with: ephKey)
        let ikm = sharedStatic.withUnsafeBytes { Data($0) } + sharedEph.withUnsafeBytes { Data($0) }
        let okm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: priv.publicKey.rawRepresentation + expectedEphPub,
            info: Data("acro-e2ee-v1".utf8),
            outputByteCount: 64
        )
        let okmData = okm.withUnsafeBytes { Data($0) }
        return (Data(okmData.prefix(32)), Data(okmData.suffix(32)))
    }

    func testKeyDerivationMatchesNoble() throws {
        let keys = try deriveKeys()
        XCTAssertEqual(keys.c2s, expectedC2S)
        XCTAssertEqual(keys.s2c, expectedS2C)
    }

    func testSealMatchesNobleCiphertext() throws {
        let keys = try deriveKeys()
        let session = E2eeSession(txKey: keys.c2s, rxKey: keys.s2c)
        XCTAssertEqual(try session.sealText("hello world"), sealedC2S)
    }

    func testOpenNobleCiphertext() throws {
        let keys = try deriveKeys()
        let session = E2eeSession(txKey: keys.c2s, rxKey: keys.s2c)
        guard case .binary(let data) = try session.open(sealedS2C) else {
            return XCTFail("expected binary payload")
        }
        XCTAssertEqual(data, Data([1, 2, 3]))
    }

    func testTamperedCiphertextThrows() throws {
        let keys = try deriveKeys()
        let session = E2eeSession(txKey: keys.c2s, rxKey: keys.s2c)
        var tampered = sealedS2C
        tampered[tampered.count - 1] ^= 0x01
        XCTAssertThrowsError(try session.open(tampered))
    }

    func testPairingOfferDecode() throws {
        // packages/protocol encodePairingOffer 生成的样例
        let json = #"{"v":1,"endpoints":["例子.test:8790"],"token":"\#(String(repeating: "t", count: 64))","pub":"\#(expectedServerPub.base64EncodedString())"}"#
        let b64 = Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let offer = try PairingOffer.decode("acro://pair?c=\(b64)")
        XCTAssertEqual(offer.endpoints, ["例子.test:8790"])
        XCTAssertEqual(Data(base64Encoded: offer.pub), expectedServerPub)
    }
}

private extension Data {
    init(hex: String) {
        self.init()
        var iterator = hex.makeIterator()
        while let a = iterator.next(), let b = iterator.next() {
            self.append(UInt8(String([a, b]), radix: 16)!)
        }
    }
}
