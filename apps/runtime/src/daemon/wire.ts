// daemon Unix socket 线协议:[u32BE 长度][u8 kind][body]
// kind 0 = JSON 控制消息(信封同 @acro/protocol 的 req/res/evt)
// kind 1 = 终端二进制帧(格式同 @acro/protocol frames)

export const KIND_JSON = 0;
export const KIND_BIN = 1;
export const MAX_WIRE_FRAME_BYTES = 64 * 1024 * 1024;

export function packJson(obj: unknown): Buffer {
  const body = Buffer.from(JSON.stringify(obj), "utf8");
  return pack(KIND_JSON, body);
}

export function packBin(frame: Uint8Array): Buffer {
  return pack(KIND_BIN, Buffer.from(frame.buffer, frame.byteOffset, frame.byteLength));
}

function pack(kind: number, body: Buffer): Buffer {
  if (body.byteLength + 1 > MAX_WIRE_FRAME_BYTES) {
    throw new Error(`wire frame length out of bounds: ${body.byteLength + 1}`);
  }
  const out = Buffer.allocUnsafe(5 + body.byteLength);
  out.writeUInt32BE(1 + body.byteLength, 0);
  out.writeUInt8(kind, 4);
  body.copy(out, 5);
  return out;
}

export interface WireMessage {
  kind: number;
  body: Buffer;
}

export class FrameReader {
  private buffer: Buffer = Buffer.alloc(0);

  reset(): void {
    this.buffer = Buffer.alloc(0);
  }

  push(chunk: Buffer): WireMessage[] {
    this.buffer = this.buffer.length === 0 ? chunk : Buffer.concat([this.buffer, chunk]);
    const messages: WireMessage[] = [];
    while (this.buffer.length >= 4) {
      const len = this.buffer.readUInt32BE(0);
      if (len < 1 || len > MAX_WIRE_FRAME_BYTES) {
        this.reset();
        throw new Error(`wire frame length out of bounds: ${len}`);
      }
      if (this.buffer.length < 4 + len) break;
      messages.push({
        kind: this.buffer.readUInt8(4),
        body: this.buffer.subarray(5, 4 + len),
      });
      this.buffer = this.buffer.subarray(4 + len);
    }
    return messages;
  }
}
