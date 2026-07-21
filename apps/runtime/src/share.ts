// 服务端 E2EE 身份与配对码生成。
// 静态 X25519 私钥持久化在 state 目录(0600),公钥随配对码分发。

import fs from "node:fs";
import os from "node:os";
import {
  b64ToBytes,
  bytesToB64,
  decodePairingOffer,
  encodePairingOffer,
  generateKeyPair,
  ServerHandshake,
} from "@acro/protocol";
import { z } from "zod";
import { paths, PRIVATE_FILE_MODE } from "./paths.ts";
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

// 真实网卡的 IPv4 地址,写进配对码供客户端直连。跨平台:取非 internal 的 IPv4,
// 排除虚拟/隧道接口——它们的宿主地址对外不可达,只会污染入口列表。
// macOS 常见虚拟名:bridge/vmnet/utun/llw/awdl;Linux 常见:docker/veth/br-/virbr/tun/tap
// 以及各类 VPN(zt/tailscale/wg)。真实有线/无线口(en*/eth*/ens*/enp*/wlan* 等)保留。
const VIRTUAL_IFACE = /^(bridge|vmnet|utun|llw|awdl|docker|veth|br-|virbr|tun|tap|zt|tailscale|wg)/i;

export function lanEndpoints(
  port: number,
  interfaces: NodeJS.Dict<os.NetworkInterfaceInfo[]> = os.networkInterfaces(),
): string[] {
  const endpoints: string[] = [];
  for (const [name, infos] of Object.entries(interfaces)) {
    if (VIRTUAL_IFACE.test(name)) continue;
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
  local = false,
): { offer: string; deviceId: string } {
  const { device, token } = registry.createGrant(name, local);
  try {
    const endpoints = [...new Set([...lanEndpoints(port), ...extraEndpoints])];
    const offer = encodePairingOffer({
      v: 1,
      endpoints: endpoints.length > 0 ? endpoints : [`127.0.0.1:${port}`],
      token,
      pub: bytesToB64(identity.pub),
    });
    return { offer, deviceId: device.id };
  } catch (error) {
    return rollbackGrant(registry, device.id, error);
  }
}

function rollbackGrant(registry: DeviceRegistry, deviceId: string, error: unknown): never {
  try {
    registry.remove(deviceId);
  } catch (rollbackError) {
    throw new AggregateError(
      [error, rollbackError],
      "failed to publish pairing offer and roll back its device grant",
    );
  }
  throw error;
}

function writeOfferFile(
  registry: DeviceRegistry,
  result: { offer: string; deviceId: string },
  file: string,
): void {
  try {
    fs.writeFileSync(file, `${result.offer}\n`, { mode: PRIVATE_FILE_MODE });
    fs.chmodSync(file, PRIVATE_FILE_MODE);
  } catch (error) {
    rollbackGrant(registry, result.deviceId, error);
  }
}

function readOfferFile(
  registry: DeviceRegistry,
  identity: ServerIdentity,
  port: number,
  file: string,
): { offer: string; deviceId: string } | null {
  try {
    const offer = fs.readFileSync(file, "utf8").trim();
    const decoded = decodePairingOffer(offer);
    const device = registry.findByToken(decoded.token);
    if (
      device &&
      decoded.pub === bytesToB64(identity.pub) &&
      decoded.endpoints.includes(`127.0.0.1:${port}`)
    ) {
      fs.chmodSync(file, PRIVATE_FILE_MODE);
      return { offer, deviceId: device.id };
    }
  } catch {
    // 调用方会生成替代授权。
  }
  return null;
}

// Desktop 与 Runtime 同属一个登录用户，本机授权直接走 ~/.acro 的 0700/0600
// 文件边界。回环 HTTP 只能证明“同一台 Mac”，不能区分本机其他账号。
export function ensureLocalOffer(
  registry: DeviceRegistry,
  identity: ServerIdentity,
  port: number,
  file = paths.localOffer,
): { offer: string; deviceId: string } {
  const existing = readOfferFile(registry, identity, port, file);
  if (existing) {
    registry.markLocal(existing.deviceId);
    registry.removeLocalGrants(existing.deviceId);
    return existing;
  }

  registry.removeLocalGrants();
  const result = createShareOffer(
    registry,
    identity,
    port,
    "本机",
    [`127.0.0.1:${port}`],
    true,
  );
  writeOfferFile(registry, result, file);
  return result;
}

// 尚无设备成功认证时的引导:mint 一个授权,配对码写入 0600 文件并打印。
// 该设备首次认证成功后删除文件(见 index.ts)。
export function writeBootstrapOffer(
  registry: DeviceRegistry,
  identity: ServerIdentity,
  port: number,
  file = paths.bootstrapOffer,
): { offer: string; deviceId: string } {
  const result = createShareOffer(registry, identity, port, "bootstrap", [
    `127.0.0.1:${port}`,
  ]);
  writeOfferFile(registry, result, file);
  return result;
}

export function ensureBootstrapOffer(
  registry: DeviceRegistry,
  identity: ServerIdentity,
  port: number,
  file = paths.bootstrapOffer,
): { offer: string; deviceId: string } {
  return (
    readOfferFile(registry, identity, port, file) ??
    writeBootstrapOffer(registry, identity, port, file)
  );
}

export function clearBootstrapOffer(): void {
  fs.rmSync(paths.bootstrapOffer, { force: true });
}
