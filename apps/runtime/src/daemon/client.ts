// Runtime 侧的 daemon 客户端:按需拉起 daemon、断线重连、请求/事件/帧分发。

import { EventEmitter } from "node:events";
import { spawn } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import { fileURLToPath } from "node:url";
import type { OutFrame } from "@acro/protocol";
import { decodeFrame, encodeInFrame, FRAME_OUT } from "@acro/protocol";
import { paths } from "../paths.ts";
import { daemonClientBufferExceeded } from "./backpressure.ts";
import { FrameReader, KIND_BIN, KIND_JSON, packBin, packJson } from "./wire.ts";

interface Pending {
  resolve: (v: unknown) => void;
  reject: (e: Error) => void;
  beforeResolve?: ((value: unknown) => void) | undefined;
  timer: NodeJS.Timeout;
}

export const DAEMON_REQUEST_TIMEOUT_MS = 15_000;
export const MAX_PENDING_DAEMON_REQUESTS = 256;

export interface DaemonEvent {
  seq: number;
  boot: string;
  event: string;
  payload: unknown;
}

export class DaemonClient extends EventEmitter {
  private socket: net.Socket | null = null;
  private reader = new FrameReader();
  private nextId = 1;
  private pending = new Map<number, Pending>();
  private timedOut = new Map<number, string>();
  private completedTimedOutMethods = new Set<string>();
  private stalled = false;
  private closed = false;
  private readonly requestTimeoutMs: number;
  private readonly maxPending: number;

  constructor(
    requestTimeoutMs = DAEMON_REQUEST_TIMEOUT_MS,
    maxPending = MAX_PENDING_DAEMON_REQUESTS,
  ) {
    super();
    this.requestTimeoutMs = requestTimeoutMs;
    this.maxPending = maxPending;
  }

  static async connect(): Promise<DaemonClient> {
    const client = new DaemonClient();
    await client.ensureConnected();
    return client;
  }

  private async ensureConnected(): Promise<void> {
    try {
      await this.tryConnect();
    } catch {
      spawnDaemon();
      await retry(() => this.tryConnect(), 50, 100);
    }
  }

  private tryConnect(): Promise<void> {
    return new Promise((resolve, reject) => {
      const socket = net.connect(paths.daemonSocket);
      socket.on("connect", () => {
        this.socket = socket;
        socket.on("data", (chunk) => {
          try {
            this.onData(chunk);
          } catch {
            socket.destroy();
          }
        });
        socket.on("close", () => this.onClose(socket));
        socket.on("error", () => {});
        this.emit("up");
        resolve();
      });
      socket.on("error", (err) => reject(err));
    });
  }

  private onClose(socket: net.Socket): void {
    if (this.socket !== socket) return;
    this.socket = null;
    this.reader.reset();
    for (const p of this.pending.values()) {
      clearTimeout(p.timer);
      p.reject(new Error("daemon connection lost"));
    }
    this.pending.clear();
    this.timedOut.clear();
    this.completedTimedOutMethods.clear();
    this.stalled = false;
    this.emit("down");
    if (this.closed) return;
    void retry(() => this.ensureConnected(), 100, 200).catch(() => {});
  }

  private onData(chunk: Buffer): void {
    for (const msg of this.reader.push(chunk)) {
      if (msg.kind === KIND_BIN) {
        const frame = decodeFrame(msg.body);
        if (frame.type === FRAME_OUT) this.emit("frame", frame satisfies OutFrame);
        continue;
      }
      if (msg.kind !== KIND_JSON) continue;
      const parsed = JSON.parse(msg.body.toString("utf8")) as
        | { t: "res"; id: number; ok: true; result: unknown }
        | { t: "res"; id: number; ok: false; error: { message: string } }
        | ({ t: "evt" } & DaemonEvent);
      if (parsed.t === "res") {
        const p = this.pending.get(parsed.id);
        if (!p) {
          const timedOutMethod = this.timedOut.get(parsed.id);
          if (timedOutMethod) {
            this.timedOut.delete(parsed.id);
            this.completedTimedOutMethods.add(timedOutMethod);
            this.recoverIfDrained();
          }
          continue;
        }
        this.pending.delete(parsed.id);
        clearTimeout(p.timer);
        this.recoverIfDrained();
        if (parsed.ok) {
          try {
            p.beforeResolve?.(parsed.result);
            p.resolve(parsed.result);
          } catch (error) {
            p.reject(error as Error);
          }
        } else p.reject(new Error(parsed.error.message));
      } else if (parsed.t === "evt") {
        this.emit("event", parsed);
      }
    }
  }

