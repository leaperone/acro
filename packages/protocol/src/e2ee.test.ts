import assert from "node:assert/strict";
import { test } from "node:test";
import {
  ClientHandshake,
  ServerHandshake,
  generateKeyPair,
  bytesToB64,
} from "./e2ee.ts";
import { decodePairingOffer, encodePairingOffer, offerServerPub } from "./pairing.ts";

function handshakePair() {
  const serverKeys = generateKeyPair();
  const server = new ServerHandshake(serverKeys.priv);
  const client = new ClientHandshake(serverKeys.pub);
  const { ready, session: serverSession } = server.onHello(client.helloMessage());
  const clientSession = client.onReady(ready);
  return { clientSession, serverSession, serverKeys };
}

test("双向加密往返:文本与二进制", () => {
  const { clientSession, serverSession } = handshakePair();

  const authBox = clientSession.sealText(JSON.stringify({ t: "auth", token: "x".repeat(64) }));
  const opened = serverSession.open(authBox);
  assert.equal(opened.kind, "text");
  assert.equal(JSON.parse((opened as { text: string }).text).t, "auth");

  const frame = new Uint8Array([1, 2, 3, 255, 0, 128]);
  const back = clientSession.open(serverSession.sealBinary(frame));
  assert.equal(back.kind, "binary");
  assert.deepEqual((back as { data: Uint8Array }).data, frame);

  // 连续多条:隐式计数器 nonce 必须两端同步
  for (let i = 0; i < 50; i += 1) {
    const msg = serverSession.open(clientSession.sealText(`m${i}`));
    assert.equal((msg as { text: string }).text, `m${i}`);
  }
});

test("密文篡改必须抛错", () => {
  const { clientSession, serverSession } = handshakePair();
  const box = clientSession.sealText("hello");
  box[box.length - 1]! ^= 0x01;
  assert.throws(() => serverSession.open(box));
});

test("重放同一 hello 派生不出旧会话密钥(防整条会话重放)", () => {
  const serverKeys = generateKeyPair();
  const server = new ServerHandshake(serverKeys.priv);
  const client = new ClientHandshake(serverKeys.pub);
  const hello = client.helloMessage();
  const first = server.onHello(hello);
  const firstSession = client.onReady(first.ready);
  const sealed = firstSession.sealText(JSON.stringify({ t: "auth", token: "x".repeat(64) }));
  // 攻击者重放同一 hello:服务端临时密钥不同,旧密文必须解不开
  const replayed = server.onHello(hello);
  assert.throws(() => replayed.session.open(sealed));
});

test("服务端公钥不匹配必须拒绝(防中间人)", () => {
  const real = generateKeyPair();
  const mitm = new ServerHandshake(generateKeyPair().priv);
  const client = new ClientHandshake(real.pub);
  const { ready } = mitm.onHello(client.helloMessage());
  assert.throws(() => client.onReady(ready), /mismatch/);
});

test("配对码编解码往返", () => {
  const pub = bytesToB64(generateKeyPair().pub);
  const offer = {
    v: 1 as const,
    endpoints: ["192.168.1.10:8790", "例子.test:7100"],
    token: "t".repeat(64),
    pub,
  };
  const encoded = encodePairingOffer(offer);
  assert.ok(encoded.startsWith("acro://pair?c="));
  assert.deepEqual(decodePairingOffer(encoded), offer);
  // 裸负载(去掉 URL 前缀)也能解
  assert.deepEqual(decodePairingOffer(encoded.slice("acro://pair?c=".length)), offer);
  assert.equal(offerServerPub(offer).length, 32);
});
