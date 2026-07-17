// acro-helper(Swift)客户端:NDJSON over Unix socket。
// helper 必须运行在已登录图形会话并持有 AX/录屏权限,由 LaunchAgent 或用户手动拉起;
// runtime 只连接,不负责 spawn。

import net from "node:net";
import os from "node:os";
import path from "node:path";

const helperSocket =
  process.env.ACRO_HELPER_SOCKET ?? path.join(os.homedir(), ".acro", "helper.sock");

interface Pending {
  resolve: (v: unknown) => void;
  reject: (e: Error) => void;
}

export class HelperClient {
  private socket: net.Socket | null = null;
  private buffer = "";
  private nextId = 1;
  private pending = new Map<number, Pending>();

  private async ensureConnected(): Promise<void> {
    if (this.socket) return;
    await new Promise<void>((resolve, reject) => {
      const socket = net.connect(helperSocket);
      socket.on("connect", () => {
        this.socket = socket;
        socket.on("data", (chunk) => this.onData(chunk.toString("utf8")));
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
    for (const p of this.pending.values()) p.reject(new Error("helper connection lost"));
    this.pending.clear();
  }

  private onData(text: string): void {
    this.buffer += text;
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
    this.socket!.write(`${JSON.stringify({ id, method, params })}\n`);
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (v: unknown) => void, reject });
      setTimeout(() => {
        if (this.pending.delete(id)) reject(new Error(`helper timeout: ${method}`));
      }, 15000);
    });
  }

  close(): void {
    this.socket?.destroy();
  }
}
