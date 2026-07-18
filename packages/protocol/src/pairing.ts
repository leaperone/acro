// 配对码:acro://pair?c=<base64url(JSON)>。
// 模型取自 orca(MIT, Copyright (c) stablyai)的 pairing offer:
// token 与服务端公钥由用户带外(复制粘贴/扫码)传输,不走明文网络。

import { z } from "zod";
import { b64ToBytes, bytesToB64 } from "./e2ee.ts";

export const PAIRING_VERSION = 1;

export const PairingOffer = z.object({
  v: z.literal(PAIRING_VERSION),
  // host:port 列表;第一个通常是 LAN 地址,可含 FRP 等公网入口
  endpoints: z.array(z.string().min(1)).min(1),
  token: z.string().min(32),
  // 服务端静态 X25519 公钥,base64
  pub: z.string().min(1),
});
export type PairingOffer = z.infer<typeof PairingOffer>;

const PREFIX = "acro://pair?c=";

function toB64Url(s: string): string {
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fromB64Url(s: string): string {
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/");
  return atob(b64 + "=".repeat((4 - (b64.length % 4)) % 4));
}

export function encodePairingOffer(offer: PairingOffer): string {
  return PREFIX + toB64Url(JSON.stringify(PairingOffer.parse(offer)));
}

// 接受完整 acro:// URL 或裸 base64url 负载
export function decodePairingOffer(input: string): PairingOffer {
  const raw = input.trim();
  const payload = raw.startsWith(PREFIX) ? raw.slice(PREFIX.length) : raw;
  return PairingOffer.parse(JSON.parse(fromB64Url(payload)));
}

export function offerServerPub(offer: PairingOffer): Uint8Array {
  const pub = b64ToBytes(offer.pub);
  if (pub.length !== 32) throw new Error("bad server public key in pairing offer");
  return pub;
}

export { bytesToB64 as pubToB64 };
