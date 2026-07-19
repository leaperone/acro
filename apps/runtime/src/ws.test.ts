import assert from "node:assert/strict";
import test from "node:test";
import { WebSocket } from "ws";
import type { DeviceRegistry } from "./devices.ts";
import { Gateway, removeSurfaceChannels, type Conn, type Handlers } from "./ws.ts";

function fixture(bufferedAmount: number) {
  let sealed = 0;
  let sent = 0;
  let terminated = 0;
  let closed = 0;
  const ws = {
    readyState: WebSocket.OPEN,
    bufferedAmount,
    send: () => {
      sent += 1;
    },
    terminate: () => {
      terminated += 1;
    },
  } as unknown as WebSocket;
  const conn = {
    ws,
    abortController: new AbortController(),
    session: {
      sealBinary(data: Uint8Array) {
        sealed += 1;
        return data;
      },
    },
    device: { id: "device", name: "Device", createdAt: "", lastSeenAt: null },
    attached: new Map(),
    browserChannels: new Map(),
    simChannels: new Map(),
    pendingSimAttaches: new Map(),
    alive: true,
  } as unknown as Conn;
  const gateway = new Gateway({} as DeviceRegistry, new Uint8Array(32), {} as Handlers, () => {});
  gateway.onConnClosed = () => {
    closed += 1;
  };
  (gateway as unknown as { conns: Set<Conn> }).conns.add(conn);
  return {
    gateway,
    conn,
    counts: () => ({ sealed, sent, terminated, closed }),
    close: () => clearInterval((gateway as unknown as { heartbeat: NodeJS.Timeout }).heartbeat),
  };
}

test("slow visual clients drop frames before encryption", () => {
  const { gateway, conn, counts, close } = fixture(Number.MAX_SAFE_INTEGER);
  try {
    (gateway as unknown as { sendBinary(c: Conn, d: Uint8Array, lossy: boolean): void })
      .sendBinary(conn, new Uint8Array([1]), true);
    assert.deepEqual(counts(), { sealed: 0, sent: 0, terminated: 0, closed: 0 });
  } finally {
    close();
  }
});

test("slow terminal clients reconnect instead of growing an unbounded queue", () => {
  const { gateway, conn, counts, close } = fixture(Number.MAX_SAFE_INTEGER);
  try {
    (gateway as unknown as { sendBinary(c: Conn, d: Uint8Array, lossy: boolean): void })
      .sendBinary(conn, new Uint8Array([1]), false);
    assert.deepEqual(counts(), { sealed: 0, sent: 0, terminated: 1, closed: 1 });
  } finally {
    close();
  }
});

test("healthy clients still receive encrypted frames", () => {
  const { gateway, conn, counts, close } = fixture(0);
  try {
    (gateway as unknown as { sendBinary(c: Conn, d: Uint8Array, lossy: boolean): void })
      .sendBinary(conn, new Uint8Array([1]), false);
    assert.deepEqual(counts(), { sealed: 1, sent: 1, terminated: 0, closed: 0 });
  } finally {
    close();
  }
});

test("terminal daemon loss terminates all authenticated connections", () => {
  const { gateway, counts, close } = fixture(0);
  try {
    gateway.terminateAll();
    assert.deepEqual(counts(), { sealed: 0, sent: 0, terminated: 1, closed: 1 });
  } finally {
    close();
  }
});

test("connection removal aborts in-flight RPC work", () => {
  const { gateway, conn, close } = fixture(0);
  try {
    gateway.terminateDevice(conn.device!.id);
    assert.equal(conn.abortController.signal.aborted, true);
    assert.match((conn.abortController.signal.reason as Error).message, /connection closed/);
  } finally {
    close();
  }
});

test("surface detach removes only the requested surface", () => {
  const channels = new Map([
    [1, "browser-a"],
    [2, "browser-b"],
    [3, "browser-a"],
  ]);
  assert.deepEqual(removeSurfaceChannels(channels, "browser-a"), [1, 3]);
  assert.deepEqual([...channels], [[2, "browser-b"]]);
});

test("surface capture remains active until the last connection leaves", () => {
  const { gateway, conn, close } = fixture(0);
  const second = {
    ...conn,
    browserChannels: new Map<number, string>(),
    simChannels: new Map<number, string>(),
    pendingSimAttaches: new Map<string, symbol>(),
  };
  try {
    conn.browserChannels.set(7, "browser");
    second.browserChannels.set(7, "browser");
    (gateway as unknown as { conns: Set<Conn> }).conns.add(second);

    conn.browserChannels.delete(7);
    assert.equal(gateway.hasBrowserChannel(7), true);
    gateway.dropBrowserChannel(7);
    assert.equal(gateway.hasBrowserChannel(7), false);
    assert.equal(second.browserChannels.size, 0);
  } finally {
    close();
  }
});

test("simulator interest includes pending and attached subscribers", () => {
  const { gateway, conn, close } = fixture(0);
  try {
    conn.pendingSimAttaches.set("sim", Symbol("pending"));
    assert.equal(gateway.hasSimInterest("sim"), true);
    conn.pendingSimAttaches.clear();
    conn.simChannels.set(9, "sim");
    assert.equal(gateway.hasSimInterest("sim"), true);
    conn.simChannels.clear();
    assert.equal(gateway.hasSimInterest("sim"), false);
  } finally {
    close();
  }
});
