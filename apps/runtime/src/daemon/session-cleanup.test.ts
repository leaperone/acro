import assert from "node:assert/strict";
import test from "node:test";
import { removeDaemonSessions, type DaemonRequester } from "./session-cleanup.ts";

test("workspace cleanup bounds daemon requests for large session histories", async () => {
  let active = 0;
  let maxActive = 0;
  const removed: string[] = [];
  const daemon: DaemonRequester = {
    request: async (_method, params) => {
      active += 1;
      maxActive = Math.max(maxActive, active);
      await new Promise<void>((resolve) => setImmediate(resolve));
      removed.push((params as { sessionId: string }).sessionId);
      active -= 1;
      return undefined;
    },
  };
  const sessionIds = Array.from({ length: 300 }, (_, index) => `session-${index}`);

  await removeDaemonSessions(daemon, sessionIds);

  assert.equal(maxActive, 16);
  assert.deepEqual(removed.sort(), [...sessionIds].sort());
});

test("workspace cleanup keeps the legacy daemon fallback", async () => {
  const calls: string[] = [];
  const daemon: DaemonRequester = {
    request: async (method) => {
      calls.push(method);
      if (method === "session.remove") throw new Error("unknown method session.remove");
      return undefined;
    },
  };

  await removeDaemonSessions(daemon, ["session"]);

  assert.deepEqual(calls, ["session.remove", "session.kill"]);
});
