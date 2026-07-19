// Apple Simulator 管理:xcrun simctl。
// ponytail: 画面用 simctl screenshot 低帧率轮询(~1fps),先满足"唤醒并查看";
// 高帧率与触控输入等 Swift helper(ScreenCaptureKit + AX)接管。

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { EventEmitter } from "node:events";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const execFileP = promisify(execFile);

const POLL_MS = 1000;

export interface SimDevice {
  udid: string;
  name: string;
  state: string;
  runtime: string;
}

async function simctl(...args: string[]): Promise<string> {
  try {
    const { stdout } = await execFileP("xcrun", ["simctl", ...args], {
      maxBuffer: 64 * 1024 * 1024,
    });
    return stdout;
  } catch (err) {
    const e = err as { stderr?: string; message: string };
    throw new Error(e.stderr?.trim() || e.message);
  }
}

export class SimulatorManager extends EventEmitter {
  private nextHandle = 1;
  // udid -> 轮询状态
  private attached = new Map<string, { handle: number; seq: number; timer: NodeJS.Timeout }>();

  async list(): Promise<SimDevice[]> {
    const out = JSON.parse(await simctl("list", "devices", "available", "--json")) as {
      devices: Record<string, Array<{ udid: string; name: string; state: string }>>;
    };
    const devices: SimDevice[] = [];
    for (const [runtime, list] of Object.entries(out.devices)) {
      for (const d of list) {
        devices.push({
          udid: d.udid,
          name: d.name,
          state: d.state,
          runtime: runtime.replace("com.apple.CoreSimulator.SimRuntime.", ""),
        });
      }
    }
    return devices;
  }

  async boot(udid: string): Promise<string> {
    try {
      await simctl("boot", udid);
    } catch (err) {
      if (!(err as Error).message.includes("current state: Booted")) throw err;
    }
    await simctl("bootstatus", udid); // 等待启动完成
    return "Booted";
  }

  async shutdown(udid: string): Promise<string> {
    this.stopPolling(udid);
    try {
      await simctl("shutdown", udid);
    } catch (err) {
      if (!(err as Error).message.includes("current state: Shutdown")) throw err;
    }
    return "Shutdown";
  }

  async attach(udid: string): Promise<{ channel: number }> {
    let existing = this.attached.get(udid);
    if (existing) return { channel: existing.handle };
    const devices = await this.list();
    if (!devices.some((device) => device.udid === udid)) {
      throw new Error("simulator not found");
    }
    // list() 等待期间另一个连接可能已经完成 attach。
    existing = this.attached.get(udid);
    if (existing) return { channel: existing.handle };
    const handle = this.nextHandle++;
    const state = { handle, seq: 0, timer: setInterval(() => void this.capture(udid), POLL_MS) };
    this.attached.set(udid, state);
    void this.capture(udid);
    return { channel: handle };
  }

  detach(udid: string): void {
    this.stopPolling(udid);
  }

  private stopPolling(udid: string): void {
    const state = this.attached.get(udid);
    if (!state) return;
    clearInterval(state.timer);
    this.attached.delete(udid);
    this.emit("detached", udid, state.handle);
  }

  private capturing = new Set<string>();

  private async capture(udid: string): Promise<void> {
    const state = this.attached.get(udid);
    if (!state || this.capturing.has(udid)) return;
    this.capturing.add(udid);
    // simctl 不支持 stdout 输出,落临时文件再读
    const tmp = path.join(os.tmpdir(), `acro-sim-${state.handle}.png`);
    try {
      await execFileP("xcrun", ["simctl", "io", udid, "screenshot", "--type=png", tmp]);
      const data = fs.readFileSync(tmp);
      fs.unlinkSync(tmp);
      state.seq += 1;
      this.emit("frame", state.handle, state.seq, data);
    } catch {
      // 未启动或截图失败,下一轮再试
    } finally {
      this.capturing.delete(udid);
    }
  }

  shutdownManager(): void {
    for (const udid of [...this.attached.keys()]) this.stopPolling(udid);
  }
}
