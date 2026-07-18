import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { ServerIdentity } from "./share.ts";

test("server identity is created once and corruption never rotates it", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-server-identity-"));
  const file = path.join(directory, "server-key.json");
  try {
    const first = new ServerIdentity(file);
    assert.deepEqual(new ServerIdentity(file).pub, first.pub);

    fs.writeFileSync(file, "null");
    assert.throws(() => new ServerIdentity(file), /invalid server identity/);
    assert.equal(fs.readFileSync(file, "utf8"), "null");
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