  request<T = unknown>(
    method: string,
    params?: unknown,
    beforeResolve?: (result: T) => void,
  ): Promise<T> {
    if (!this.socket) return Promise.reject(new Error("daemon not connected"));
    if (this.stalled) return Promise.reject(new Error("daemon stalled after request timeout"));
    if (this.pending.size >= this.maxPending) {
      return Promise.reject(new Error("daemon request queue full"));
    }
    const id = this.nextId++;
    const socket = this.socket;
    const deadline = Date.now() + this.requestTimeoutMs;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        const pending = this.pending.get(id);
        if (!pending) return;
        this.pending.delete(id);
        this.timedOut.set(id, method);
        this.stalled = true;
        pending.reject(new Error(`daemon timeout: ${method}`));
      }, this.requestTimeoutMs);
      this.pending.set(id, {
        resolve: resolve as (v: unknown) => void,
        reject,
        beforeResolve: beforeResolve as ((value: unknown) => void) | undefined,
        timer,
      });
      const failWrite = (error: Error) => {
        const pending = this.pending.get(id);
        if (pending) {
          this.pending.delete(id);
          clearTimeout(pending.timer);
          this.recoverIfDrained();
          pending.reject(error);
        }
        socket.destroy();
      };
      try {
        socket.write(packJson({ t: "req", id, method, params, deadline }), (error) => {
          if (error) failWrite(error);
        });
      } catch (error) {
        failWrite(error instanceof Error ? error : new Error(String(error)));
      }
    });
  }

  private recoverIfDrained(): void {
    if (this.stalled && this.timedOut.size === 0 && this.pending.size === 0) {
      this.stalled = false;
      const methods = [...this.completedTimedOutMethods];
      this.completedTimedOutMethods.clear();
      this.emit("lateResponsesDrained", methods);
    }
  }

  sendInput(handle: number, data: Uint8Array): void {
    const socket = this.socket;
    if (!socket) return;
    const frame = packBin(encodeInFrame(handle, data));
    if (socket.destroyed || daemonClientBufferExceeded(socket.writableLength, frame.byteLength)) {
      socket.destroy();
      return;
    }
    try {
      socket.write(frame);
    } catch {
      socket.destroy();
    }
  }

  close(): void {
    this.closed = true;
    this.socket?.destroy();
  }
}

function spawnDaemon(): void {
  // 打包形态(app 内置 runtime.cjs)下 daemon 入口由环境变量显式指定;
  // cjs bundle 里 import.meta.url 为空,缺环境变量时给出明确报错而不是 Invalid URL
  let entry = process.env.ACRO_DAEMON_ENTRY;
  if (!entry) {
    if (!import.meta.url) {
      throw new Error("bundled runtime requires ACRO_DAEMON_ENTRY to locate daemon.cjs");
    }
    entry = fileURLToPath(new URL("./daemon.ts", import.meta.url));
  }
  const logFd = fs.openSync(paths.daemonLog, "a");
  // Node 22+ 直接运行 .ts;父进程的 --inspect/--input-type 等参数不能透传给文件入口
  const child = spawn(process.execPath, [entry], {
    detached: true,
    stdio: ["ignore", logFd, logFd],
    env: process.env,
  });
  child.unref();
  fs.closeSync(logFd);
}

async function retry<T>(fn: () => Promise<T>, attempts: number, delayMs: number): Promise<T> {
  let lastErr: unknown;
  for (let i = 0; i < attempts; i += 1) {
    try {
      return await fn();
    } catch (err) {
      lastErr = err;
      await new Promise((r) => setTimeout(r, delayMs));
    }
  }
  throw lastErr;
}
