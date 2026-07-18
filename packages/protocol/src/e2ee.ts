// 应用层端到端加密信道。方案取自 orca(MIT, Copyright (c) stablyai)的
// runtime E2EE:不依赖 TLS,配对码带出服务端公钥,token 只在加密信道内传输。
// 原语选 X25519 + HKDF-SHA256 + ChaCha20-Poly1305:三端同构
// (Node/RN 用 @noble,Swift 用 CryptoKit 原生),orca 用的 XSalsa20 CryptoKit 没有。
//
// 握手(WS 文本帧,明文):
//   client → {t:"hello", v:1, pub}   pub = 客户端临时 X25519 公钥
//   server → {t:"ready", pub, eph}   pub = 服务端静态公钥(客户端必须与配对码比对,防中间人);
//                                    eph = 服务端每连接临时公钥(防整条会话重放:
//                                    没有它,重放 hello 会派生出与被录会话相同的密钥,
//                                    旧密文全部可重放执行)
// 密钥:IKM = DH(clientEph, serverStatic) || DH(clientEph, serverEph),
//       salt = clientPub || serverEphPub,HKDF-SHA256 导出 64 字节。
// 之后所有消息走二进制帧:ChaCha20-Poly1305(key_dir, nonce=LE64(counter)) 密文。
// 每方向独立 key 与隐式计数器 nonce(传输层 TCP 保序,不随帧发送)。
// 明文首字节区分负载:0x00=JSON 文本,0x01=二进制帧(frames.ts 编码)。
//
// 认证在信道内完成:客户端首条加密消息 {t:"auth", token},服务端校验后回
// {t:"authed", deviceId}。token 从不明文过网。

import { x25519 } from "@noble/curves/ed25519.js";
import { chacha20poly1305 } from "@noble/ciphers/chacha.js";
import { hkdf } from "@noble/hashes/hkdf.js";
import { sha256 } from "@noble/hashes/sha2.js";

export const E2EE_VERSION = 1;
const HKDF_INFO = new TextEncoder().encode("acro-e2ee-v1");

export const PAYLOAD_TEXT = 0x00;
export const PAYLOAD_BINARY = 0x01;

// ---- base64(RN Hermes / Node / 浏览器通用,避免 Buffer) ----

export function bytesToB64(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i += 1) bin += String.fromCharCode(bytes[i]!);
  return btoa(bin);
}

export function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i += 1) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

// ---- 方向信道:隐式计数器 nonce ----

class DirectionCipher {
  private key: Uint8Array;
  private counter = 0n;

  constructor(key: Uint8Array) {
    this.key = key;
  }

  private nextNonce(): Uint8Array {
    const nonce = new Uint8Array(12);
    let c = this.counter;
    this.counter += 1n;
    for (let i = 4; i < 12; i += 1) {
      nonce[i] = Number(c & 0xffn);
      c >>= 8n;
    }
    return nonce;
  }

  seal(plain: Uint8Array): Uint8Array {
    return chacha20poly1305(this.key, this.nextNonce()).encrypt(plain);
  }

  open(box: Uint8Array): Uint8Array {
    return chacha20poly1305(this.key, this.nextNonce()).decrypt(box);
  }
}

// ---- 会话 ----

export type OpenedMessage =
  | { kind: "text"; text: string }
  | { kind: "binary"; data: Uint8Array };

export class E2eeSession {
  private tx: DirectionCipher;
  private rx: DirectionCipher;

  constructor(txKey: Uint8Array, rxKey: Uint8Array) {
    this.tx = new DirectionCipher(txKey);
    this.rx = new DirectionCipher(rxKey);
  }

  sealText(text: string): Uint8Array {
    const utf8 = new TextEncoder().encode(text);
    const plain = new Uint8Array(1 + utf8.length);
    plain[0] = PAYLOAD_TEXT;
    plain.set(utf8, 1);
    return this.tx.seal(plain);
  }

  sealBinary(data: Uint8Array): Uint8Array {
    const plain = new Uint8Array(1 + data.length);
    plain[0] = PAYLOAD_BINARY;
    plain.set(data, 1);
    return this.tx.seal(plain);
  }

