import crypto from "node:crypto";
import type { Device } from "@acro/protocol";
import { paths } from "./paths.ts";
import { readJson, writeJsonAtomic } from "./store.ts";

interface StoredDevice extends Device {
  tokenHash: string;
}

const PAIR_CODE_TTL_MS = 10 * 60 * 1000;

function sha256(s: string): string {
  return crypto.createHash("sha256").update(s).digest("hex");
}

export class DeviceRegistry {
  private devices: StoredDevice[];
  private pairCodes = new Map<string, number>(); // code -> expiresAt

  constructor() {
    this.devices = readJson<StoredDevice[]>(paths.devices, []);
    // 测试注入固定配对码
    if (process.env.ACRO_PAIR_CODE) this.addPairCode(process.env.ACRO_PAIR_CODE);
  }

  newPairCode(): string {
    const code = crypto.randomBytes(4).toString("hex").toUpperCase();
    this.addPairCode(code);
    return code;
  }

  private addPairCode(code: string): void {
    this.pairCodes.set(code, Date.now() + PAIR_CODE_TTL_MS);
  }

  pair(code: string, deviceName: string): { device: Device; token: string } | null {
    const expiresAt = this.pairCodes.get(code);
    if (!expiresAt || Date.now() > expiresAt) return null;
    this.pairCodes.delete(code); // 一次性
    const token = crypto.randomBytes(32).toString("hex");
    const device: StoredDevice = {
      id: crypto.randomUUID(),
      name: deviceName,
      createdAt: new Date().toISOString(),
      lastSeenAt: null,
      tokenHash: sha256(token),
    };
    this.devices.push(device);
    this.persist();
    return { device: this.publicView(device), token };
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
