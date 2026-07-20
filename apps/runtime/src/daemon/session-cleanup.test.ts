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

test("daemon restart asks the current daemon to stop itself", async () => {
  const calls: string[] = [];
  const daemon: DaemonRequester = {
    request: async (method) => {
      calls.push(method);
      return { restarting: true };
    },
  };

  await restartTerminalDaemon(daemon);

  assert.deepEqual(calls, ["daemon.restart"]);
});

test("daemon restart falls back to a matching legacy daemon identity", async () => {
  const signals: Array<[number, NodeJS.Signals]> = [];
  const daemon: DaemonRequester = {
    request: async (method) => {
      if (method === "daemon.restart") throw new Error("unknown method daemon.restart");
      assert.equal(method, "daemon.info");
      return { pid: 4242, boot: "boot-id" };
    },
  };

  await restartTerminalDaemon(
    daemon,
    (pid, signal) => signals.push([pid, signal]),
    () => ({ pid: 4242, boot: "boot-id" }),
  );

  assert.deepEqual(signals, [[4242, "SIGTERM"]]);
});

test("daemon restart rejects a changed legacy daemon identity", async () => {
  const daemon: DaemonRequester = {
    request: async (method) => {
      if (method === "daemon.restart") throw new Error("unknown method daemon.restart");
      return { pid: 4242, boot: "boot-id" };
    },
  };

  await assert.rejects(
    restartTerminalDaemon(daemon, () => {}, () => ({ pid: 4242, boot: "other-boot" })),
    /invalid terminal daemon identity/,
  );
});
