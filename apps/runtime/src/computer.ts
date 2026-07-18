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

interface Pending {
  resolve: (v: unknown) => void;
  reject: (e: Error) => void;
  timer: NodeJS.Timeout;
}

export class HelperClient {
  private socket: net.Socket | null = null;
  private buffer = "";
  private decoder = new StringDecoder("utf8");
  private nextId = 1;
  private pending = new Map<number, Pending>();

  private async ensureConnected(): Promise<void> {
    if (this.socket) return;
    await new Promise<void>((resolve, reject) => {
      const socket = net.connect(helperSocket);
      socket.on("connect", () => {
        this.socket = socket;
        socket.on("data", (chunk) => this.onData(this.decoder.write(chunk)));
        socket.on("close", () => this.onClose());
        socket.on("error", () => {});
        resolve();
      });
      socket.on("error", () =>
        reject(new Error("acro-helper 未运行;在图形会话中启动 acro-helper 并授予权限")),
      );
    });
  }

  private onClose(): void {
    this.socket = null;
    this.buffer = "";
    this.decoder = new StringDecoder("utf8");
    for (const p of this.pending.values()) {
      clearTimeout(p.timer);
      p.reject(new Error("helper connection lost"));
    }
    this.pending.clear();
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

  async request<T = unknown>(method: string, params: Record<string, unknown> = {}): Promise<T> {
    await this.ensureConnected();
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        if (this.pending.delete(id)) reject(new Error(`helper timeout: ${method}`));
      }, 15000);
      this.pending.set(id, { resolve: resolve as (v: unknown) => void, reject, timer });
      this.socket!.write(`${JSON.stringify({ id, method, params })}\n`, (error) => {
        if (!error) return;
        const pending = this.pending.get(id);
        if (!pending) return;
        this.pending.delete(id);
        clearTimeout(pending.timer);
        reject(error);
      });
    });
  }

  close(): void {
    this.socket?.destroy();
  }
}
