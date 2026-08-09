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

interface DaemonRequestOptions {
  deadline?: number;
  destroySocketOnTimeout?: boolean;
}

export class DaemonClient extends EventEmitter {
  private socket: net.Socket | null = null;
  private reader = new FrameReader();
  private nextId = 1;
  private pending = new Map<number, Pending>();
  private closed = false;
  private readonly requestTimeoutMs: number;
  private readonly maxPending: number;
  // 当前 daemon 声明支持的方法。每次连接建立后重新协商:
  // daemon 独立于 runtime 升级,能力必须绑定到具体连接而不是进程生命周期。
  private capabilities = new Set<string>();

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
        // 先协商能力再宣告可用:恢复流程紧跟 "up" 运行,不能读到空能力集而误判为旧 daemon。
        void this.negotiate().then(() => {
          // 协商期间连接可能已经断开并被 onClose 换掉;在死连接上宣告 up 只会让
          // 恢复流程白跑一轮。此时重连已在路上,交给下一次 up。
          if (this.socket !== socket) {
            reject(new Error("daemon connection lost during negotiation"));
            return;
          }
          this.emit("up");
          resolve();
        });
      });
      socket.on("error", (err) => reject(err));
    });
  }

  // 握手失败不是致命错误:旧 daemon 的 daemon.info 没有 methods,超时或报错也一样,
  // 一律落到空能力集,即"不支持任何需要显式声明的方法"。
  private async negotiate(): Promise<void> {
    this.capabilities = new Set();
    try {
      const info = await this.request<{ methods?: unknown }>("daemon.info", {}, undefined, {
        destroySocketOnTimeout: false,
      });
      if (Array.isArray(info?.methods)) {
        this.capabilities = new Set(info.methods.filter((m): m is string => typeof m === "string"));
      }
    } catch {
      // 保持空能力集
    }
  }

  // daemon 是否明确声明支持该方法。旧 daemon(不报告 methods)恒为 false,
  // 调用方据此给出"daemon 过旧"的处置,而不是解析错误文案。
  supports(method: string): boolean {
    return this.capabilities.has(method);
  }

  private onClose(socket: net.Socket): void {
    if (this.socket !== socket) return;
    this.socket = null;
    this.capabilities = new Set();
    this.reader.reset();
    for (const p of this.pending.values()) {
      clearTimeout(p.timer);
      p.reject(new Error("daemon connection lost"));
    }
    this.pending.clear();
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
        if (!p) continue;
        this.pending.delete(parsed.id);
        clearTimeout(p.timer);
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
    options: DaemonRequestOptions = {},
  ): Promise<T> {
    if (!this.socket) return Promise.reject(new Error("daemon not connected"));
    if (this.pending.size >= this.maxPending) {
      return Promise.reject(new Error("daemon request queue full"));
    }
    const id = this.nextId++;
    const socket = this.socket;
    const now = Date.now();
    const requestDeadline = Math.min(options.deadline ?? Infinity, now + this.requestTimeoutMs);
    if (!Number.isFinite(requestDeadline) || requestDeadline <= now) {
      return Promise.reject(new Error(`daemon timeout: ${method}`));
    }
    const timeoutMs = requestDeadline - now;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        const pending = this.pending.get(id);
        if (!pending) return;
        this.pending.delete(id);
        pending.reject(new Error(`daemon timeout: ${method}`));
        // 请求已失去完成边界。继续复用同一 socket 会让所有后续终端 RPC
        // 永久依赖一个可能永远不来的迟到响应;关闭后走既有重连和状态恢复。
        if (options.destroySocketOnTimeout !== false) socket.destroy();
      }, timeoutMs);
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
          pending.reject(error);
        }
        socket.destroy();
      };
      try {
        socket.write(packJson({ t: "req", id, method, params, deadline: requestDeadline }), (error) => {
          if (error) failWrite(error);
        });
      } catch (error) {
        failWrite(error instanceof Error ? error : new Error(String(error)));
      }
    });
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
