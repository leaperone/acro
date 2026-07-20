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
  pairingAdmissionId,
  RpcRequest,
  ServerHandshake,
} from "@acro/protocol";
import type { DeviceRegistry } from "./devices.ts";

export function removeSurfaceChannels(channels: Map<number, string>, surfaceId: string): number[] {
  const removed: number[] = [];
  for (const [channel, id] of channels) {
    if (id !== surfaceId) continue;
    channels.delete(channel);
    removed.push(channel);
  }
  return removed;
}

export interface Conn {
  ws: WebSocket;
  abortController: AbortController;
  // E2EE 握手完成后建立;认证前只允许 auth 消息
  session: E2eeSession | null;
  device: Device | null;
  // 升级前识别到的授权提示；不是认证凭据，认证后必须与信道内 token 对上。
  admissionId: string | null;
  // channel(=daemon handle) -> 附着状态。attachSeq 之前的输出已包含在快照里。
  attached: Map<number, { sessionId: string; attachSeq: number }>;
  // 已附着的画面 channel -> surface id，用于按连接释放最后一个订阅者。
  browserChannels: Map<number, string>;
  simChannels: Map<number, string>;
  // udid -> 当前 attach RPC 的意图 token；detach/断线可在 channel 产生前取消。
  pendingSimAttaches: Map<string, symbol>;
  inFlightRpc: number;
  // 心跳:上一轮 ping 后是否收到 pong(取自 orca ws-transport 的半开连接回收)
  alive: boolean;
}

// 移动端后台挂起会留下半开 socket,macOS TCP keepalive 默认 2 小时才发现;
// 每轮 ping,下一轮仍未 pong 就 terminate。
const HEARTBEAT_INTERVAL_MS = 15_000;
// 握手 + 认证必须在此时限内完成(取自 orca 的 PRE_AUTH_TIMEOUT)
const PRE_AUTH_TIMEOUT_MS = 10_000;
// 未认证连接也会占用 socket、握手状态和定时器；在升级前拒绝，避免公开入口被耗尽。
export const MAX_WS_CONNECTIONS = 128;
// 旧客户端或随机请求只能占少量兼容席位；已知授权各自有独立握手池。
export const MAX_UNKNOWN_PREAUTH_CONNECTIONS = 8;
export const MAX_PREAUTH_CONNECTIONS_PER_ADMISSION = 16;
// 正常客户端并发很低；预算封在 RPC 入口，避免快照、simctl 和控制队列各自被放大。
export const MAX_IN_FLIGHT_RPC_PER_CONNECTION = 8;
export const MAX_IN_FLIGHT_RPC_TOTAL = 32;
// 布局控制消息上限 256KB,终端输入通常远小于 1MB;更大的单帧只会放大内存攻击面。
const MAX_INBOUND_BYTES = 1024 * 1024;
// 慢客户端不能让 ws 内部发送队列无限增长。画面可以丢帧;终端必须断线后靠快照恢复。
const MAX_BUFFERED_BYTES = 8 * 1024 * 1024;
const SEALED_OVERHEAD_BYTES = 17;

export type WebSocketAdmissionFailure = "total" | "unknown" | "grant" | null;

export function websocketAdmissionFailure(
  conns: Iterable<{ device: Device | null; admissionId: string | null }>,
  admissionId: string | null,
): WebSocketAdmissionFailure {
  let total = 0;
  let matchingPreAuth = 0;
  for (const conn of conns) {
    total += 1;
    if (conn.device) continue;
    if (conn.admissionId === admissionId) matchingPreAuth += 1;
  }
  if (total >= MAX_WS_CONNECTIONS) return "total";
  if (admissionId === null && matchingPreAuth >= MAX_UNKNOWN_PREAUTH_CONNECTIONS) return "unknown";
  if (admissionId !== null && matchingPreAuth >= MAX_PREAUTH_CONNECTIONS_PER_ADMISSION) {
    return "grant";
  }
  return null;
}

export function admissionMatchesToken(admissionId: string | null, token: string): boolean {
  return admissionId === null || pairingAdmissionId(token) === admissionId;
}

export type RpcAdmissionFailure = "connection" | "total" | null;

export function rpcAdmissionFailure(
  connectionInFlight: number,
  totalInFlight: number,
): RpcAdmissionFailure {
  if (connectionInFlight >= MAX_IN_FLIGHT_RPC_PER_CONNECTION) return "connection";
  if (totalInFlight >= MAX_IN_FLIGHT_RPC_TOTAL) return "total";
  return null;
}

export type Handlers = {
  [M in keyof typeof methods]: (
    conn: Conn,
    params: import("zod").infer<(typeof methods)[M]["params"]>,
  ) => Promise<unknown> | unknown;
};

