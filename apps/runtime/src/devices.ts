import crypto from "node:crypto";
import type { Device } from "@acro/protocol";
import { paths } from "./paths.ts";
import { readJson, writeJsonAtomic } from "./store.ts";

interface StoredDevice extends Device {
  tokenHash: string;
}

function sha256(s: string): string {
  return crypto.createHash("sha256").update(s).digest("hex");
}

// 访问授权模型(取自 orca 的 runtime access grant):
// 每个授权 = 一个设备条目 + 一个 token。token 由配对码带外分发,服务端只存哈希。
// lastSeenAt === null 表示"配对码已生成但尚未有客户端连上"。
export class DeviceRegistry {
  private devices: StoredDevice[];

  constructor() {
    this.devices = readJson<StoredDevice[]>(paths.devices, []);
  }

  createGrant(name?: string): { device: Device; token: string } {
    const token = crypto.randomBytes(32).toString("hex");
    const device: StoredDevice = {
      id: crypto.randomUUID(),
      name: name ?? `Runtime ${new Date().toISOString().slice(0, 10)}`,
      createdAt: new Date().toISOString(),
      lastSeenAt: null,
      tokenHash: sha256(token),
    };
    this.devices.push(device);
    this.persist();
    return { device: this.publicView(device), token };
  }

  remove(deviceId: string): Device | null {
    const idx = this.devices.findIndex((d) => d.id === deviceId);
    if (idx < 0) return null;
    const [removed] = this.devices.splice(idx, 1);
    this.persist();
    return this.publicView(removed!);
  }

  auth(token: string): Device | null {
    const hash = Buffer.from(sha256(token), "hex");
    for (const d of this.devices) {
      if (crypto.timingSafeEqual(hash, Buffer.from(d.tokenHash, "hex"))) {
        d.lastSeenAt = new Date().toISOString();
        this.persist();
        return this.publicView(d);
      }
    }
    return null;
  }

  list(): Device[] {
    return this.devices.map((d) => this.publicView(d));
  }

  hasDevices(): boolean {
    return this.devices.length > 0;
  }

  private publicView(d: StoredDevice): Device {
    const { tokenHash: _, ...pub } = d;
    return pub;
  }

  private persist(): void {
    writeJsonAtomic(paths.devices, this.devices);
  }
}
