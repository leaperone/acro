import crypto from "node:crypto";
import { Device as DeviceSchema, pairingAdmissionId, type Device } from "@acro/protocol";
import { z } from "zod";
import { paths } from "./paths.ts";
import { readJson, writeJsonAtomic } from "./store.ts";

interface StoredDevice extends Device {
  tokenHash: string;
  local: boolean;
}

const StoredDevices = z.array(
  DeviceSchema.extend({
    tokenHash: z.string().regex(/^[0-9a-f]{64}$/),
    local: z.boolean().default(false),
  }),
);

// 访问授权模型(取自 orca 的 runtime access grant):
// 每个授权 = 一个设备条目 + 一个 token。token 由配对码带外分发,服务端只存哈希。
// lastSeenAt === null 表示"配对码已生成但尚未有客户端连上"。
export class DeviceRegistry {
  private devices: StoredDevice[];
  private file: string;
  private legacyDeviceIds = new Set<string>();

  constructor(file = paths.devices) {
    this.file = file;
    try {
      const raw = readJson<unknown>(file, []);
      this.devices = StoredDevices.parse(raw);
      if (Array.isArray(raw)) {
        this.legacyDeviceIds = new Set(
          raw.flatMap((entry) =>
            entry &&
            typeof entry === "object" &&
            !Object.hasOwn(entry, "local") &&
            typeof (entry as { id?: unknown }).id === "string"
              ? [(entry as { id: string }).id]
              : [],
          ),
        );
      }
    } catch (error) {
      throw new Error(`invalid device state ${file}: ${(error as Error).message}`, { cause: error });
    }
  }

  createGrant(name?: string, local = false): { device: Device; token: string } {
    const token = crypto.randomBytes(32).toString("hex");
    const device: StoredDevice = {
      id: crypto.randomUUID(),
      name: name ?? `Runtime ${new Date().toISOString().slice(0, 10)}`,
      createdAt: new Date().toISOString(),
      lastSeenAt: null,
      tokenHash: pairingAdmissionId(token),
      local,
    };
    const next = [...this.devices, device];
    this.persist(next);
    this.devices = next;
    return { device: this.publicView(device), token };
  }

  remove(deviceId: string): Device | null {
    const idx = this.devices.findIndex((d) => d.id === deviceId);
    if (idx < 0) return null;
    const next = [...this.devices];
    const [removed] = next.splice(idx, 1);
    this.persist(next);
    this.devices = next;
    return this.publicView(removed!);
  }

  auth(token: string): Device | null {
    const index = this.findTokenIndex(token);
    if (index < 0) return null;
    const updated = { ...this.devices[index]!, lastSeenAt: new Date().toISOString() };
    const next = [...this.devices];
    next[index] = updated;
    try {
      this.persist(next);
      this.devices = next;
    } catch (error) {
      console.warn(`[runtime] failed to persist device lastSeenAt: ${(error as Error).message}`);
    }
    return this.publicView(updated);
  }

  findByToken(token: string): Device | null {
    const index = this.findTokenIndex(token);
    return index < 0 ? null : this.publicView(this.devices[index]!);
  }

  hasAdmissionId(admissionId: string): boolean {
    return (
      /^[0-9a-f]{64}$/.test(admissionId) &&
      this.devices.some((device) => device.tokenHash === admissionId)
    );
  }

  markLocal(deviceId: string): void {
    const index = this.devices.findIndex((device) => device.id === deviceId);
    if (index < 0) throw new Error("device not found");
    if (this.devices[index]!.local) return;
    const next = [...this.devices];
    next[index] = { ...next[index]!, local: true };
    this.persist(next);
    this.devices = next;
  }

  removeLocalGrants(keepDeviceId?: string): Device[] {
    const removed = this.devices.filter(
      (device) => device.local && device.id !== keepDeviceId,
    );
    if (removed.length === 0) return [];
    const next = this.devices.filter(
      (device) => !device.local || device.id === keepDeviceId,
    );
    this.persist(next);
    this.devices = next;
    return removed.map((device) => this.publicView(device));
  }

  // 旧 /local-offer 固定把设备命名为“本机”，且旧记录没有 local 字段。
  // 只迁移缺字段的旧记录；新 schema 中用户创建的同名远程设备不受影响。
  migrateLegacyLocalGrants(): Device[] {
    if (this.legacyDeviceIds.size === 0) return [];
    const migrated: StoredDevice[] = [];
    const next = this.devices.map((device) => {
      if (!this.legacyDeviceIds.has(device.id) || device.name !== "本机") return device;
      const local = { ...device, local: true };
      migrated.push(local);
      return local;
    });
    this.persist(next);
    this.devices = next;
    this.legacyDeviceIds.clear();
    return migrated.map((device) => this.publicView(device));
  }

  list(): Device[] {
    return this.devices.map((d) => this.publicView(d));
  }

  private publicView(d: StoredDevice): Device {
    const { tokenHash: _, local: _local, ...pub } = d;
    return pub;
  }

  private findTokenIndex(token: string): number {
    const hash = Buffer.from(pairingAdmissionId(token), "hex");
    return this.devices.findIndex((device) =>
      crypto.timingSafeEqual(hash, Buffer.from(device.tokenHash, "hex")),
    );
  }

  private persist(devices: StoredDevice[]): void {
    writeJsonAtomic(this.file, devices);
  }
}
