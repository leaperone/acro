import crypto from "node:crypto";
import {
  ALL_RPC_SCOPES,
  DEFAULT_GRANT_SCOPES,
  Device as DeviceSchema,
  pairingAdmissionId,
  type Device,
  type RpcScope,
} from "@acro/protocol";
import { z } from "zod";
import { paths } from "./paths.ts";
import { readJson, writeJsonAtomic } from "./store.ts";

interface StoredDevice extends Device {
  tokenHash: string;
  local: boolean;
  scopes: RpcScope[];
}

const StoredDevices = z.array(
  DeviceSchema.extend({
    tokenHash: z.string().regex(/^[0-9a-f]{64}$/),
    local: z.boolean().default(false),
    // scope 早于本字段的授权在读取时补全为全 scope(见 normalizeScopes):
    // 已配对的 iPhone / MacBook 不能因为一次升级就失去权限。
    scopes: z.array(z.enum(ALL_RPC_SCOPES as [RpcScope, ...RpcScope[]])).nullable().default(null),
  }),
);

// 旧记录(scopes 缺失或为 null)= 升级前配对的设备,当时的实际权限就是全部方法。
// 静默降权会让用户已在用的设备突然报 forbidden,比暂时宽松更糟。
function normalizeScopes(scopes: readonly RpcScope[] | null | undefined): RpcScope[] {
  if (!scopes) return [...ALL_RPC_SCOPES];
  const unique = [...new Set(scopes)];
  return ALL_RPC_SCOPES.filter((scope) => unique.includes(scope));
}

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
      this.devices = StoredDevices.parse(raw).map((device) => ({
        ...device,
        scopes: normalizeScopes(device.scopes),
      }));
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

  // local grant 是本机桌面端自己用的授权,必须拿全 scope,否则本机 UI 会被自己锁住。
  // 远程配对省略 scopes 时按 DEFAULT_GRANT_SCOPES(不含 computer / admin)。
  createGrant(
    name?: string,
    local = false,
    scopes?: readonly RpcScope[],
  ): { device: Device; token: string } {
    const token = crypto.randomBytes(32).toString("hex");
    const granted = local
      ? [...ALL_RPC_SCOPES]
      : normalizeScopes(scopes ?? DEFAULT_GRANT_SCOPES);
    if (granted.length === 0) throw new Error("grant requires at least one scope");
    const device: StoredDevice = {
      id: crypto.randomUUID(),
      name: name ?? `Runtime ${new Date().toISOString().slice(0, 10)}`,
      createdAt: new Date().toISOString(),
      lastSeenAt: null,
      tokenHash: pairingAdmissionId(token),
      local,
      scopes: granted,
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
