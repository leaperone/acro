import assert from "node:assert/strict";
import type net from "node:net";
import test from "node:test";
import { encodeOutFrame } from "@acro/protocol";
import { MAX_DAEMON_CLIENT_BUFFER_BYTES } from "./backpressure.ts";
import { DaemonClient } from "./client.ts";
import { packBin, packJson } from "./wire.ts";

test("daemon response hooks run before following frames in the same chunk", async () => {
  const client = new DaemonClient();
  let attached = false;
  let frameSeen = false;
  client.on("frame", () => {
    frameSeen = true;
    assert.equal(attached, true);
  });
  const result = new Promise<unknown>((resolve, reject) => {
    (
      client as unknown as {
        pending: Map<
          number,
          {
            resolve: (value: unknown) => void;
            reject: (error: Error) => void;
            beforeResolve: (value: unknown) => void;
            timer: NodeJS.Timeout;
          }
        >;
      }
    ).pending.set(1, {
      resolve,
      reject,
      beforeResolve: () => {
        attached = true;
      },
      timer: setTimeout(() => {}, 1000),
    });
  });
  const response = packJson({ t: "res", id: 1, ok: true, result: { handle: 7, seq: 3 } });
  const frame = packBin(encodeOutFrame(7, 4, Buffer.from("next")));

  (client as unknown as { onData(chunk: Buffer): void }).onData(Buffer.concat([response, frame]));

  assert.deepEqual(await result, { handle: 7, seq: 3 });
  assert.equal(frameSeen, true);
});

test("daemon request timeout closes the poisoned socket so reconnect can recover", async () => {
  const client = new DaemonClient(20, 1);
  let destroyed = false;
  const socket = {
    write: (_data: Buffer, callback?: (error?: Error | null) => void) => {
      callback?.();
      return true;
    },
    destroy: () => {
      destroyed = true;
      return undefined as unknown as net.Socket;
    },
  } as unknown as net.Socket;
  (
    client as unknown as {
      socket: net.Socket;
    }
  ).socket = socket;

  const blocked = client.request("blocked");
  await assert.rejects(client.request("overflow"), /queue full/);
  await assert.rejects(blocked, /daemon timeout: blocked/);
  assert.equal(destroyed, true);
  assert.equal(
    (client as unknown as { pending: Map<number, unknown> }).pending.size,
    0,
  );
});

test("daemon requests honor a caller deadline without restarting bounded recovery", async () => {
  const client = new DaemonClient(1000, 1);
  let writes = 0;
  let destroyed = false;
  (
    client as unknown as {
      socket: net.Socket;
    }
  ).socket = {
    write: (_data: Buffer, callback?: (error?: Error | null) => void) => {
      writes += 1;
      callback?.();
      return true;
    },
    destroy: () => {
      destroyed = true;
      return undefined as unknown as net.Socket;
    },
  } as unknown as net.Socket;

  const startedAt = Date.now();
  await assert.rejects(
    client.request("expired", undefined, undefined, {
      deadline: startedAt - 1,
      destroySocketOnTimeout: false,
    }),
    /daemon timeout: expired/,
  );
  assert.equal(writes, 0);
  await assert.rejects(
    client.request("budgeted", undefined, undefined, {
      deadline: startedAt + 20,
      destroySocketOnTimeout: false,
    }),
    /daemon timeout: budgeted/,
  );
  assert.ok(Date.now() - startedAt < 500);
  assert.equal(writes, 1);
  assert.equal(destroyed, false);

  const recovered = client.request("recovered");
  (client as unknown as { onData(chunk: Buffer): void }).onData(
    packJson({ t: "res", id: 3, ok: true, result: { ok: true } }),
  );
  assert.deepEqual(await recovered, { ok: true });
});

