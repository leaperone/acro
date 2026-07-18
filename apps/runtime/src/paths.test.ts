import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { ensurePrivateDirectory } from "./paths.ts";

test("private directories repair existing permissive modes", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-private-dir-"));
  try {
    fs.chmodSync(directory, 0o755);
    ensurePrivateDirectory(directory);
    assert.equal(fs.statSync(directory).mode & 0o777, 0o700);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
