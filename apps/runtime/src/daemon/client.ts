// Runtime 侧的 daemon 客户端:按需拉起 daemon、断线重连、请求/事件/帧分发。

import { EventEmitter } from "node:events";
import { spawn } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import { fileURLToPath } from "node:url";
import type { OutFrame } from "@acro/protocol";
import { decodeFrame, encodeInFrame, FRAME_OUT } from "@acro/protocol";
import { paths } from "../paths.ts";
import {
  DAEMON_PROTOCOL_VERSION,
  FrameReader,
  KIND_BIN,
  KIND_JSON,
  packBin,
  packJson,
} from "./wire.ts";

interface Pending {
  resolve: (v: unknown) => void;
  reject: (e: Error) => void;
}

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
  private closed = false;
  private daemonPid = 0;
  private protocolVersion = 0;

  get supportsCwdInheritance(): boolean {
    return this.protocolVersion >= DAEMON_PROTOCOL_VERSION;
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
    await this.loadDaemonInfo();
    if (!this.supportsCwdInheritance) {
      const sessions = await this.request<Array<{ id: string; alive: boolean }>>("session.list");
      const liveSession = sessions.find((session) => session.alive);
      if (liveSession) {
        try {
          await this.request("session.cwd", { sessionId: liveSession.id });
          this.protocolVersion = DAEMON_PROTOCOL_VERSION;
        } catch {
          // 真正的旧 daemon:保留活会话,新建继承终端时返回明确错误
        }
      } else {
        await this.replaceOutdatedDaemon();
      }
    }
    this.emit("up");
  }

  private tryConnect(): Promise<void> {
    return new Promise((resolve, reject) => {
      const socket = net.connect(paths.daemonSocket);
      socket.on("connect", () => {
        this.socket = socket;
        socket.on("data", (chunk) => this.onData(chunk));
        socket.on("close", () => this.onClose(socket));
        socket.on("error", () => {});
        resolve();
      });
      socket.on("error", (err) => reject(err));
    });
  }

  private onClose(socket: net.Socket): void {
    if (this.socket !== socket) return;
    this.socket = null;
    this.daemonPid = 0;
    this.protocolVersion = 0;
    for (const p of this.pending.values()) p.reject(new Error("daemon connection lost"));
    this.pending.clear();
    this.emit("down");
    if (this.closed) return;
    void retry(() => this.ensureConnected(), 100, 200).catch(() => {});
  }

  private async loadDaemonInfo(): Promise<void> {
    const info = await this.request<{ pid: number; protocolVersion?: number }>("daemon.info");
    this.daemonPid = info.pid;
    this.protocolVersion = info.protocolVersion ?? 0;
  }

  private async replaceOutdatedDaemon(): Promise<void> {
    const pid = this.daemonPid;
    const socket = this.socket;
    this.socket = null;
    socket?.destroy();
    if (processExists(pid)) process.kill(pid, "SIGTERM");
    await retry(async () => {
      if (processExists(pid)) throw new Error("outdated daemon still running");
    }, 50, 100);
    spawnDaemon();
    await retry(() => this.tryConnect(), 50, 100);
    await this.loadDaemonInfo();
    if (!this.supportsCwdInheritance) throw new Error("failed to upgrade terminal daemon");
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
        if (parsed.ok) p.resolve(parsed.result);
        else p.reject(new Error(parsed.error.message));
      } else if (parsed.t === "evt") {
        this.emit("event", parsed);
      }
    }
  }

  request<T = unknown>(method: string, params?: unknown): Promise<T> {
    if (!this.socket) return Promise.reject(new Error("daemon not connected"));
    const id = this.nextId++;
    this.socket.write(packJson({ t: "req", id, method, params }));
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (v: unknown) => void, reject });
    });
  }

  sendInput(handle: number, data: Uint8Array): void {
    this.socket?.write(packBin(encodeInFrame(handle, data)));
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
  // dev 下 execArgv 带着 tsx loader,daemon 跟随同一运行方式;build 后是纯 js
  const child = spawn(process.execPath, [...process.execArgv, entry], {
    detached: true,
    stdio: ["ignore", logFd, logFd],
    env: process.env,
  });
  child.unref();
  fs.closeSync(logFd);
}

function processExists(pid: number): boolean {
  if (pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ESRCH") return false;
    throw error;
  }
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
