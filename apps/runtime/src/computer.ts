// acro-helper(Swift)客户端:NDJSON over Unix socket。
// helper 必须运行在已登录图形会话并持有 AX/录屏权限,由 LaunchAgent 或用户手动拉起;
// runtime 只连接,不负责 spawn。

import net from "node:net";
import os from "node:os";
import path from "node:path";
import { StringDecoder } from "node:string_decoder";

const helperSocket =
  process.env.ACRO_HELPER_SOCKET ?? path.join(os.homedir(), ".acro", "helper.sock");
const MAX_HELPER_LINE_CHARS = 64 * 1024 * 1024;
const HELPER_TIMEOUT_MS = 15_000;
const MAX_HELPER_QUEUE = 32;

interface Pending {
  resolve: (v: unknown) => void;
  reject: (e: Error) => void;
  timer: NodeJS.Timeout;
}

interface QueuedRequest {
  method: string;
  params: Record<string, unknown>;
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
}

export class HelperClient {
  private socket: net.Socket | null = null;
  private connecting: Promise<void> | null = null;
  private readonly socketPath: string;
  private buffer = "";
  private decoder = new StringDecoder("utf8");
  private nextId = 1;
  private pending = new Map<number, Pending>();
  private queue: QueuedRequest[] = [];
  private active = false;
  private closed = false;
  private readonly timeoutMs: number;
  private readonly maxQueue: number;

  constructor(socketPath = helperSocket, timeoutMs = HELPER_TIMEOUT_MS, maxQueue = MAX_HELPER_QUEUE) {
    this.socketPath = socketPath;
    this.timeoutMs = timeoutMs;
    this.maxQueue = maxQueue;
  }

  private ensureConnected(): Promise<void> {
    if (this.socket) return Promise.resolve();
    this.connecting ??= this.connect().finally(() => {
      this.connecting = null;
    });
    return this.connecting;
  }

  private connect(): Promise<void> {
    if (this.socket) return Promise.resolve();
    return new Promise<void>((resolve, reject) => {
      const socket = net.connect(this.socketPath);
      const fail = () =>
        reject(new Error("acro-helper 未运行;在图形会话中启动 acro-helper 并授予权限"));
      socket.once("error", fail);
      socket.on("connect", () => {
        socket.off("error", fail);
        if (this.closed) {
          socket.destroy();
          reject(new Error("helper client closed"));
          return;
        }
        this.socket = socket;
        socket.on("data", (chunk) => this.onData(this.decoder.write(chunk)));
        socket.on("close", () => this.onClose(socket));
        socket.on("error", () => {});
        resolve();
      });
    });
  }

  private onClose(socket: net.Socket): void {
    if (!this.resetSocket(socket)) return;
    for (const p of this.pending.values()) {
      clearTimeout(p.timer);
      p.reject(new Error("helper connection lost"));
    }
    this.pending.clear();
  }

  private resetSocket(socket: net.Socket): boolean {
    if (this.socket !== socket) return false;
    this.socket = null;
    this.buffer = "";
    this.decoder = new StringDecoder("utf8");
    return true;
  }

  private onData(text: string): void {
    this.buffer += text;
    if (this.buffer.length > MAX_HELPER_LINE_CHARS) {
      this.socket?.destroy();
      return;
    }
    let newline = this.buffer.indexOf("\n");
    while (newline >= 0) {
      const line = this.buffer.slice(0, newline);
      this.buffer = this.buffer.slice(newline + 1);
      newline = this.buffer.indexOf("\n");
      try {
        const msg = JSON.parse(line) as {
          id: number;
          ok: boolean;
          result?: unknown;
          error?: string;
        };
        const p = this.pending.get(msg.id);
        if (!p) continue;
        this.pending.delete(msg.id);
        clearTimeout(p.timer);
        if (msg.ok) p.resolve(msg.result ?? {});
        else p.reject(new Error(msg.error ?? "helper error"));
      } catch {
        // 非法行丢弃
      }
    }
  }

  request<T = unknown>(method: string, params: Record<string, unknown> = {}): Promise<T> {
    if (this.closed) return Promise.reject(new Error("helper client closed"));
    if (this.queue.length >= this.maxQueue) {
      return Promise.reject(new Error("helper request queue full"));
    }
    return new Promise<T>((resolve, reject) => {
      this.queue.push({
        method,
        params,
        resolve: resolve as (value: unknown) => void,
        reject,
      });
      void this.pump();
    });
  }

  private async pump(): Promise<void> {
    if (this.active || this.closed) return;
    const queued = this.queue.shift();
    if (!queued) return;
    this.active = true;
    try {
      await this.ensureConnected();
      queued.resolve(await this.send(queued.method, queued.params));
    } catch (error) {
      queued.reject(error as Error);
    } finally {
      this.active = false;
      void this.pump();
    }
  }

  private send(method: string, params: Record<string, unknown>): Promise<unknown> {
    const id = this.nextId++;
    const deadlineMs = Date.now() + this.timeoutMs;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        if (!this.pending.delete(id)) return;
        const socket = this.socket;
        if (socket && this.resetSocket(socket)) socket.destroy();
        reject(new Error(`helper timeout: ${method}`));
      }, this.timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      this.socket!.write(`${JSON.stringify({ id, method, params, deadlineMs })}\n`, (error) => {
        if (!error) return;
        const pending = this.pending.get(id);
        if (!pending) return;
        this.pending.delete(id);
        clearTimeout(pending.timer);
        const socket = this.socket;
        if (socket && this.resetSocket(socket)) socket.destroy();
        reject(error);
      });
    });
  }

  close(): void {
    this.closed = true;
    for (const queued of this.queue.splice(0)) queued.reject(new Error("helper client closed"));
    this.socket?.destroy();
  }
}
