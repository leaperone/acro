import assert from "node:assert/strict";
import test from "node:test";
import { WebSocket } from "ws";
import type { DeviceRegistry } from "./devices.ts";
import { Gateway, type Conn, type Handlers } from "./ws.ts";

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
    session: {
      sealBinary(data: Uint8Array) {
        sealed += 1;
        return data;
      },
    },
    device: { id: "device", name: "Device", createdAt: "", lastSeenAt: null },
    attached: new Map(),
    browserChannels: new Set(),
    simChannels: new Set(),
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
