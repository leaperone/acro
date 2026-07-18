import assert from "node:assert/strict";
import test from "node:test";
import type { Session } from "@acro/protocol";
import { AcroClient, resolveSessionRef } from "./client.ts";

function session(id: string): Session {
  return {
    id,
    cwd: "/tmp",
    command: "zsh",
    cols: 80,
    rows: 24,
    createdAt: "2026-01-01T00:00:00.000Z",
    alive: true,
    exitCode: null,
    title: null,
  };
}

test("resolveSessionRef requires a unique prefix", () => {
  const first = session("abcdef01-0000-0000-0000-000000000000");
  const second = session("abcdef02-0000-0000-0000-000000000000");
  assert.equal(resolveSessionRef([first, second], first.id), first);
  assert.equal(resolveSessionRef([first, second], "abcdef01"), first);
  assert.throws(() => resolveSessionRef([first, second], "abcdef"), /ambiguous session id/);
  assert.throws(() => resolveSessionRef([first, second], "missing"), /session not found/);
});

test("AcroClient exposes websocket flow control", async () => {
  let bufferedAmount = 2 * 1024 * 1024;
  let paused = 0;
  let resumed = 0;
  const client = Object.create(AcroClient.prototype) as AcroClient;
  Object.assign(client, {
    ws: {
      readyState: 1,
      get bufferedAmount() {
        return bufferedAmount;
      },
      send() {},
      pause() {
        paused += 1;
      },
      resume() {
        resumed += 1;
      },
    },
    session: { sealBinary: (data: Uint8Array) => data },
  });

  assert.equal(client.sendBinary(new Uint8Array([1])), bufferedAmount);
  client.pauseIncoming();
  client.resumeIncoming();
  assert.equal(paused, 1);
  assert.equal(resumed, 1);

  setTimeout(() => {
    bufferedAmount = 0;
  }, 20);
  await client.waitForWritable(0);
});
