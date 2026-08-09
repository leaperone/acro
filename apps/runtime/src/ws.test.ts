import assert from "node:assert/strict";
import test from "node:test";
import type { IncomingMessage } from "node:http";
import type { Duplex } from "node:stream";
import { WebSocket } from "ws";
import { ALL_RPC_SCOPES, encodeInFrame, pairingAdmissionId, type RpcScope } from "@acro/protocol";
import type { DeviceRegistry } from "./devices.ts";
import {
  admissionMatchesToken,
  deviceHasScope,
  Gateway,
  MAX_IN_FLIGHT_RPC_PER_CONNECTION,
  MAX_IN_FLIGHT_RPC_TOTAL,
  MAX_PREAUTH_CONNECTIONS_PER_ADMISSION,
  MAX_UNKNOWN_PREAUTH_CONNECTIONS,
  removeSurfaceChannels,
  rpcAdmissionFailure,
  websocketAdmissionFailure,
  type Conn,
  type Handlers,
} from "./ws.ts";

function fixture(bufferedAmount: number, scopes: readonly RpcScope[] = ALL_RPC_SCOPES) {
  let sealed = 0;
  let sent = 0;
  let terminated = 0;
  let closed = 0;
  const messages: unknown[] = [];
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
      sealText(text: string) {
        messages.push(JSON.parse(text));
        return new Uint8Array([1]);
      },
      // 测试夹具里 E2EE 是恒等变换,便于直接驱动 onMessage 的解密后分支
      open(data: Uint8Array) {
        return { kind: "binary" as const, data };
      },
    },
    device: { id: "device", name: "Device", createdAt: "", lastSeenAt: null, scopes: [...scopes] },
    admissionId: null,
    attached: new Map(),
    browserChannels: new Map(),
    simChannels: new Map(),
    pendingSimAttaches: new Map(),
    inFlightRpc: 0,
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
    messages,
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

test("websocket upgrades are rejected before allocating beyond the connection cap", () => {
  const { gateway, close } = fixture(0);
  const conns = (gateway as unknown as { conns: Set<Conn> }).conns;
  while (conns.size < 128) conns.add({} as Conn);
  let response = "";
  let destroyed = 0;
  const socket = {
    write(data: string) {
      response += data;
      return true;
    },
    destroy() {
      destroyed += 1;
    },
  } as unknown as Duplex;

  try {
    gateway.handleUpgrade({ url: "/ws" } as IncomingMessage, socket, Buffer.alloc(0));
    assert.match(response, /^HTTP\/1\.1 503 Service Unavailable/);
    assert.equal(destroyed, 1);
    assert.equal(conns.size, 128);
  } finally {
    close();
  }
});

test("unknown pre-auth sockets cannot consume known grant capacity", () => {
  const unknown = Array.from({ length: MAX_UNKNOWN_PREAUTH_CONNECTIONS }, () => ({
    device: null,
    admissionId: null,
  }));
  assert.equal(websocketAdmissionFailure(unknown, null), "unknown");
  assert.equal(websocketAdmissionFailure(unknown, "a".repeat(64)), null);
});

test("each known grant has an independent pre-auth connection cap", () => {
  const admissionId = "a".repeat(64);
  const conns = Array.from({ length: MAX_PREAUTH_CONNECTIONS_PER_ADMISSION }, () => ({
    device: null,
    admissionId,
  }));
  assert.equal(websocketAdmissionFailure(conns, admissionId), "grant");
  assert.equal(websocketAdmissionFailure(conns, "b".repeat(64)), null);
});

test("known admission hints must match the encrypted auth token", () => {
  const token = "t".repeat(64);
  const admissionId = pairingAdmissionId(token);
  assert.equal(admissionMatchesToken(admissionId, token), true);
  assert.equal(admissionMatchesToken(admissionId, "x".repeat(64)), false);
  assert.equal(admissionMatchesToken(null, token), true);
});

test("RPC admission has independent connection and runtime budgets", () => {
  assert.equal(
    rpcAdmissionFailure(MAX_IN_FLIGHT_RPC_PER_CONNECTION - 1, MAX_IN_FLIGHT_RPC_TOTAL - 1),
    null,
  );
  assert.equal(rpcAdmissionFailure(MAX_IN_FLIGHT_RPC_PER_CONNECTION, 0), "connection");
  assert.equal(rpcAdmissionFailure(0, MAX_IN_FLIGHT_RPC_TOTAL), "total");
});

