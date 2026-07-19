// 应用层 E2EE 信道,与 packages/protocol/src/e2ee.ts 同构:
// X25519 + HKDF-SHA256 + ChaCha20-Poly1305,隐式计数器 nonce(4 零字节 + LE64)。
// 方案取自 orca(MIT, Copyright (c) stablyai);wire 格式见 e2ee.ts 头部注释。

import CryptoKit
import Foundation

enum E2eeError: Error, LocalizedError {
    case handshake(String)
    var errorDescription: String? {
        if case .handshake(let msg) = self { return msg }
        return nil
    }
}

// 配对码:acro://pair?c=<base64url(JSON)>
struct PairingOffer: Codable {
    let v: Int
    let endpoints: [String]
    let token: String
    let pub: String

    static func decode(_ raw: String) throws -> PairingOffer {
        let prefix = "acro://pair?c="
        var payload = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.hasPrefix(prefix) { payload = String(payload.dropFirst(prefix.count)) }
        var b64 = payload.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64) else {
            throw E2eeError.handshake("配对码不是合法的 base64")
        }
        let offer = try JSONDecoder().decode(PairingOffer.self, from: data)
        guard offer.v == 1 else { throw E2eeError.handshake("不支持的配对码版本 \(offer.v)") }
        return offer
    }
}

func pairingAdmissionId(_ token: String) -> String {
    SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
}

func pairingWebSocketURL(endpoint: String, token: String) -> URL? {
    URL(string: "ws://\(endpoint)/ws?grant=\(pairingAdmissionId(token))")
}

private final class DirectionCipher {
    private let key: SymmetricKey
    private var counter: UInt64 = 0

    init(keyBytes: Data) {
        key = SymmetricKey(data: keyBytes)
    }

    private func nextNonce() throws -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        var c = counter.littleEndian
        withUnsafeBytes(of: &c) { bytes.append(contentsOf: $0) }
        counter += 1
        return try ChaChaPoly.Nonce(data: bytes)
    }

    // wire = ciphertext || tag(16),nonce 不随帧发送
    func seal(_ plain: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plain, using: key, nonce: nextNonce())
        return box.ciphertext + box.tag
    }

    func open(_ wire: Data) throws -> Data {
        guard wire.count >= 16 else { throw E2eeError.handshake("密文过短") }
        let box = try ChaChaPoly.SealedBox(
            nonce: nextNonce(),
            ciphertext: wire.dropLast(16),
            tag: wire.suffix(16)
        )
        return try ChaChaPoly.open(box, using: key)
    }
}

enum E2eePayload {
    case text(String)
    case binary(Data)
}

final class E2eeSession {
    private let tx: DirectionCipher
    private let rx: DirectionCipher

    init(txKey: Data, rxKey: Data) {
        tx = DirectionCipher(keyBytes: txKey)
        rx = DirectionCipher(keyBytes: rxKey)
    }

    func sealText(_ text: String) throws -> Data {
        try tx.seal(Data([0x00]) + Data(text.utf8))
    }

    func sealBinary(_ data: Data) throws -> Data {
        try tx.seal(Data([0x01]) + data)
    }

    func open(_ wire: Data) throws -> E2eePayload {
        let plain = try rx.open(wire)
        guard let kind = plain.first else { throw E2eeError.handshake("空明文") }
        let payload = plain.dropFirst()
        if kind == 0x00 {
            return .text(String(decoding: payload, as: UTF8.self))
        }
        return .binary(Data(payload))
    }
}

final class E2eeClientHandshake {
    private let priv = Curve25519.KeyAgreement.PrivateKey()
    private let expectedServerPub: Data

    init(expectedServerPubB64: String) throws {
        guard let pub = Data(base64Encoded: expectedServerPubB64), pub.count == 32 else {
            throw E2eeError.handshake("配对码里的服务端公钥无效")
        }
        expectedServerPub = pub
    }

    func helloJSON() -> String {
        let pub = priv.publicKey.rawRepresentation.base64EncodedString()
        return #"{"t":"hello","v":1,"pub":"\#(pub)"}"#
    }

    // 密钥:IKM = DH(clientEph, serverStatic) || DH(clientEph, serverEph),
    // salt = clientPub || serverEphPub(与 e2ee.ts 一致;服务端临时公钥防整条会话重放)
    func onReady(pubB64: String, ephB64: String) throws -> E2eeSession {
        guard let serverPub = Data(base64Encoded: pubB64), serverPub == expectedServerPub else {
            throw E2eeError.handshake("服务端公钥与配对码不一致(疑似中间人)")
        }
        guard let serverEph = Data(base64Encoded: ephB64), serverEph.count == 32 else {
            throw E2eeError.handshake("服务端临时公钥无效")
        }
        let staticKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverPub)
        let ephKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverEph)
        let sharedStatic = try priv.sharedSecretFromKeyAgreement(with: staticKey)
        let sharedEph = try priv.sharedSecretFromKeyAgreement(with: ephKey)
        let ikm = sharedStatic.withUnsafeBytes { Data($0) } + sharedEph.withUnsafeBytes { Data($0) }
        let clientPub = priv.publicKey.rawRepresentation
        // HKDF 一次导出 64 字节:[0,32)=client→server,[32,64)=server→client
        let okm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: clientPub + serverEph,
            info: Data("acro-e2ee-v1".utf8),
            outputByteCount: 64
        )
        let okmData = okm.withUnsafeBytes { Data($0) }
        return E2eeSession(txKey: okmData.prefix(32), rxKey: okmData.suffix(32))
    }
}
