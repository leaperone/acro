import type { MethodName, MethodParams, MethodResult } from "@acro/protocol";
import { decodeFrame, type Frame } from "@acro/protocol";

export interface PairResult {
  deviceId: string;
  token: string;
}

export async function pairWithHost(
  host: string,
  code: string,
  deviceName: string,
): Promise<PairResult> {
  const res = await fetch(`http://${host}/pair`, {
    method: "POST",
    body: JSON.stringify({ code, deviceName }),
  });
  if (!res.ok) throw new Error(`配对失败 (${res.status})`);
  return (await res.json()) as PairResult;
}

type PendingEntry = { resolve: (v: unknown) => void; reject: (e: Error) => void };

// 单条 WS:JSON 控制消息 + 二进制帧,断线自动重连。
export class MobileClient {
  private ws: WebSocket | null = null;
  private host: string;
  private token: string;
  private nextId = 1;
  private pending = new Map<number, PendingEntry>();
  private closed = false;
  onFrame: ((frame: Frame) => void) | null = null;
  onEvent: ((event: string, payload: unknown) => void) | null = null;
  onStateChange: ((connected: boolean) => void) | null = null;

  constructor(host: string, token: string) {
    this.host = host;
    this.token = token;
  }

  connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(`ws://${this.host}/ws?token=${this.token}`);
      ws.binaryType = "arraybuffer";
      ws.onopen = () => {
        this.ws = ws;
        this.onStateChange?.(true);
        resolve();
      };
      ws.onerror = () => {
        if (!this.ws) reject(new Error("连接失败"));
      };
      ws.onclose = () => {
        this.ws = null;
        for (const p of this.pending.values()) p.reject(new Error("连接断开"));
        this.pending.clear();
        this.onStateChange?.(false);
        if (!this.closed) setTimeout(() => void this.connect().catch(() => {}), 1500);
      };
      ws.onmessage = (ev: MessageEvent) => {
        if (ev.data instanceof ArrayBuffer) {
          this.onFrame?.(decodeFrame(new Uint8Array(ev.data)));
          return;
        }
        const msg = JSON.parse(String(ev.data));
        if (msg.t === "res") {
          const p = this.pending.get(msg.id);
          if (!p) return;
          this.pending.delete(msg.id);
          if (msg.ok) p.resolve(msg.result);
          else p.reject(new Error(`${msg.error.code}: ${msg.error.message}`));
        } else if (msg.t === "evt") {
          this.onEvent?.(msg.event, msg.payload);
        }
      };
    });
  }

  rpc<M extends MethodName>(method: M, params: MethodParams<M>): Promise<MethodResult<M>> {
    const ws = this.ws;
    if (!ws) return Promise.reject(new Error("未连接"));
    const id = this.nextId++;
    ws.send(JSON.stringify({ t: "req", id, method, params }));
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (v: unknown) => void, reject });
      setTimeout(() => {
        if (this.pending.delete(id)) reject(new Error(`超时: ${method}`));
      }, 20000);
    });
  }

  sendBinary(data: Uint8Array): void {
    this.ws?.send(data.buffer as ArrayBuffer);
  }

  get connected(): boolean {
    return this.ws !== null;
  }

  close(): void {
    this.closed = true;
    this.ws?.close();
  }
}