test("RPC dispatch rejects overflow and releases its admission slots", async () => {
  const { gateway, conn, messages, close } = fixture(0);
  let release!: () => void;
  const blocker = new Promise<void>((resolve) => {
    release = resolve;
  });
  let calls = 0;
  (gateway as unknown as { handlers: Handlers }).handlers = {
    "session.list": async () => {
      calls += 1;
      await blocker;
      return [];
    },
  } as unknown as Handlers;
  const dispatch = (
    gateway as unknown as {
      dispatch(
        connection: Conn,
        request: { t: "req"; id: number; method: string; params: unknown },
      ): Promise<void>;
    }
  ).dispatch.bind(gateway);

  try {
    const running = Array.from({ length: MAX_IN_FLIGHT_RPC_PER_CONNECTION }, (_, id) =>
      dispatch(conn, { t: "req", id, method: "session.list", params: {} }),
    );
    assert.equal(calls, MAX_IN_FLIGHT_RPC_PER_CONNECTION);
    await dispatch(conn, { t: "req", id: 99, method: "session.list", params: {} });
    assert.deepEqual(messages, [
      {
        t: "res",
        id: 99,
        ok: false,
        error: { code: "busy", message: "too many concurrent RPC requests" },
      },
    ]);

    release();
    await Promise.all(running);
    assert.equal(conn.inFlightRpc, 0);
    assert.equal((gateway as unknown as { inFlightRpc: number }).inFlightRpc, 0);
    await dispatch(conn, { t: "req", id: 100, method: "session.list", params: {} });
    assert.equal(calls, MAX_IN_FLIGHT_RPC_PER_CONNECTION + 1);
  } finally {
    release();
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

test("terminal session cleanup drops attachments from every connection", () => {
  const { gateway, conn, close } = fixture(0);
  const second = {
    ...conn,
    attached: new Map<number, { sessionId: string; attachSeq: number }>(),
    browserChannels: new Map<number, string>(),
    simChannels: new Map<number, string>(),
    pendingSimAttaches: new Map<string, symbol>(),
  };
  try {
    conn.attached.set(7, { sessionId: "session", attachSeq: 1 });
    conn.attached.set(8, { sessionId: "other", attachSeq: 1 });
    second.attached.set(9, { sessionId: "session", attachSeq: 2 });
    (gateway as unknown as { conns: Set<Conn> }).conns.add(second);

    gateway.dropSession("session");

    assert.deepEqual([...conn.attached.keys()], [8]);
    assert.equal(second.attached.size, 0);
  } finally {
    close();
  }
});

test("terminal attachment lookup follows all connections from the same device", () => {
  const { gateway, conn, close } = fixture(0);
  const second = {
    ...conn,
    attached: new Map<number, { sessionId: string; attachSeq: number }>(),
    browserChannels: new Map<number, string>(),
    simChannels: new Map<number, string>(),
    pendingSimAttaches: new Map<string, symbol>(),
  };
  try {
    (gateway as unknown as { conns: Set<Conn> }).conns.add(second);
    conn.attached.set(7, { sessionId: "session", attachSeq: 1 });
    assert.equal(gateway.hasDeviceSessionAttachment(conn.device!.id, "session"), true);

    conn.attached.clear();
    second.attached.set(8, { sessionId: "session", attachSeq: 2 });
    assert.equal(gateway.hasDeviceSessionAttachment(conn.device!.id, "session"), true);

    second.attached.clear();
    assert.equal(gateway.hasDeviceSessionAttachment(conn.device!.id, "session"), false);
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

test("a valid connection is not authorization to call everything on it", async () => {
  // 只有 read 的设备:能看,不能控,更不能碰 Computer Use 或设备管理
  const { gateway, conn, messages, close } = fixture(0, ["read"]);
  let called = 0;
  (gateway as unknown as { handlers: Handlers }).handlers = new Proxy({} as Handlers, {
    get: () => async () => {
      called += 1;
      return [];
    },
  });
  const dispatch = (
    gateway as unknown as {
      dispatch(c: Conn, r: { t: "req"; id: number; method: string; params: unknown }): Promise<void>;
    }
  ).dispatch.bind(gateway);

  try {
    for (const [id, method] of [
      [1, "session.kill"],
      [2, "computer.click"],
      [3, "computer.capture"],
      [4, "device.share"],
      [5, "daemon.restart"],
    ] as const) {
      await dispatch(conn, { t: "req", id, method, params: {} });
    }
    assert.equal(called, 0, "no forbidden handler may run");
    assert.deepEqual(
      messages.map((m) => (m as { error: { code: string } }).error.code),
      ["forbidden", "forbidden", "forbidden", "forbidden", "forbidden"],
    );

    // 授予的 scope 照常放行
    messages.length = 0;
    await dispatch(conn, { t: "req", id: 6, method: "fs.list", params: { path: "/tmp" } });
    assert.equal(called, 1);
    assert.equal((messages[0] as { ok: boolean }).ok, true);
  } finally {
    close();
  }
});

test("read-only devices watch terminals but cannot type into them", () => {
  const { gateway, conn, close } = fixture(0, ["read"]);
  let forwarded = 0;
  try {
    conn.attached.set(7, { sessionId: "s1", attachSeq: 0 });
    (gateway as unknown as { onInput: (channel: number, data: Uint8Array) => void }).onInput =
      () => {
        forwarded += 1;
      };
    const onMessage = (
      gateway as unknown as { onMessage(c: Conn, raw: Buffer, isBinary: boolean): void }
    ).onMessage.bind(gateway);

    const input = Buffer.from(encodeInFrame(7, new TextEncoder().encode("rm -rf /")));
    onMessage(conn, input, true);
    assert.equal(forwarded, 0, "terminal input requires the control scope");

    conn.device = { ...conn.device!, scopes: ["read", "control"] };
    onMessage(conn, input, true);
    assert.equal(forwarded, 1);
  } finally {
    close();
  }
});

test("scope checks treat unknown grants as unauthorized", () => {
  assert.equal(deviceHasScope(null, "read"), false);
  assert.equal(deviceHasScope({ scopes: null } as never, "read"), false);
  assert.equal(deviceHasScope({ scopes: [] } as never, "read"), false);
  assert.equal(deviceHasScope({ scopes: ["control"] } as never, "read"), false);
  assert.equal(deviceHasScope({ scopes: ["read"] } as never, "read"), true);
});
