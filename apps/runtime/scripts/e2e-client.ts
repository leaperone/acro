import WebSocket from "ws";
import {
  b64ToBytes,
  ClientHandshake,
  decodeFrame,
  type E2eeSession,
  encodeInFrame,
  type Frame,
  FRAME_OUT,
  type PairingOffer,
} from "@acro/protocol";

interface Pending {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
}

export class E2eClient {
  private ws!: WebSocket;
  private session!: E2eeSession;
  private nextId = 1;
  private pending = new Map<number, Pending>();
  deviceId = "";
  output = "";
  events: Array<{ event: string; payload: any }> = [];
  frames: Frame[] = [];

  async connect(offer: PairingOffer, token = offer.token): Promise<void> {
    const endpoint =
      offer.endpoints.find((value) => value.startsWith("127.0.0.1:")) ?? offer.endpoints[0]!;
    this.ws = new WebSocket(`ws://${endpoint}/ws`);
    const handshake = new ClientHandshake(b64ToBytes(offer.pub));
    await new Promise<void>((resolve, reject) => {
      let settled = false;
      const finish = (error?: Error) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (error) {
          this.ws.terminate();
          reject(error);
        } else {
          resolve();
        }
      };
      const timer = setTimeout(() => finish(new Error("handshake timeout")), 8000);
      this.ws.on("open", () => this.ws.send(JSON.stringify(handshake.helloMessage())));
      this.ws.on("error", (error) => finish(error));
      this.ws.on("close", () => finish(new Error("closed during handshake")));
      this.ws.once("message", (raw: Buffer) => {
        try {
          this.session = handshake.onReady(JSON.parse(raw.toString("utf8")));
          this.ws.send(this.session.sealText(JSON.stringify({ t: "auth", token })));
          this.ws.once("message", (authRaw: Buffer) => {
            try {
              const opened = this.session.open(new Uint8Array(authRaw));
              if (opened.kind !== "text") throw new Error("expected authed");
              const msg = JSON.parse(opened.text);
              if (msg.t !== "authed") throw new Error(`unexpected: ${opened.text}`);
              this.deviceId = msg.deviceId;
              this.ws.removeAllListeners();
              this.listen();
              finish();
            } catch (error) {
              finish(error as Error);
            }
          });
        } catch (error) {
          finish(error as Error);
        }
      });
    });
  }

  private listen(): void {
    const fail = () => {
      for (const pending of this.pending.values()) {
        clearTimeout(pending.timer);
        pending.reject(new Error("connection closed"));
      }
      this.pending.clear();
    };
    this.ws.on("close", fail);
    this.ws.on("error", fail);
    this.ws.on("message", (raw: Buffer) => {
      const opened = this.session.open(new Uint8Array(raw));
      if (opened.kind === "binary") {
        const frame = decodeFrame(opened.data);
        if (frame.type === FRAME_OUT) {
          this.output += Buffer.from(frame.data).toString("utf8");
        } else {
          this.frames.push(frame);
          if (this.frames.length > 100) this.frames.shift();
        }
        return;
      }
      const msg = JSON.parse(opened.text);
      if (msg.t === "res") {
        const pending = this.pending.get(msg.id);
        if (!pending) return;
        this.pending.delete(msg.id);
        clearTimeout(pending.timer);
        if (msg.ok) pending.resolve(msg.result);
        else pending.reject(new Error(`${msg.error.code}: ${msg.error.message}`));
      } else if (msg.t === "evt") {
        this.events.push({ event: msg.event, payload: msg.payload });
      }
    });
  }

  rpc<T = any>(method: string, params: unknown = {}, timeoutMs = 10000): Promise<T> {
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        if (this.pending.delete(id)) reject(new Error(`rpc timeout: ${method}`));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: resolve as (value: unknown) => void,
        reject,
        timer,
      });
      try {
        this.ws.send(
          this.session.sealText(JSON.stringify({ t: "req", id, method, params })),
          (error) => {
            if (!error) return;
            const pending = this.pending.get(id);
            if (!pending) return;
            this.pending.delete(id);
            clearTimeout(pending.timer);
            reject(error);
          },
        );
      } catch (error) {
        this.pending.delete(id);
        clearTimeout(timer);
        reject(error as Error);
      }
    });
  }

  sendInput(channel: number, text: string): void {
    this.ws.send(this.session.sealBinary(encodeInFrame(channel, Buffer.from(text, "utf8"))), {
      binary: true,
    });
  }

  async waitOutput(needle: string, timeoutMs = 8000): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (this.output.includes(needle)) return;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    throw new Error(
      `output did not contain ${JSON.stringify(needle)}; got: ${JSON.stringify(this.output.slice(-500))}`,
    );
  }

  async waitFrame<T extends Frame["type"]>(
    type: T,
    timeoutMs = 15000,
  ): Promise<Extract<Frame, { type: T }>> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const frame = this.frames.find((candidate) => candidate.type === type);
      if (frame) return frame as Extract<Frame, { type: T }>;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    throw new Error(`frame type ${type} not received`);
  }

  waitClosed(): Promise<void> {
    if (this.ws.readyState === WebSocket.CLOSED) return Promise.resolve();
    return new Promise((resolve) => this.ws.once("close", () => resolve()));
  }

  close(): void {
    this.ws.close();
  }
}
