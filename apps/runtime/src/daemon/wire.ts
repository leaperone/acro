// daemon Unix socket 线协议:[u32BE 长度][u8 kind][body]
// kind 0 = JSON 控制消息(信封同 @acro/protocol 的 req/res/evt)
// kind 1 = 终端二进制帧(格式同 @acro/protocol frames)

export const KIND_JSON = 0;
export const KIND_BIN = 1;
export const MAX_WIRE_FRAME_BYTES = 64 * 1024 * 1024;
export const MAX_WIRE_FRAME_FRAGMENTS = 8192;

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
  private chunks: Buffer[] = [];
  private chunkIndex = 0;
  private chunkOffset = 0;
  private bufferedBytes = 0;

  reset(): void {
    this.chunks = [];
    this.chunkIndex = 0;
    this.chunkOffset = 0;
    this.bufferedBytes = 0;
  }

  push(chunk: Buffer): WireMessage[] {
    if (chunk.length > 0) {
      this.chunks.push(chunk);
      this.bufferedBytes += chunk.length;
    }
    const messages: WireMessage[] = [];
    while (this.bufferedBytes >= 4) {
      const len = this.peek(4).readUInt32BE(0);
      if (len < 1 || len > MAX_WIRE_FRAME_BYTES) {
        this.reset();
        throw new Error(`wire frame length out of bounds: ${len}`);
      }
      if (this.bufferedBytes < 4 + len) break;
      this.advance(4);
      const frame = this.take(len);
      messages.push({
        kind: frame.readUInt8(0),
        body: frame.subarray(1),
      });
    }
    if (this.bufferedBytes > 0 && this.chunks.length - this.chunkIndex > MAX_WIRE_FRAME_FRAGMENTS) {
      this.reset();
      throw new Error("wire frame has too many fragments");
    }
    return messages;
  }

  private peek(length: number): Buffer {
    const first = this.chunks[this.chunkIndex]!;
    if (first.length - this.chunkOffset >= length) {
      return first.subarray(this.chunkOffset, this.chunkOffset + length);
    }
    const out = Buffer.allocUnsafe(length);
    let index = this.chunkIndex;
    let offset = this.chunkOffset;
    let written = 0;
    while (written < length) {
      const source = this.chunks[index]!;
      const count = Math.min(length - written, source.length - offset);
      source.copy(out, written, offset, offset + count);
      written += count;
      index += 1;
      offset = 0;
    }
    return out;
  }

  private take(length: number): Buffer {
    const first = this.chunks[this.chunkIndex]!;
    if (first.length - this.chunkOffset >= length) {
      const out = first.subarray(this.chunkOffset, this.chunkOffset + length);
      this.advance(length);
      return out;
    }
    const out = Buffer.allocUnsafe(length);
    let written = 0;
    while (written < length) {
      const source = this.chunks[this.chunkIndex]!;
      const count = Math.min(length - written, source.length - this.chunkOffset);
      source.copy(out, written, this.chunkOffset, this.chunkOffset + count);
      written += count;
      this.advance(count);
    }
    return out;
  }

  private advance(length: number): void {
    let remaining = length;
    this.bufferedBytes -= length;
    while (remaining > 0) {
      const chunk = this.chunks[this.chunkIndex]!;
      const count = Math.min(remaining, chunk.length - this.chunkOffset);
      this.chunkOffset += count;
      remaining -= count;
      if (this.chunkOffset === chunk.length) {
        this.chunkIndex += 1;
        this.chunkOffset = 0;
      }
    }
    if (this.chunkIndex === this.chunks.length) {
      this.chunks = [];
      this.chunkIndex = 0;
    } else if (this.chunkIndex >= 1024 && this.chunkIndex * 2 >= this.chunks.length) {
      this.chunks = this.chunks.slice(this.chunkIndex);
      this.chunkIndex = 0;
    }
  }
}
