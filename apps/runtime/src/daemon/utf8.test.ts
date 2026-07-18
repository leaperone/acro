import assert from "node:assert/strict";
import test from "node:test";
import { utf8SafeCut } from "./utf8.ts";

test("keeps complete ascii and multibyte sequences whole", () => {
  assert.equal(utf8SafeCut(Buffer.from("abc", "utf8")), 3);
  assert.equal(utf8SafeCut(Buffer.from("你好", "utf8")), 6); // 2 * 3 bytes
  assert.equal(utf8SafeCut(Buffer.from("a你🎉", "utf8")), 1 + 3 + 4);
  assert.equal(utf8SafeCut(Buffer.alloc(0)), 0);
});

test("cuts before a truncated trailing sequence", () => {
  const ni = Buffer.from("你", "utf8"); // e4 bd a0
  assert.equal(utf8SafeCut(ni.subarray(0, 1)), 0); // lead byte only
  assert.equal(utf8SafeCut(ni.subarray(0, 2)), 0); // lead + 1 continuation
  const emoji = Buffer.from("🎉", "utf8"); // f0 9f 8e 89
  assert.equal(utf8SafeCut(emoji.subarray(0, 3)), 0); // 3 of 4 bytes
  // 完整字符后跟半个:切在完整字符之后
  assert.equal(utf8SafeCut(Buffer.concat([Buffer.from("好"), emoji.subarray(0, 2)])), 3);
});

test("reassembles a character split across two frames", () => {
  const hello = Buffer.from("你好世界", "utf8"); // 12 bytes
  // 在第 4 字节处切开(把第 2 个字符 好 劈成两半)
  const a = hello.subarray(0, 4);
  const b = hello.subarray(4);
  const cutA = utf8SafeCut(a);
  assert.equal(cutA, 3); // 只交出完整的 你
  const tail = a.subarray(cutA); // 好 的第 1 字节
  const merged = Buffer.concat([tail, b]);
  assert.equal(utf8SafeCut(merged), merged.byteLength); // 拼回后完整
  assert.equal(
    Buffer.concat([a.subarray(0, cutA), merged.subarray(0, utf8SafeCut(merged))]).toString("utf8"),
    "你好世界",
  );
});