  // 篡改或乱序时抛错;调用方应直接断开连接
  open(box: Uint8Array): OpenedMessage {
    const plain = this.rx.open(box);
    const payload = plain.subarray(1);
    if (plain[0] === PAYLOAD_TEXT) {
      return { kind: "text", text: new TextDecoder().decode(payload) };
    }
    return { kind: "binary", data: payload };
  }
}

// HKDF 一次导出 64 字节:[0,32)=client→server,[32,64)=server→client
function deriveKeys(
  sharedStatic: Uint8Array,
  sharedEph: Uint8Array,
  clientPub: Uint8Array,
  serverEphPub: Uint8Array,
): { c2s: Uint8Array; s2c: Uint8Array } {
  const ikm = new Uint8Array(64);
  ikm.set(sharedStatic, 0);
  ikm.set(sharedEph, 32);
  const salt = new Uint8Array(64);
  salt.set(clientPub, 0);
  salt.set(serverEphPub, 32);
  const okm = hkdf(sha256, ikm, salt, HKDF_INFO, 64);
  return { c2s: okm.slice(0, 32), s2c: okm.slice(32, 64) };
}

// ---- 握手消息 ----

export interface HelloMessage {
  t: "hello";
  v: number;
  pub: string;
}

export interface ReadyMessage {
  t: "ready";
  pub: string;
  eph: string;
}

export function generateKeyPair(): { priv: Uint8Array; pub: Uint8Array } {
  const priv = x25519.utils.randomSecretKey();
  return { priv, pub: x25519.getPublicKey(priv) };
}

// 客户端:临时密钥对,校验服务端公钥与配对码一致(防中间人)
export class ClientHandshake {
  private priv: Uint8Array;
  readonly pub: Uint8Array;
  private expectedServerPub: Uint8Array;

  constructor(expectedServerPub: Uint8Array) {
    const pair = generateKeyPair();
    this.priv = pair.priv;
    this.pub = pair.pub;
    this.expectedServerPub = expectedServerPub;
  }

  helloMessage(): HelloMessage {
    return { t: "hello", v: E2EE_VERSION, pub: bytesToB64(this.pub) };
  }

  onReady(msg: ReadyMessage): E2eeSession {
    const serverPub = b64ToBytes(msg.pub);
    if (
      serverPub.length !== 32 ||
      bytesToB64(serverPub) !== bytesToB64(this.expectedServerPub)
    ) {
      throw new Error("server public key mismatch");
    }
    const serverEph = b64ToBytes(msg.eph);
    if (serverEph.length !== 32) throw new Error("bad server ephemeral key");
    const sharedStatic = x25519.getSharedSecret(this.priv, serverPub);
    const sharedEph = x25519.getSharedSecret(this.priv, serverEph);
    const { c2s, s2c } = deriveKeys(sharedStatic, sharedEph, this.pub, serverEph);
    return new E2eeSession(c2s, s2c);
  }
}

// 服务端:静态密钥对(持久化,公钥进配对码)
export class ServerHandshake {
  private priv: Uint8Array;
  readonly pub: Uint8Array;

  constructor(staticPriv: Uint8Array) {
    this.priv = staticPriv;
    this.pub = x25519.getPublicKey(staticPriv);
  }

  onHello(msg: HelloMessage): { ready: ReadyMessage; session: E2eeSession } {
    if (msg.v !== E2EE_VERSION) throw new Error(`unsupported e2ee version: ${msg.v}`);
    const clientPub = b64ToBytes(msg.pub);
    if (clientPub.length !== 32) throw new Error("bad client public key");
    // 每连接临时密钥:保证重放的 hello 派生不出旧会话密钥
    const eph = generateKeyPair();
    const sharedStatic = x25519.getSharedSecret(this.priv, clientPub);
    const sharedEph = x25519.getSharedSecret(eph.priv, clientPub);
    const { c2s, s2c } = deriveKeys(sharedStatic, sharedEph, clientPub, eph.pub);
    // 服务端视角:tx=s2c,rx=c2s
    return {
      ready: { t: "ready", pub: bytesToB64(this.pub), eph: bytesToB64(eph.pub) },
      session: new E2eeSession(s2c, c2s),
    };
  }
}
