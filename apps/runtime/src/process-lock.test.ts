import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { acquireProcessLock } from "./process-lock.ts";

test("process locks are exclusive until the owning file descriptor closes", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-process-lock-"));
  const file = path.join(directory, "runtime.lock");
  try {
    const release = acquireProcessLock(file, "runtime");
    assert.throws(() => acquireProcessLock(file, "runtime"), /already running/);
    release();
    release();

    const releaseAgain = acquireProcessLock(file, "runtime");
    releaseAgain();
    assert.equal(fs.existsSync(file), true);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
