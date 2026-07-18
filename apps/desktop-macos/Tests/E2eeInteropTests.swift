// E2EE 跨语言互通测试:固定密钥向量由 packages/protocol(@noble)生成,
// CryptoKit 侧的推导与密文必须逐字节一致,否则 Swift 客户端连不上 TS Runtime。

import CryptoKit
import XCTest
@testable import AcroDesktop

final class E2eeInteropTests: XCTestCase {
    // 向量:clientPriv = 32×0x01,serverPriv = 32×0x02(见 e2ee.ts 同参数推导)
    private let clientPrivBytes = Data(repeating: 1, count: 32)
    private let expectedClientPub = Data(hex: "a4e09292b651c278b9772c569f5fa9bb13d906b46ab68c9df9dc2b4409f8a209")
    private let expectedServerPub = Data(hex: "ce8d3ad1ccb633ec7b70c17814a5c76ecd029685050d344745ba05870e587d59")
    private let expectedC2S = Data(hex: "d056c2490c13d57707ef5e6a175b6a2a62a69b50329bc0d8eaec5f3818493c52")
    private let expectedS2C = Data(hex: "f9e8f9cbe5c3794f984977b360cf06290a7236c2ea5f0de732475040cbc2ef8e")
    private let sealedC2S = Data(hex: "76adc1f8262465c351ecce859031263c93de1ae5e4094f06b7f228c2")
    private let sealedS2C = Data(hex: "63536ae8111e2044d096d079dd8ec140a7ccb338")

    private func deriveKeys() throws -> (c2s: Data, s2c: Data) {
        let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: clientPrivBytes)
        XCTAssertEqual(priv.publicKey.rawRepresentation, expectedClientPub)
        let serverKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: expectedServerPub)
        let shared = try priv.sharedSecretFromKeyAgreement(with: serverKey)
        let okm = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: priv.publicKey.rawRepresentation + expectedServerPub,
            sharedInfo: Data("acro-e2ee-v1".utf8),
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
        let json = #"{"v":1,"endpoints":["192.168.1.10:8790"],"token":"\#(String(repeating: "t", count: 64))","pub":"\#(expectedServerPub.base64EncodedString())"}"#
        let b64 = Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let offer = try PairingOffer.decode("acro://pair?c=\(b64)")
        XCTAssertEqual(offer.endpoints, ["192.168.1.10:8790"])
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
