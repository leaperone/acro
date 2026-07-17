// 终端数据走二进制帧,不进 JSON。WS 上直接发这个格式;
// daemon Unix socket 上外面再包一层 [u32 长度] 前缀(见 runtime)。
//
// OUT (服务端→客户端): u8 0x01 | u32 channel | u32 seq | payload
// IN  (客户端→服务端): u8 0x02 | u32 channel | payload
//
// channel 是 session.attach 返回的连接内编号;seq 是会话输出的单调序号,
// 用于断线重连时和快照对齐。

export const FRAME_OUT = 0x01;
export const FRAME_IN = 0x02;

export interface OutFrame {
  type: typeof FRAME_OUT;
  channel: number;
  seq: number;
  data: Uint8Array;
}

export interface InFrame {
  type: typeof FRAME_IN;
  channel: number;
  data: Uint8Array;
}

export type Frame = OutFrame | InFrame;

export function encodeOutFrame(channel: number, seq: number, data: Uint8Array): Uint8Array {
  const buf = new Uint8Array(9 + data.byteLength);
  const view = new DataView(buf.buffer);
  view.setUint8(0, FRAME_OUT);
  view.setUint32(1, channel);
  view.setUint32(5, seq);
  buf.set(data, 9);
  return buf;
}

export function encodeInFrame(channel: number, data: Uint8Array): Uint8Array {
  const buf = new Uint8Array(5 + data.byteLength);
  const view = new DataView(buf.buffer);
  view.setUint8(0, FRAME_IN);
  view.setUint32(1, channel);
  buf.set(data, 5);
  return buf;
}

export function decodeFrame(raw: Uint8Array): Frame {
  const view = new DataView(raw.buffer, raw.byteOffset, raw.byteLength);
  const type = view.getUint8(0);
  if (type === FRAME_OUT) {
    if (raw.byteLength < 9) throw new Error("out frame too short");
    return {
      type: FRAME_OUT,
      channel: view.getUint32(1),
      seq: view.getUint32(5),
      data: raw.subarray(9),
    };
  }
  if (type === FRAME_IN) {
    if (raw.byteLength < 5) throw new Error("in frame too short");
    return { type: FRAME_IN, channel: view.getUint32(1), data: raw.subarray(5) };
  }
  throw new Error(`unknown frame type ${type}`);
}