export class Gateway {
  private wss = new WebSocketServer({ noServer: true, maxPayload: MAX_INBOUND_BYTES });
  private conns = new Set<Conn>();
  private inFlightRpc = 0;
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
          this.removeConn(conn);
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
    const requestedAdmissionId = url.searchParams.get("grant");
    const admissionId =
      requestedAdmissionId && this.registry.hasAdmissionId(requestedAdmissionId)
        ? requestedAdmissionId
        : null;
    if (websocketAdmissionFailure(this.conns, admissionId)) {
      socket.write("HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n");
      socket.destroy();
      return;
    }
    this.wss.handleUpgrade(req, socket, head, (ws) => {
      const conn: Conn = {
        ws,
        abortController: new AbortController(),
        session: null,
        device: null,
        admissionId,
        attached: new Map(),
        browserChannels: new Map(),
        simChannels: new Map(),
        pendingSimAttaches: new Map(),
        inFlightRpc: 0,
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
        this.removeConn(conn);
      });
      ws.on("error", () => this.removeConn(conn));
    });
  }

  private removeConn(conn: Conn): void {
    if (!this.conns.delete(conn)) return;
    conn.abortController.abort(new Error("connection closed"));
    if (conn.device) this.onConnClosed?.(conn);
  }

  hasDeviceConnection(deviceId: string): boolean {
    for (const conn of this.conns) {
      if (conn.device?.id === deviceId) return true;
    }
    return false;
  }

  hasDeviceSessionAttachment(deviceId: string, sessionId: string): boolean {
    for (const conn of this.conns) {
      if (conn.device?.id !== deviceId) continue;
      for (const attached of conn.attached.values()) {
        if (attached.sessionId === sessionId) return true;
      }
    }
    return false;
  }

  hasConnection(conn: Conn): boolean {
    return this.conns.has(conn);
  }

  hasBrowserChannel(channel: number): boolean {
    for (const conn of this.conns) {
      if (conn.browserChannels.has(channel)) return true;
    }
    return false;
  }

  hasSimInterest(udid: string): boolean {
    for (const conn of this.conns) {
      if (conn.pendingSimAttaches.has(udid)) return true;
      for (const attachedUdid of conn.simChannels.values()) {
        if (attachedUdid === udid) return true;
      }
    }
    return false;
  }

  dropBrowserChannel(channel: number): void {
    for (const conn of this.conns) conn.browserChannels.delete(channel);
  }

  dropSimChannel(channel: number): void {
    for (const conn of this.conns) conn.simChannels.delete(channel);
  }

  dropSession(sessionId: string): void {
    for (const conn of this.conns) {
      for (const [channel, state] of conn.attached) {
        if (state.sessionId === sessionId) conn.attached.delete(channel);
      }
    }
  }

  // 撤销授权时立即断开该设备的所有活动连接(orca terminateClientConnections)
  terminateDevice(deviceId: string): void {
    for (const conn of this.conns) {
      if (conn.device?.id === deviceId) {
        conn.ws.terminate();
        this.removeConn(conn);
      }
    }
  }

  terminateAll(): void {
    for (const conn of [...this.conns]) {
      conn.ws.terminate();
      this.removeConn(conn);
    }
  }

  private sendText(conn: Conn, msg: unknown): void {
    if (!conn.session) return;
    const text = JSON.stringify(msg);
    if (!this.canSend(conn, Buffer.byteLength(text) + SEALED_OVERHEAD_BYTES, false)) return;
    this.sendSealed(conn, conn.session.sealText(text));
  }

  private canSend(conn: Conn, bytes: number, lossy: boolean): boolean {
    if (conn.ws.readyState !== WebSocket.OPEN) return false;
    // 单个大画面在队列为空时仍允许发送;之后的帧会丢弃,峰值只多这一帧。
    if (conn.ws.bufferedAmount === 0 || conn.ws.bufferedAmount + bytes <= MAX_BUFFERED_BYTES) {
      return true;
    }
    if (!lossy) {
      conn.ws.terminate();
      this.removeConn(conn);
    }
    return false;
  }

  private sendSealed(conn: Conn, data: Uint8Array): void {
    try {
      conn.ws.send(data, { binary: true }, (error) => {
        if (!error) return;
        conn.ws.terminate();
        this.removeConn(conn);
      });
    } catch {
      conn.ws.terminate();
      this.removeConn(conn);
    }
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
        if (!admissionMatchesToken(conn.admissionId, auth.token)) throw new Error("unauthorized");
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
      this.removeConn(conn);
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
    if (rpcAdmissionFailure(conn.inFlightRpc, this.inFlightRpc)) {
      send({
        t: "res",
        id: req.id,
        ok: false,
        error: { code: "busy", message: "too many concurrent RPC requests" },
      });
      return;
    }
    conn.inFlightRpc += 1;
    this.inFlightRpc += 1;
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
    } finally {
      conn.inFlightRpc -= 1;
      this.inFlightRpc -= 1;
    }
  }

  private sendBinary(conn: Conn, data: Uint8Array, lossy = false): void {
    if (!conn.session || !conn.device) return;
    if (!this.canSend(conn, data.byteLength + SEALED_OVERHEAD_BYTES, lossy)) return;
    this.sendSealed(conn, conn.session.sealBinary(data));
  }

  forwardBrowserFrame(channel: number, seq: number, data: Uint8Array): void {
    let encoded: Uint8Array | null = null;
    for (const conn of this.conns) {
      if (conn.browserChannels.has(channel)) {
        encoded ??= encodeBrowserFrame(channel, seq, data);
        this.sendBinary(conn, encoded, true);
      }
    }
  }

  forwardSimFrame(channel: number, seq: number, data: Uint8Array): void {
    let encoded: Uint8Array | null = null;
    for (const conn of this.conns) {
      if (conn.simChannels.has(channel)) {
        encoded ??= encodeSimFrame(channel, seq, data);
        this.sendBinary(conn, encoded, true);
      }
    }
  }

  forwardFrame(frame: OutFrame): void {
    let encoded: Uint8Array | null = null;
    for (const conn of this.conns) {
      const st = conn.attached.get(frame.channel);
      if (st && frame.seq > st.attachSeq) {
        encoded ??= encodeOutFrame(frame.channel, frame.seq, frame.data);
        this.sendBinary(conn, encoded);
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
    this.terminateAll();
    this.wss.close();
  }
}
