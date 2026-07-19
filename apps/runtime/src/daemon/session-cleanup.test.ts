import assert from "node:assert/strict";
import test from "node:test";
import {
  removeDaemonSessions,
  restartTerminalDaemon,
  type DaemonRequester,
  untrackedDeadSessionIds,
} from "./session-cleanup.ts";

test("untracked dead session cleanup preserves live and workspace sessions", () => {
  const sessions = [
    { id: "live-untracked", alive: true },
    { id: "dead-tracked", alive: false },
    { id: "dead-untracked", alive: false },
  ];

  assert.deepEqual(untrackedDeadSessionIds(sessions, new Set(["dead-tracked"])), [
    "dead-untracked",
  ]);
});

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

test("daemon restart signals the process that answered daemon.info", async () => {
  const signals: Array<[number, NodeJS.Signals]> = [];
  const daemon: DaemonRequester = {
    request: async (method) => {
      assert.equal(method, "daemon.info");
      return { pid: 4242, boot: "boot-id" };
    },
  };

  await restartTerminalDaemon(daemon, (pid, signal) => signals.push([pid, signal]));

  assert.deepEqual(signals, [[4242, "SIGTERM"]]);
});

test("daemon restart rejects an invalid process identity", async () => {
  const daemon: DaemonRequester = {
    request: async () => ({ pid: 0, boot: "" }),
  };

  await assert.rejects(restartTerminalDaemon(daemon), /invalid terminal daemon identity/);
});
