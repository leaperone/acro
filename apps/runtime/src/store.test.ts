import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { writeJsonAtomic } from "./store.ts";

test("atomic state files are private even when replacing a permissive temp file", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-private-file-"));
  const file = path.join(directory, "state.json");
  const tmp = path.join(directory, ".state.json.tmp");
  try {
    fs.writeFileSync(tmp, "stale", { mode: 0o644 });
    writeJsonAtomic(file, { ok: true });
    assert.equal(fs.statSync(file).mode & 0o777, 0o600);
    assert.deepEqual(JSON.parse(fs.readFileSync(file, "utf8")), { ok: true });
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
