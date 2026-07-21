import { test } from "node:test";
import assert from "node:assert/strict";
import nodeFs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { list, read, search } from "./fs.ts";

async function tmpDir(): Promise<string> {
  return nodeFs.mkdtemp(path.join(os.tmpdir(), "acro-fs-test-"));
}

test("list sorts directories first then case-insensitive by name", async () => {
  const dir = await tmpDir();
  await nodeFs.writeFile(path.join(dir, "zeta.txt"), "z");
  await nodeFs.writeFile(path.join(dir, "Alpha.txt"), "a");
  await nodeFs.mkdir(path.join(dir, "src"));
  await nodeFs.mkdir(path.join(dir, "Docs"));

  const entries = await list(dir);
  assert.deepEqual(
    entries.map((e) => e.name),
    ["Docs", "src", "Alpha.txt", "zeta.txt"],
  );
  assert.equal(entries[0]!.kind, "dir");
  assert.equal(entries[2]!.kind, "file");
  assert.equal(entries[2]!.path, path.join(dir, "Alpha.txt"));
});

test("read returns utf-8 text for a small text file", async () => {
  const dir = await tmpDir();
  const file = path.join(dir, "hello.ts");
  await nodeFs.writeFile(file, "const x = 1;\n");
  const content = await read(file);
  assert.equal(content.kind, "text");
  assert.equal(content.text, "const x = 1;\n");
  assert.equal(content.truncated, false);
  assert.equal(content.base64, null);
});

test("read truncates text past the maxBytes limit and flags truncated", async () => {
  const dir = await tmpDir();
  const file = path.join(dir, "big.txt");
  await nodeFs.writeFile(file, "a".repeat(1000));
  const content = await read(file, 100);
  assert.equal(content.kind, "text");
  assert.equal(content.truncated, true);
  assert.equal(content.text!.length, 100);
  assert.equal(content.size, 1000);
});

test("read classifies files with NUL bytes as binary", async () => {
  const dir = await tmpDir();
  const file = path.join(dir, "blob.bin");
  await nodeFs.writeFile(file, Buffer.from([0x41, 0x00, 0x42, 0x00]));
  const content = await read(file);
  assert.equal(content.kind, "binary");
  assert.equal(content.text, null);
  assert.equal(content.base64, null);
});

test("read returns base64 image for a known image extension", async () => {
  const dir = await tmpDir();
  const file = path.join(dir, "pixel.png");
  const bytes = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  await nodeFs.writeFile(file, bytes);
  const content = await read(file);
  assert.equal(content.kind, "image");
  assert.equal(content.mime, "image/png");
  assert.equal(content.base64, bytes.toString("base64"));
});

test("search finds matching lines with path/line/preview", async () => {
  const dir = await tmpDir();
  await nodeFs.writeFile(path.join(dir, "a.ts"), "const needle = 1;\nother line\n");
  await nodeFs.writeFile(path.join(dir, "b.ts"), "no match here\n");
  const hits = await search(dir, "needle");
  assert.equal(hits.length, 1);
  assert.equal(hits[0]!.path, path.join(dir, "a.ts"));
  assert.equal(hits[0]!.line, 1);
  assert.match(hits[0]!.preview, /needle/);
});

test("search returns empty for no matches", async () => {
  const dir = await tmpDir();
  await nodeFs.writeFile(path.join(dir, "a.ts"), "hello world\n");
  const hits = await search(dir, "zzz-nonexistent-token");
  assert.deepEqual(hits, []);
});
