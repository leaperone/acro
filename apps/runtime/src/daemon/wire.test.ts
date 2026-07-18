import assert from "node:assert/strict";
import test from "node:test";
import { FrameReader, MAX_WIRE_FRAME_BYTES, packJson } from "./wire.ts";

test("frame reader discards a partial frame when the connection resets", () => {
  const reader = new FrameReader();
  const partial = Buffer.alloc(4);
  partial.writeUInt32BE(100, 0);
  assert.deepEqual(reader.push(partial), []);

  reader.reset();
  const frame = packJson({ ok: true });
  const messages = reader.push(frame);
  assert.equal(messages.length, 1);
  assert.deepEqual(JSON.parse(messages[0]!.body.toString("utf8")), { ok: true });
});

test("frame reader rejects invalid lengths before buffering their bodies", () => {
  const reader = new FrameReader();
  const oversized = Buffer.alloc(4);
  oversized.writeUInt32BE(MAX_WIRE_FRAME_BYTES + 1, 0);
  assert.throws(() => reader.push(oversized), /out of bounds/);

  const empty = Buffer.alloc(4);
  assert.throws(() => reader.push(empty), /out of bounds/);
});
