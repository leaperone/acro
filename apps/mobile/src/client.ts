import type { MethodName, MethodParams, MethodResult } from "@acro/protocol";
import {
  b64ToBytes,
  ClientHandshake,
  decodeFrame,
  decodePairingOffer,
  type E2eeSession,
  type Frame,
} from "@acro/protocol";

// 一个远程 Runtime = 一个 token + 多个入口(LAN 直连、FRP 公网等)。
// 从哪个入口连上都是同一身份、同一批会话。
export interface ServerConfig {
  name: string;
  deviceId: string;
  token: string;
  pub: string; // 服务端静态公钥,base64
  endpoints: string[]; // host:port,按序尝试
}

const CONNECT_TIMEOUT_MS = 4000;
const RETRY_DELAY_MS = 1500;

type PendingEntry = { resolve: (v: unknown) => void; reject: (e: Error) => void };

interface Channel {
  ws: WebSocket;
  session: E2eeSession;
  deviceId: string;
}

// 单个入口:WS 连接 + E2EE 握手 + 信道内认证
function connectEndpoint(endpoint: string, config: ServerConfig): Promise<Channel> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://${endpoint}/ws`);
    ws.binaryType = "arraybuffer";
    const handshake = new ClientHandshake(b64ToBytes(config.pub));
    let session: E2eeSession | null = null;
    let settled = false;
    const fail = (err: Error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      ws.close();
      reject(err);
    };
    const timer = setTimeout(() => fail(new Error(`连接超时: ${endpoint}`)), CONNECT_TIMEOUT_MS);
    ws.onerror = () => fail(new Error(`连接失败: ${endpoint}`));
    ws.onclose = () => fail(new Error(`连接被关闭: ${endpoint}`));
    ws.onopen = () => ws.send(JSON.stringify(handshake.helloMessage()));
    ws.onmessage = (ev: MessageEvent) => {
      try {
        if (!session) {
          if (ev.data instanceof ArrayBuffer) throw new Error("handshake violation");
          session = handshake.onReady(JSON.parse(String(ev.data)));
          ws.send(session.sealText(JSON.stringify({ t: "auth", token: config.token })).buffer as ArrayBuffer);
          return;
        }
        if (!(ev.data instanceof ArrayBuffer)) throw new Error("expected sealed message");
        const opened = session.open(new Uint8Array(ev.data));
        if (opened.kind !== "text") throw new Error("expected authed");
        const msg = JSON.parse(opened.text) as { t: string; deviceId: string };
        if (msg.t !== "authed") throw new Error("expected authed");
        settled = true;
        clearTimeout(timer);
        ws.onerror = null;
        ws.onclose = null;
        ws.onmessage = null;
        resolve({ ws, session, deviceId: msg.deviceId });
      } catch (err) {
        fail(err as Error);
      }
    };
  });
}

// 配对:解析配对码 → 连一次确认有效 → 返回可存储的配置
export async function pairWithOffer(raw: string, name: string): Promise<ServerConfig> {
  const offer = decodePairingOffer(raw);
  const config: ServerConfig = {
    name,
    deviceId: "",
    token: offer.token,
    pub: offer.pub,
    endpoints: offer.endpoints,
  };
  let lastErr: Error = new Error("no endpoints");
  for (const endpoint of offer.endpoints) {
    try {
      const channel = await connectEndpoint(endpoint, config);
      channel.ws.close();
      return { ...config, deviceId: channel.deviceId };
    } catch (err) {
      lastErr = err as Error;
    }
  }
  throw new Error(`所有入口均连接失败: ${lastErr.message}`);
}

// 单条 WS:E2EE 信道内 JSON 控制消息 + 二进制帧,断线自动重连(轮询所有入口)。
export class MobileClient {
  private ws: WebSocket | null = null;
  private session: E2eeSession | null = null;
  private config: ServerConfig;
  private nextId = 1;
  private pending = new Map<number, PendingEntry>();
  private closed = false;
  onFrame: ((frame: Frame) => void) | null = null;
  onEvent: ((event: string, payload: unknown) => void) | null = null;
  onStateChange: ((connected: boolean) => void) | null = null;

  constructor(config: ServerConfig) {
    this.config = config;
  }

  async connect(): Promise<void> {
    let lastErr: Error = new Error("no endpoints");
    for (const endpoint of this.config.endpoints) {
      if (this.closed) return;
      try {
        const channel = await connectEndpoint(endpoint, this.config);
        this.attach(channel);
        return;
      } catch (err) {
        lastErr = err as Error;
      }
    }
    if (!this.closed) {
      setTimeout(() => void this.connect().catch(() => {}), RETRY_DELAY_MS);
    }
    throw lastErr;
  }

  private attach(channel: Channel): void {
    this.ws = channel.ws;
    this.session = channel.session;
    this.onStateChange?.(true);
    channel.ws.onclose = () => {
      this.ws = null;
      this.session = null;
      for (const p of this.pending.values()) p.reject(new Error("连接断开"));
      this.pending.clear();
      this.onStateChange?.(false);
      if (!this.closed) setTimeout(() => void this.connect().catch(() => {}), RETRY_DELAY_MS);
    };
    channel.ws.onmessage = (ev: MessageEvent) => {
      const session = this.session;
      if (!session || !(ev.data instanceof ArrayBuffer)) return;
      let opened;
      try {
        opened = session.open(new Uint8Array(ev.data));
      } catch {
        // 解密失败说明信道状态不同步,断开走重连
        channel.ws.close();
        return;
      }
      if (opened.kind === "binary") {
        this.onFrame?.(decodeFrame(opened.data));
        return;
      }
      const msg = JSON.parse(opened.text);
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
  }

  rpc<M extends MethodName>(method: M, params: MethodParams<M>): Promise<MethodResult<M>> {
    const ws = this.ws;
    const session = this.session;
    if (!ws || !session) return Promise.reject(new Error("未连接"));
    const id = this.nextId++;
    ws.send(session.sealText(JSON.stringify({ t: "req", id, method, params })).buffer as ArrayBuffer);
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (v: unknown) => void, reject });
      setTimeout(() => {
        if (this.pending.delete(id)) reject(new Error(`超时: ${method}`));
      }, 20000);
    });
  }

  sendBinary(data: Uint8Array): void {
    if (!this.ws || !this.session) return;
    this.ws.send(this.session.sealBinary(data).buffer as ArrayBuffer);
  }

  get connected(): boolean {
    return this.ws !== null;
  }

  close(): void {
    this.closed = true;
    this.ws?.close();
  }
}
