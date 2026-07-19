// Apple Simulator 管理:xcrun simctl。
// ponytail: 画面用 simctl screenshot 低帧率轮询(~1fps),先满足"唤醒并查看";
// 高帧率与触控输入等 Swift helper(ScreenCaptureKit + AX)接管。

import { execFile } from "node:child_process";
import crypto from "node:crypto";
import { promisify } from "node:util";
import { EventEmitter } from "node:events";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const execFileP = promisify(execFile);

const POLL_MS = 1000;
const SIMCTL_TIMEOUT_MS = 60_000;
const SCREENSHOT_TIMEOUT_MS = 10_000;
const MAX_SIMCTL_CONCURRENCY = 4;
const MAX_SIMCTL_QUEUE = 4;

interface SimctlRunOptions {
  signal?: AbortSignal | undefined;
  timeoutMs: number;
}

type SimctlRunner = (args: string[], options: SimctlRunOptions) => Promise<string>;

interface Waiter {
  signal?: AbortSignal | undefined;
  resolve: () => void;
  reject: (error: Error) => void;
  onAbort?: (() => void) | undefined;
}

class SimctlExecutor {
  private active = 0;
  private waiters: Waiter[] = [];
  private idleWaiters: Array<() => void> = [];
  private readonly limit: number;
  private readonly maxQueue: number;

  constructor(limit: number, maxQueue: number) {
    this.limit = limit;
    this.maxQueue = maxQueue;
  }

  async run<T>(
    task: (signal: AbortSignal) => Promise<T>,
    signal: AbortSignal | undefined,
    timeoutMs: number,
  ): Promise<T> {
    if (signal?.aborted) throw abortError(signal);
    if (this.active >= this.limit && this.waiters.length >= this.maxQueue) {
      throw new Error("simulator request queue full");
    }
    const timeoutController = new AbortController();
    const timer = setTimeout(
      () => timeoutController.abort(new Error("simulator request timeout")),
      timeoutMs,
    );
    timer.unref();
    const runSignal = signal
      ? AbortSignal.any([signal, timeoutController.signal])
      : timeoutController.signal;
    let acquired = false;
    try {
      await this.acquire(runSignal);
      acquired = true;
      runSignal.throwIfAborted();
      return await task(runSignal);
    } finally {
      clearTimeout(timer);
      if (acquired) this.release();
    }
  }

  private acquire(signal?: AbortSignal): Promise<void> {
    if (signal?.aborted) return Promise.reject(abortError(signal));
    if (this.active < this.limit) {
      this.active += 1;
      return Promise.resolve();
    }
    if (this.waiters.length >= this.maxQueue) {
      return Promise.reject(new Error("simulator request queue full"));
    }
    return new Promise((resolve, reject) => {
      const waiter: Waiter = { signal, resolve, reject };
      waiter.onAbort = () => {
        const index = this.waiters.indexOf(waiter);
        if (index < 0) return;
        this.waiters.splice(index, 1);
        reject(abortError(signal!));
        this.notifyIdle();
      };
      signal?.addEventListener("abort", waiter.onAbort, { once: true });
      this.waiters.push(waiter);
    });
  }

  private release(): void {
    this.active -= 1;
    while (this.waiters.length > 0) {
      const waiter = this.waiters.shift()!;
      if (waiter.onAbort) waiter.signal?.removeEventListener("abort", waiter.onAbort);
      if (waiter.signal?.aborted) {
        waiter.reject(abortError(waiter.signal));
        continue;
      }
      this.active += 1;
      waiter.resolve();
      return;
    }
    this.notifyIdle();
  }

  waitForIdle(): Promise<void> {
    if (this.active === 0 && this.waiters.length === 0) return Promise.resolve();
    return new Promise((resolve) => this.idleWaiters.push(resolve));
  }

  private notifyIdle(): void {
    if (this.active !== 0 || this.waiters.length !== 0) return;
    for (const resolve of this.idleWaiters.splice(0)) resolve();
  }
}

function abortError(signal: AbortSignal): Error {
  return signal.reason instanceof Error ? signal.reason : new Error("simulator request cancelled");
}

export interface SimDevice {
  udid: string;
  name: string;
  state: string;
  runtime: string;
}

async function runSimctlProcess(args: string[], options: SimctlRunOptions): Promise<string> {
  try {
    const { stdout } = await execFileP("xcrun", ["simctl", ...args], {
      maxBuffer: 64 * 1024 * 1024,
      signal: options.signal,
      timeout: options.timeoutMs,
    });
    return stdout;
  } catch (err) {
    const e = err as { stderr?: string; message: string };
    throw new Error(e.stderr?.trim() || e.message);
  }
}

export class SimulatorManager extends EventEmitter {
  private nextHandle = 1;
  private readonly runner: SimctlRunner;
  private readonly executor: SimctlExecutor;
  private readonly instanceId = crypto.randomUUID();
  // udid -> 轮询状态
  private attached = new Map<
    string,
    { handle: number; seq: number; timer: NodeJS.Timeout; abortController: AbortController }
  >();
  private captures = new Map<string, Promise<void>>();
  private lifecycleBusy = new Set<string>();
  private lifecycleVersion = 0;