test("daemon write failures close the broken socket and release pending work", async () => {
  const client = new DaemonClient(1000, 1);
  let destroyed = false;
  (
    client as unknown as {
      socket: net.Socket;
    }
  ).socket = {
    write: (_data: Buffer, callback?: (error?: Error | null) => void) => {
      callback?.(new Error("write failed"));
      return false;
    },
    destroy: () => {
      destroyed = true;
      return undefined as unknown as net.Socket;
    },
  } as unknown as net.Socket;

  await assert.rejects(client.request("write"), /write failed/);
  assert.equal(destroyed, true);
  assert.equal(
    (client as unknown as { pending: Map<number, unknown> }).pending.size,
    0,
  );
});

test("terminal input drops a stalled daemon socket before its queue exceeds the limit", () => {
  const client = new DaemonClient();
  let writes = 0;
  let destroyed = false;
  (
    client as unknown as {
      socket: net.Socket;
    }
  ).socket = {
    destroyed: false,
    writableLength: MAX_DAEMON_CLIENT_BUFFER_BYTES,
    write: () => {
      writes += 1;
      return false;
    },
    destroy: () => {
      destroyed = true;
      return undefined as unknown as net.Socket;
    },
  } as unknown as net.Socket;

  client.sendInput(1, Uint8Array.of(1));

  assert.equal(writes, 0);
  assert.equal(destroyed, true);
});

// daemon 是 detached 进程,活过 runtime 重启,所以"新 runtime + 旧 daemon"是常态。
// 能力必须来自 daemon 的显式声明,而不是解析 "unknown method ..." 的错误文案。
function negotiateWith(reply: (method: string) => unknown): {
  client: DaemonClient;
  done: Promise<void>;
} {
  const client = new DaemonClient(50, 8);
  const socket = {
    write: (data: Buffer, callback?: (error?: Error | null) => void) => {
      callback?.();
      const body = JSON.parse(data.subarray(5).toString("utf8")) as { id: number; method: string };
      setImmediate(() => {
        const result = reply(body.method);
        (client as unknown as { onData(chunk: Buffer): void }).onData(
          packJson(
            result === undefined
              ? { t: "res", id: body.id, ok: false, error: { message: "unknown method" } }
              : { t: "res", id: body.id, ok: true, result },
          ),
        );
      });
      return true;
    },
    destroy: () => undefined as unknown as net.Socket,
  } as unknown as net.Socket;
  (client as unknown as { socket: net.Socket }).socket = socket;
  const done = (client as unknown as { negotiate(): Promise<void> }).negotiate();
  return { client, done };
}

test("daemon capabilities come from the handshake, not from error strings", async () => {
  const current = negotiateWith((method) =>
    method === "daemon.info"
      ? { boot: "b", pid: 1, methods: ["session.createOwned", "session.cwd"] }
      : undefined,
  );
  await current.done;
  assert.equal(current.client.supports("session.createOwned"), true);
  assert.equal(current.client.supports("session.cwd"), true);
  assert.equal(current.client.supports("session.somethingNewer"), false);
});

test("a daemon that reports no methods supports nothing that needs declaring", async () => {
  // 旧 daemon:daemon.info 存在但不报告 methods
  const legacy = negotiateWith((method) =>
    method === "daemon.info" ? { boot: "b", pid: 1, features: { agentSessions: true } } : undefined,
  );
  await legacy.done;
  assert.equal(legacy.client.supports("session.createOwned"), false);
  assert.equal(legacy.client.supports("session.cwd"), false);

  // 更旧的 daemon:连 daemon.info 都没有。握手失败不得抛穿,只落到空能力集。
  const ancient = negotiateWith(() => undefined);
  await ancient.done;
  assert.equal(ancient.client.supports("session.cwd"), false);
});

test("capabilities are dropped when the daemon connection closes", async () => {
  const { client, done } = negotiateWith((method) =>
    method === "daemon.info" ? { boot: "b", pid: 1, methods: ["session.cwd"] } : undefined,
  );
  await done;
  assert.equal(client.supports("session.cwd"), true);

  client.close();
  const socket = (client as unknown as { socket: net.Socket | null }).socket;
  (client as unknown as { onClose(s: net.Socket | null): void }).onClose(socket);
  assert.equal(client.supports("session.cwd"), false);
});
