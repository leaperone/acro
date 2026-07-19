import assert from "node:assert/strict";
import test from "node:test";
import { ExclusiveRunner } from "./exclusive.ts";

test("exclusive work aborted while queued never starts", async () => {
  const runner = new ExclusiveRunner();
  let release!: () => void;
  const blocker = new Promise<void>((resolve) => {
    release = resolve;
  });
  const first = runner.run("workspace", () => blocker);
  const abort = new AbortController();
  let started = false;
  const queued = runner.run(
    "workspace",
    () => {
      started = true;
    },
    abort.signal,
  );

  abort.abort(new Error("connection closed"));
  release();
  await first;
  await assert.rejects(queued, /connection closed/);
  assert.equal(started, false);
});
