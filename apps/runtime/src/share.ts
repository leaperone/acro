// 服务端 E2EE 身份与配对码生成。
// 静态 X25519 私钥持久化在 state 目录(0600),公钥随配对码分发。

import fs from "node:fs";
import os from "node:os";
import {
  b64ToBytes,
  bytesToB64,
  encodePairingOffer,
  generateKeyPair,
  ServerHandshake,
} from "@acro/protocol";
import { z } from "zod";
import { paths } from "./paths.ts";
import type { DeviceRegistry } from "./devices.ts";
import { readJson, writeJsonAtomic } from "./store.ts";

const StoredServerIdentity = z.object({ priv: z.string() });

export class ServerIdentity {
  readonly priv: Uint8Array;
  readonly pub: Uint8Array;

  constructor(file = paths.serverKey) {
    const stored = readJson<unknown | undefined>(file, undefined);
    let priv: Uint8Array;
    if (stored === undefined) {
      priv = generateKeyPair().priv;
      writeJsonAtomic(file, { priv: bytesToB64(priv) });
    } else {
      try {
        const parsed = StoredServerIdentity.parse(stored);
        priv = b64ToBytes(parsed.priv);
        if (priv.length !== 32) throw new Error("private key must be 32 bytes");
      } catch (error) {
        throw new Error(`invalid server identity ${file}: ${(error as Error).message}`, {
          cause: error,
        });
      }
    }
    this.priv = priv;
    this.pub = new ServerHandshake(priv).pub;
  }
}

// 真实网卡(macOS 的 en0/en1 = Wi-Fi/以太网)的 IPv4 地址,写进配对码供客户端直连。
// vmnet/utun 等虚拟接口的宿主地址对外不可达,只会污染入口列表,一律排除。
export function lanEndpoints(port: number): string[] {
  const endpoints: string[] = [];
  for (const [name, infos] of Object.entries(os.networkInterfaces())) {
    if (!/^en\d+$/.test(name)) continue;
    for (const info of infos ?? []) {
      if (info.family === "IPv4" && !info.internal) endpoints.push(`${info.address}:${port}`);
    }
  }
  return endpoints;
}

export function createShareOffer(
  registry: DeviceRegistry,
  identity: ServerIdentity,
  port: number,
  name?: string,
  extraEndpoints: string[] = [],
): { offer: string; deviceId: string } {
  const { device, token } = registry.createGrant(name);
  const endpoints = [...new Set([...lanEndpoints(port), ...extraEndpoints])];
  const offer = encodePairingOffer({
    v: 1,
    endpoints: endpoints.length > 0 ? endpoints : [`127.0.0.1:${port}`],
    token,
    pub: bytesToB64(identity.pub),
  });
  return { offer, deviceId: device.id };
}

// 首次启动无任何设备时的引导:mint 一个授权,配对码写入 0600 文件并打印。
// 该设备首次认证成功后删除文件(见 index.ts)。
export function writeBootstrapOffer(
  registry: DeviceRegistry,
  identity: ServerIdentity,
  port: number,
): { offer: string; deviceId: string } {
  const result = createShareOffer(registry, identity, port, "bootstrap", [
    `127.0.0.1:${port}`,
  ]);
  fs.writeFileSync(paths.bootstrapOffer, `${result.offer}\n`, { mode: 0o600 });
  return result;
}

export function clearBootstrapOffer(): void {
  fs.rmSync(paths.bootstrapOffer, { force: true });
}
