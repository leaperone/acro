import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import WebSocket from "ws";
import type { MethodName, MethodParams, MethodResult } from "@acro/protocol";
import { decodeFrame, type Frame } from "@acro/protocol/frames";
// e2ee 不引 zod:attach 冷启动路径保持轻量
import { b64ToBytes, ClientHandshake, type E2eeSession } from "@acro/protocol/e2ee";

const configFile =
  process.env.ACRO_CLIENT_CONFIG ?? path.join(os.homedir(), ".acro", "client.json");

// 一个远程 Runtime = 一个 token + 多个入口(LAN 直连、FRP 公网等)。
// 从哪个入口连上都是同一身份、同一批会话——服务端不区分连接来源。
export interface ServerEntry {
  name: string;
  deviceId: string;
  token: string;
  pub: string; // 服务端静态公钥,base64
  endpoints: string[]; // host:port,按序尝试
}

export interface ClientConfig {
  v: 2;
  servers: ServerEntry[];
  active: string | null; // deviceId
}

export function loadClientConfig(): ClientConfig {
  try {
    const parsed = JSON.parse(fs.readFileSync(configFile, "utf8")) as ClientConfig;
    if (parsed.v === 2 && Array.isArray(parsed.servers)) return parsed;
  } catch {
    // 未配对或旧版格式
  }
  console.error("尚未配对;先运行: acro pair <配对码>");
  process.exit(1);
}

export function saveClientConfig(config: ClientConfig): void {
  fs.mkdirSync(path.dirname(configFile), { recursive: true });
  fs.writeFileSync(configFile, JSON.stringify(config, null, 2), { mode: 0o600 });
}

export function activeServer(config: ClientConfig): ServerEntry {
  const server =
    config.servers.find((s) => s.deviceId === config.active) ?? config.servers[0];
  if (!server) {
    console.error("没有已配对的服务器;先运行: acro pair <配对码>");
    process.exit(1);
  }
  return server;
}

const CONNECT_TIMEOUT_MS = 4000;

interface Channel {
  ws: WebSocket;
  session: E2eeSession;
  deviceId: string;
}

// 单个入口:WS 连接 + E2EE 握手 + 信道内认证
function connectEndpoint(endpoint: string, server: ServerEntry): Promise<Channel> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://${endpoint}/ws`);
    const handshake = new ClientHandshake(b64ToBytes(server.pub));
    let session: E2eeSession | null = null;
    const timer = setTimeout(() => {
      ws.terminate();
      reject(new Error(`连接超时: ${endpoint}`));
    }, CONNECT_TIMEOUT_MS);
    const fail = (err: Error) => {
      clearTimeout(timer);
      ws.terminate();
      reject(err);
    };
    ws.on("error", fail);
    ws.on("close", () => fail(new Error(`连接被关闭: ${endpoint}`)));
    ws.on("open", () => ws.send(JSON.stringify(handshake.helloMessage())));
    ws.on("message", (raw: Buffer, isBinary: boolean) => {
      try {
        if (!session) {
          if (isBinary) throw new Error("handshake violation");
          session = handshake.onReady(JSON.parse(raw.toString("utf8")));
          ws.send(session.sealText(JSON.stringify({ t: "auth", token: server.token })));
          return;
        }
        const opened = session.open(new Uint8Array(raw));
        if (opened.kind !== "text") throw new Error("expected authed");
        const msg = JSON.parse(opened.text) as { t: string; deviceId: string };
        if (msg.t !== "authed") throw new Error("expected authed");
        clearTimeout(timer);
        ws.removeAllListeners();
        resolve({ ws, session, deviceId: msg.deviceId });
      } catch (err) {
        fail(err as Error);
      }
    });
  });
}

export class AcroClient {
  readonly deviceId: string;
  private ws: WebSocket;
  private session: E2eeSession;
  private nextId = 1;
  private pending = new Map<
    number,
    { resolve: (v: any) => void; reject: (e: Error) => void; timer: NodeJS.Timeout }
  >();
  onFrame: ((frame: Frame) => void) | null = null;
  onEvent: ((event: string, payload: unknown) => void) | null = null;

  private constructor(channel: Channel) {
    this.ws = channel.ws;
    this.session = channel.session;
    this.deviceId = channel.deviceId;
  }

  // 按序尝试所有入口(在家走 LAN,出门走 FRP),第一个成功的胜出
  static async connect(server: ServerEntry): Promise<AcroClient> {
    let lastErr: Error = new Error("no endpoints");
    for (const endpoint of server.endpoints) {
      try {
        const channel = await connectEndpoint(endpoint, server);
        const client = new AcroClient(channel);
        client.listen();
        return client;
      } catch (err) {
        lastErr = err as Error;
      }
    }
    throw new Error(`所有入口均连接失败 (${server.endpoints.join(", ")}): ${lastErr.message}`);
  }

  private listen(): void {
    this.ws.on("message", (raw: Buffer) => {
      let opened;
      try {
        opened = this.session.open(new Uint8Array(raw));
      } catch {
        this.ws.terminate();
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
        clearTimeout(p.timer);
        if (msg.ok) p.resolve(msg.result);
        else p.reject(new Error(`${msg.error.code}: ${msg.error.message}`));
      } else if (msg.t === "evt") {
        this.onEvent?.(msg.event, msg.payload);
      }
    });
  }

  rpc<M extends MethodName>(method: M, params: MethodParams<M>): Promise<MethodResult<M>> {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        if (this.pending.delete(id)) reject(new Error(`rpc timeout: ${method}`));
      }, 30000);
      this.pending.set(id, { resolve, reject, timer });
      this.ws.send(this.session.sealText(JSON.stringify({ t: "req", id, method, params })));
    });
  }

  sendBinary(data: Uint8Array): void {
    this.ws.send(this.session.sealBinary(data), { binary: true });
  }

  close(): void {
    this.ws.close();
  }
}
