import assert from "node:assert/strict";
import test from "node:test";
import {
  FrameReader,
  MAX_WIRE_FRAME_BYTES,
  MAX_WIRE_FRAME_FRAGMENTS,
  packJson,
} from "./wire.ts";

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

test("frame reader assembles a header split across chunks", () => {
  const reader = new FrameReader();
  const frame = packJson({ ok: true });

  assert.deepEqual(reader.push(frame.subarray(0, 2)), []);
  assert.deepEqual(reader.push(frame.subarray(2, 4)), []);
  const messages = reader.push(frame.subarray(4));

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

test("frame reader assembles a large fragmented frame without rebuilding prior chunks", () => {
  const reader = new FrameReader();
  const payload = "x".repeat(4 * 1024 * 1024);
  const frame = packJson({ payload });
  const messages = [];
  for (let offset = 0; offset < frame.length; offset += 16 * 1024) {
    messages.push(...reader.push(frame.subarray(offset, offset + 16 * 1024)));
  }
  assert.equal(messages.length, 1);
  assert.equal(JSON.parse(messages[0]!.body.toString("utf8")).payload.length, payload.length);
});

test("frame reader rejects an excessive number of fragments for one incomplete frame", () => {
  const reader = new FrameReader();
  const header = Buffer.alloc(4);
  header.writeUInt32BE(MAX_WIRE_FRAME_BYTES, 0);
  reader.push(header);

  for (let i = 1; i < MAX_WIRE_FRAME_FRAGMENTS; i += 1) reader.push(Buffer.from([0]));
  assert.throws(() => reader.push(Buffer.from([0])), /too many fragments/);
});