  constructor(
    runner: SimctlRunner = runSimctlProcess,
    concurrency = MAX_SIMCTL_CONCURRENCY,
    maxQueue = MAX_SIMCTL_QUEUE,
  ) {
    super();
    this.runner = runner;
    this.executor = new SimctlExecutor(concurrency, maxQueue);
  }

  private simctl(
    args: string[],
    signal?: AbortSignal,
    timeoutMs = SIMCTL_TIMEOUT_MS,
  ): Promise<string> {
    return this.executor.run(
      (runSignal) => this.runner(args, { signal: runSignal, timeoutMs }),
      signal,
      timeoutMs,
    );
  }

  async list(signal?: AbortSignal): Promise<SimDevice[]> {
    const out = JSON.parse(
      await this.simctl(["list", "devices", "available", "--json"], signal),
    ) as {
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

  async boot(udid: string, signal?: AbortSignal): Promise<string> {
    this.beginLifecycle(udid);
    try {
      try {
        await this.simctl(["boot", udid], signal);
      } catch (err) {
        if (!(err as Error).message.includes("current state: Booted")) throw err;
      }
      await this.simctl(["bootstatus", udid], signal); // 等待启动完成
      return "Booted";
    } finally {
      this.endLifecycle(udid);
    }
  }

  async shutdown(udid: string, signal?: AbortSignal): Promise<string> {
    this.beginLifecycle(udid);
    try {
      try {
        await this.simctl(["shutdown", udid], signal);
      } catch (err) {
        if (!(err as Error).message.includes("current state: Shutdown")) throw err;
      }
      this.stopPolling(udid);
      return "Shutdown";
    } finally {
      this.endLifecycle(udid);
    }
  }

  async attach(udid: string, signal?: AbortSignal): Promise<{ channel: number }> {
    if (this.lifecycleBusy.has(udid)) throw new Error("simulator operation in progress");
    let existing = this.attached.get(udid);
    if (existing) return { channel: existing.handle };
    const lifecycleVersion = this.lifecycleVersion;
    const devices = await this.list(signal);
    if (!devices.some((device) => device.udid === udid)) {
      throw new Error("simulator not found");
    }
    signal?.throwIfAborted();
    if (this.lifecycleBusy.has(udid) || this.lifecycleVersion !== lifecycleVersion) {
      throw new Error("simulator operation changed during attach");
    }
    // list() 等待期间另一个连接可能已经完成 attach。
    existing = this.attached.get(udid);
    if (existing) return { channel: existing.handle };
    const handle = this.nextHandle++;
    const abortController = new AbortController();
    const state = {
      handle,
      seq: 0,
      timer: setInterval(() => void this.capture(udid), POLL_MS),
      abortController,
    };
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
    state.abortController.abort(new Error("simulator detached"));
    this.emit("detached", udid, state.handle);
  }

  private beginLifecycle(udid: string): void {
    if (this.lifecycleBusy.has(udid)) throw new Error("simulator operation in progress");
    this.lifecycleVersion += 1;
    this.lifecycleBusy.add(udid);
  }

  private endLifecycle(udid: string): void {
    this.lifecycleBusy.delete(udid);
  }

  private capture(udid: string): Promise<void> {
    const state = this.attached.get(udid);
    if (!state) return Promise.resolve();
    const existing = this.captures.get(udid);
    if (existing) return existing;
    const task = this.captureOnce(udid, state).finally(() => {
      if (this.captures.get(udid) === task) this.captures.delete(udid);
    });
    this.captures.set(udid, task);
    return task;
  }

  private async captureOnce(
    udid: string,
    state: { handle: number; seq: number; timer: NodeJS.Timeout; abortController: AbortController },
  ): Promise<void> {
    // simctl 不支持 stdout 输出,落临时文件再读
    const tmp = path.join(
      os.tmpdir(),
      `acro-sim-${process.pid}-${this.instanceId}-${state.handle}.png`,
    );
    try {
      await this.simctl(
        ["io", udid, "screenshot", "--type=png", tmp],
        state.abortController.signal,
        SCREENSHOT_TIMEOUT_MS,
      );
      if (this.attached.get(udid) !== state || state.abortController.signal.aborted) return;
      // 异步读:PNG 截图可达数 MB,同步读会卡住转发终端输出的同一个事件循环
      const data = await fs.promises.readFile(tmp);
      if (this.attached.get(udid) !== state || state.abortController.signal.aborted) return;
      state.seq += 1;
      this.emit("frame", state.handle, state.seq, data);
    } catch {
      // 未启动或截图失败,下一轮再试
    } finally {
      try {
        fs.rmSync(tmp, { force: true });
      } catch {}
    }
  }

  async shutdownManager(): Promise<void> {
    for (const udid of [...this.attached.keys()]) this.stopPolling(udid);
    await Promise.allSettled([...this.captures.values()]);
    await this.executor.waitForIdle();
  }
}
