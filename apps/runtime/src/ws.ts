import type { IncomingMessage } from "node:http";
import type { Duplex } from "node:stream";
import { WebSocketServer, WebSocket } from "ws";
import type { Device, OutFrame } from "@acro/protocol";
import {
  decodeFrame,
  encodeBrowserFrame,
  encodeOutFrame,
  encodeSimFrame,
  FRAME_IN,
  methods,
  RpcRequest,
} from "@acro/protocol";
import type { DeviceRegistry } from "./devices.ts";

export interface Conn {
  ws: WebSocket;
  device: Device;
  // channel(=daemon handle) -> 附着状态。attachSeq 之前的输出已包含在快照里。
  attached: Map<number, { sessionId: string; attachSeq: number }>;
  // 已附着的浏览器 screencast channel
  browserChannels: Set<number>;
  // 已附着的模拟器画面 channel
  simChannels: Set<number>;
  // 心跳:上一轮 ping 后是否收到 pong(取自 orca ws-transport 的半开连接回收)
  alive: boolean;
}

// 移动端后台挂起会留下半开 socket,macOS TCP keepalive 默认 2 小时才发现;
// 每轮 ping,下一轮仍未 pong 就 terminate。
const HEARTBEAT_INTERVAL_MS = 15_000;

export type Handlers = {
  [M in keyof typeof methods]: (
    conn: Conn,
    params: import("zod").infer<(typeof methods)[M]["params"]>,
  ) => Promise<unknown> | unknown;
};

export class Gateway {
  private wss = new WebSocketServer({ noServer: true });
  private conns = new Set<Conn>();
  private heartbeat: NodeJS.Timeout;

  private registry: DeviceRegistry;
  private handlers: Handlers;
  private onInput: (sessionHandle: number, data: Uint8Array) => void;

  constructor(
    registry: DeviceRegistry,
    handlers: Handlers,
    onInput: (sessionHandle: number, data: Uint8Array) => void,
  ) {
    this.registry = registry;
    this.handlers = handlers;
    this.onInput = onInput;
    this.heartbeat = setInterval(() => {
      for (const conn of this.conns) {
        if (!conn.alive) {
          conn.ws.terminate();
          this.conns.delete(conn);
          continue;
        }
        conn.alive = false;
        conn.ws.ping();
      }
    }, HEARTBEAT_INTERVAL_MS);
    this.heartbeat.unref();
  }

  handleUpgrade(req: IncomingMessage, socket: Duplex, head: Buffer): void {
    const url = new URL(req.url ?? "/", "http://localhost");
    const token = url.searchParams.get("token") ?? "";
    const device = token ? this.registry.auth(token) : null;
    if (url.pathname !== "/ws" || !device) {
      socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
      socket.destroy();
      return;
    }
    this.wss.handleUpgrade(req, socket, head, (ws) => {
      const conn: Conn = {
        ws,
        device,
        attached: new Map(),
        browserChannels: new Set(),
        simChannels: new Set(),
        alive: true,
      };
      this.conns.add(conn);
      ws.on("message", (raw, isBinary) => this.onMessage(conn, raw as Buffer, isBinary));
      ws.on("pong", () => {
        conn.alive = true;
      });
      ws.on("close", () => this.conns.delete(conn));
      ws.on("error", () => this.conns.delete(conn));
    });
  }

  private onMessage(conn: Conn, raw: Buffer, isBinary: boolean): void {
    if (isBinary) {
      try {
        const frame = decodeFrame(raw);
        if (frame.type === FRAME_IN && conn.attached.has(frame.channel)) {
          this.onInput(frame.channel, frame.data);
        }
      } catch {
        // 非法帧直接丢弃
      }
      return;
    }
    let req: RpcRequest;
    try {
      req = RpcRequest.parse(JSON.parse(raw.toString("utf8")));
    } catch {
      return;
    }
    void this.dispatch(conn, req);
  }

  private async dispatch(conn: Conn, req: RpcRequest): Promise<void> {
    const send = (msg: unknown) => conn.ws.send(JSON.stringify(msg));
    const method = methods[req.method as keyof typeof methods];
    if (!method) {
      send({ t: "res", id: req.id, ok: false, error: { code: "unknown_method", message: req.method } });
      return;
    }
    const parsed = method.params.safeParse(req.params ?? {});
    if (!parsed.success) {
      send({
        t: "res",
        id: req.id,
        ok: false,
        error: { code: "invalid_params", message: parsed.error.message },
      });
      return;
    }
    try {
      const handler = this.handlers[req.method as keyof typeof methods];
      const result = await handler(conn, parsed.data as never);
      send({ t: "res", id: req.id, ok: true, result: method.result.parse(result) });
    } catch (err) {
      send({
        t: "res",
        id: req.id,
        ok: false,
        error: { code: "internal", message: (err as Error).message },
      });
    }
  }

  forwardBrowserFrame(channel: number, seq: number, data: Uint8Array): void {
    for (const conn of this.conns) {
      if (conn.browserChannels.has(channel)) {
        conn.ws.send(encodeBrowserFrame(channel, seq, data), { binary: true });
      }
    }
  }

  forwardSimFrame(channel: number, seq: number, data: Uint8Array): void {
    for (const conn of this.conns) {
      if (conn.simChannels.has(channel)) {
        conn.ws.send(encodeSimFrame(channel, seq, data), { binary: true });
      }
    }
  }

  forwardFrame(frame: OutFrame): void {
    for (const conn of this.conns) {
      const st = conn.attached.get(frame.channel);
      if (st && frame.seq > st.attachSeq) {
        conn.ws.send(encodeOutFrame(frame.channel, frame.seq, frame.data), { binary: true });
      }
    }
  }

  broadcastEvent(evt: { seq: number; boot: string; event: string; payload: unknown }): void {
    const msg = JSON.stringify({ t: "evt", ...evt });
    for (const conn of this.conns) conn.ws.send(msg);
  }

  close(): void {
    clearInterval(this.heartbeat);
    for (const conn of this.conns) conn.ws.close();
    this.wss.close();
  }
}
