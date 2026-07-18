import type { IncomingMessage } from "node:http";
import type { Duplex } from "node:stream";
import { WebSocketServer, WebSocket } from "ws";
import type { Device, E2eeSession, OutFrame } from "@acro/protocol";
import {
  decodeFrame,
  E2eeAuth,
  encodeBrowserFrame,
  encodeOutFrame,
  encodeSimFrame,
  FRAME_IN,
  type HelloMessage,
  methods,
  RpcRequest,
  ServerHandshake,
} from "@acro/protocol";
import type { DeviceRegistry } from "./devices.ts";

export interface Conn {
  ws: WebSocket;
  // E2EE 握手完成后建立;认证前只允许 auth 消息
  session: E2eeSession | null;
  device: Device | null;
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
// 握手 + 认证必须在此时限内完成(取自 orca 的 PRE_AUTH_TIMEOUT)
const PRE_AUTH_TIMEOUT_MS = 10_000;

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
  private identityPriv: Uint8Array;
  private handlers: Handlers;
  private onInput: (sessionHandle: number, data: Uint8Array) => void;
  // 首个设备认证成功的回调(用于清理 bootstrap 配对码文件)
  onAuthenticated: ((device: Device) => void) | null = null;
  // 终端占用锁:返回 false 时丢弃该连接对该会话的输入帧
  inputGate: ((conn: Conn, sessionId: string) => boolean) | null = null;
  // 已认证连接关闭(占用释放等簿记用)
  onConnClosed: ((conn: Conn) => void) | null = null;

  constructor(
    registry: DeviceRegistry,
    identityPriv: Uint8Array,
    handlers: Handlers,
    onInput: (sessionHandle: number, data: Uint8Array) => void,
  ) {
    this.registry = registry;
    this.identityPriv = identityPriv;
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
    if (url.pathname !== "/ws") {
      socket.write("HTTP/1.1 404 Not Found\r\n\r\n");
      socket.destroy();
      return;
    }
    this.wss.handleUpgrade(req, socket, head, (ws) => {
      const conn: Conn = {
        ws,
        session: null,
        device: null,
        attached: new Map(),
        browserChannels: new Set(),
        simChannels: new Set(),
        alive: true,
      };
      this.conns.add(conn);
      const preAuthTimer = setTimeout(() => {
        if (!conn.device) ws.terminate();
      }, PRE_AUTH_TIMEOUT_MS);
      preAuthTimer.unref();
      ws.on("message", (raw, isBinary) => this.onMessage(conn, raw as Buffer, isBinary));
      ws.on("pong", () => {
        conn.alive = true;
      });
      ws.on("close", () => {
        clearTimeout(preAuthTimer);
        this.conns.delete(conn);
        if (conn.device) this.onConnClosed?.(conn);
      });
      ws.on("error", () => this.conns.delete(conn));
    });
  }

  hasDeviceConnection(deviceId: string): boolean {
    for (const conn of this.conns) {
      if (conn.device?.id === deviceId) return true;
    }
    return false;
  }

  // 撤销授权时立即断开该设备的所有活动连接(orca terminateClientConnections)
  terminateDevice(deviceId: string): void {
    for (const conn of this.conns) {
      if (conn.device?.id === deviceId) {
        conn.ws.terminate();
        this.conns.delete(conn);
      }
    }
  }

  private sendText(conn: Conn, msg: unknown): void {
    if (!conn.session) return;
    conn.ws.send(conn.session.sealText(JSON.stringify(msg)), { binary: true });
  }

  private onMessage(conn: Conn, raw: Buffer, isBinary: boolean): void {
    try {
      if (!isBinary) {
        // 唯一合法的明文消息:E2EE hello
        if (conn.session) throw new Error("unexpected plaintext after handshake");
        const hello = JSON.parse(raw.toString("utf8")) as HelloMessage;
        if (hello.t !== "hello") throw new Error("expected hello");
        const { ready, session } = new ServerHandshake(this.identityPriv).onHello(hello);
        conn.session = session;
        conn.ws.send(JSON.stringify(ready));
        return;
      }
      if (!conn.session) throw new Error("binary before handshake");
      const opened = conn.session.open(new Uint8Array(raw));

      if (!conn.device) {
        // 认证前只接受 auth
        if (opened.kind !== "text") throw new Error("expected auth");
        const auth = E2eeAuth.parse(JSON.parse(opened.text));
        const device = this.registry.auth(auth.token);
        if (!device) throw new Error("unauthorized");
        conn.device = device;
        this.sendText(conn, { t: "authed", deviceId: device.id });
        this.onAuthenticated?.(device);
        return;
      }

      if (opened.kind === "binary") {
        const frame = decodeFrame(opened.data);
        const attached = frame.type === FRAME_IN ? conn.attached.get(frame.channel) : undefined;
        if (attached) {
          // 会话被其他设备占用时丢弃输入:蒙版之下的硬约束
          if (this.inputGate && !this.inputGate(conn, attached.sessionId)) return;
          this.onInput(frame.channel, frame.data);
        }
        return;
      }
      const req = RpcRequest.parse(JSON.parse(opened.text));
      void this.dispatch(conn, req);
    } catch {
      // 握手违规、解密失败、认证失败:直接断开
      conn.ws.terminate();
      this.conns.delete(conn);
    }
  }

  private async dispatch(conn: Conn, req: RpcRequest): Promise<void> {
    const send = (msg: unknown) => this.sendText(conn, msg);
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

  private sendBinary(conn: Conn, data: Uint8Array): void {
    if (!conn.session || !conn.device) return;
    conn.ws.send(conn.session.sealBinary(data), { binary: true });
  }

  forwardBrowserFrame(channel: number, seq: number, data: Uint8Array): void {
    for (const conn of this.conns) {
      if (conn.browserChannels.has(channel)) {
        this.sendBinary(conn, encodeBrowserFrame(channel, seq, data));
      }
    }
  }

  forwardSimFrame(channel: number, seq: number, data: Uint8Array): void {
    for (const conn of this.conns) {
      if (conn.simChannels.has(channel)) {
        this.sendBinary(conn, encodeSimFrame(channel, seq, data));
      }
    }
  }

  forwardFrame(frame: OutFrame): void {
    for (const conn of this.conns) {
      const st = conn.attached.get(frame.channel);
      if (st && frame.seq > st.attachSeq) {
        this.sendBinary(conn, encodeOutFrame(frame.channel, frame.seq, frame.data));
      }
    }
  }

  broadcastEvent(evt: { seq: number; boot: string; event: string; payload: unknown }): void {
    for (const conn of this.conns) {
      if (conn.device) this.sendText(conn, { t: "evt", ...evt });
    }
  }

  close(): void {
    clearInterval(this.heartbeat);
    for (const conn of this.conns) conn.ws.close();
    this.wss.close();
  }
}
