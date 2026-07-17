import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import WebSocket from "ws";
import type { MethodName, MethodParams, MethodResult } from "@acro/protocol";
import { decodeFrame, type Frame } from "@acro/protocol";

const configFile =
  process.env.ACRO_CLIENT_CONFIG ?? path.join(os.homedir(), ".acro", "client.json");

export interface ClientConfig {
  host: string; // host:port
  token: string;
  deviceId: string;
}

export function loadClientConfig(): ClientConfig {
  try {
    return JSON.parse(fs.readFileSync(configFile, "utf8")) as ClientConfig;
  } catch {
    console.error("not paired yet; run: acro pair <host:port>");
    process.exit(1);
  }
}

export function saveClientConfig(config: ClientConfig): void {
  fs.mkdirSync(path.dirname(configFile), { recursive: true });
  fs.writeFileSync(configFile, JSON.stringify(config, null, 2), { mode: 0o600 });
}

export class AcroClient {
  private ws: WebSocket;
  private nextId = 1;
  private pending = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
  onFrame: ((frame: Frame) => void) | null = null;
  onEvent: ((event: string, payload: unknown) => void) | null = null;

  private constructor(ws: WebSocket) {
    this.ws = ws;
  }

  static async connect(config: ClientConfig): Promise<AcroClient> {
    const ws = new WebSocket(`ws://${config.host}/ws?token=${config.token}`);
    await new Promise<void>((resolve, reject) => {
      ws.on("open", () => resolve());
      ws.on("error", reject);
    });
    const client = new AcroClient(ws);
    ws.on("message", (raw: Buffer, isBinary: boolean) => {
      if (isBinary) {
        client.onFrame?.(decodeFrame(raw));
        return;
      }
      const msg = JSON.parse(raw.toString("utf8"));
      if (msg.t === "res") {
        const p = client.pending.get(msg.id);
        if (!p) return;
        client.pending.delete(msg.id);
        if (msg.ok) p.resolve(msg.result);
        else p.reject(new Error(`${msg.error.code}: ${msg.error.message}`));
      } else if (msg.t === "evt") {
        client.onEvent?.(msg.event, msg.payload);
      }
    });
    return client;
  }

  rpc<M extends MethodName>(method: M, params: MethodParams<M>): Promise<MethodResult<M>> {
    const id = this.nextId++;
    this.ws.send(JSON.stringify({ t: "req", id, method, params }));
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      setTimeout(() => {
        if (this.pending.delete(id)) reject(new Error(`rpc timeout: ${method}`));
      }, 30000);
    });
  }

  sendBinary(data: Uint8Array): void {
    this.ws.send(data, { binary: true });
  }

  close(): void {
    this.ws.close();
  }
}
