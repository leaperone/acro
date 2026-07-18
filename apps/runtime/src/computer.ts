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
  cleanup: () => void;
}

interface QueuedRequest {
  method: string;
  params: Record<string, unknown>;
  deadlineMs: number;
  signal?: AbortSignal;
  abortListener?: () => void;
  deadlineTimer: NodeJS.Timeout | null;
  settled: boolean;
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
}

function abortError(signal: AbortSignal): Error {
  return signal.reason instanceof Error ? signal.reason : new Error("helper request aborted");
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
  private activeRequest: QueuedRequest | null = null;
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
      p.cleanup();
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
        p.cleanup();
        if (msg.ok) p.resolve(msg.result ?? {});
        else p.reject(new Error(msg.error ?? "helper error"));
      } catch {
        // 非法行丢弃
      }
    }
  }

  request<T = unknown>(
    method: string,
    params: Record<string, unknown> = {},
    signal?: AbortSignal,
  ): Promise<T> {
    if (this.closed) return Promise.reject(new Error("helper client closed"));
    if (signal?.aborted) return Promise.reject(abortError(signal));
    if (this.queue.length >= this.maxQueue) {
      return Promise.reject(new Error("helper request queue full"));
    }
    return new Promise<T>((resolve, reject) => {
      const queued: QueuedRequest = {
        method,
        params,
        deadlineMs: Date.now() + this.timeoutMs,
        ...(signal ? { signal } : {}),
        deadlineTimer: null,
        settled: false,
        resolve: resolve as (value: unknown) => void,
        reject,
      };
      queued.deadlineTimer = setTimeout(
        () => this.cancelRequest(queued, new Error(`helper timeout: ${method}`)),
        this.timeoutMs,
      );
      if (signal) {
        queued.abortListener = () => this.cancelRequest(queued, abortError(signal));
        signal.addEventListener("abort", queued.abortListener, { once: true });
      }
      this.queue.push(queued);
      void this.pump();
    });
  }

  private cleanupRequest(queued: QueuedRequest): void {
    if (queued.deadlineTimer) clearTimeout(queued.deadlineTimer);
    queued.deadlineTimer = null;
    if (queued.signal && queued.abortListener) {
      queued.signal.removeEventListener("abort", queued.abortListener);
    }
  }

  private resolveRequest(queued: QueuedRequest, value: unknown): void {
    if (queued.settled) return;
    queued.settled = true;
    this.cleanupRequest(queued);
    queued.resolve(value);
  }

  private rejectRequest(queued: QueuedRequest, error: Error): void {
    if (queued.settled) return;
    queued.settled = true;
    this.cleanupRequest(queued);
    queued.reject(error);
  }

  private cancelRequest(queued: QueuedRequest, error: Error): void {
    const index = this.queue.indexOf(queued);
    if (index >= 0) this.queue.splice(index, 1);
    if (this.activeRequest === queued) this.dropSocket();
    this.rejectRequest(queued, error);
  }

  private async pump(): Promise<void> {
    if (this.active || this.closed) return;
    const queued = this.queue.shift();
    if (!queued) return;
    this.active = true;
    this.activeRequest = queued;
    try {
      if (queued.signal?.aborted) throw abortError(queued.signal);
      await this.ensureConnected();
      if (queued.settled) return;
      if (queued.signal?.aborted) {
        this.dropSocket();
        throw abortError(queued.signal);
      }
      if (Date.now() >= queued.deadlineMs) {
        throw new Error(`helper timeout: ${queued.method}`);
      }
      if (queued.deadlineTimer) clearTimeout(queued.deadlineTimer);
      queued.deadlineTimer = null;
      this.resolveRequest(
        queued,
        await this.send(queued.method, queued.params, queued.deadlineMs, queued.signal),
      );
    } catch (error) {
      this.rejectRequest(queued, error as Error);
    } finally {
      if (this.activeRequest === queued) this.activeRequest = null;
      this.active = false;
      void this.pump();
    }
  }

  private dropSocket(): void {
    const socket = this.socket;
    if (socket && this.resetSocket(socket)) socket.destroy();
  }

  private send(
    method: string,
    params: Record<string, unknown>,
    deadlineMs: number,
    signal?: AbortSignal,
  ): Promise<unknown> {
    if (signal?.aborted) return Promise.reject(abortError(signal));
    const id = this.nextId++;
    const remainingMs = deadlineMs - Date.now();
    if (remainingMs <= 0) return Promise.reject(new Error(`helper timeout: ${method}`));
    return new Promise((resolve, reject) => {
      let abortListener: (() => void) | undefined;
      const cleanup = () => {
        clearTimeout(timer);
        if (signal && abortListener) signal.removeEventListener("abort", abortListener);
      };
      const fail = (error: Error) => {
        const pending = this.pending.get(id);
        if (!pending) return;
        this.pending.delete(id);
        pending.cleanup();
        this.dropSocket();
        reject(error);
      };
      const timer = setTimeout(() => {
        fail(new Error(`helper timeout: ${method}`));
      }, remainingMs);
      abortListener = () => fail(abortError(signal!));
      this.pending.set(id, { resolve, reject, timer, cleanup });
      if (signal) signal.addEventListener("abort", abortListener, { once: true });
      this.socket!.write(`${JSON.stringify({ id, method, params, deadlineMs })}\n`, (error) => {
        if (!error) return;
        fail(error);
      });
    });
  }

  close(): void {
    this.closed = true;
    for (const queued of this.queue.splice(0)) {
      this.rejectRequest(queued, new Error("helper client closed"));
    }
    if (this.activeRequest) {
      this.rejectRequest(this.activeRequest, new Error("helper client closed"));
    }
    this.socket?.destroy();
  }
}
