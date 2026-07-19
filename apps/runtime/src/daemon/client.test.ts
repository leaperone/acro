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

test("daemon requests time out, stall new work, and recover after late responses", async () => {
  const client = new DaemonClient(20, 1);
  let drainedMethods: string[] = [];
  client.on("lateResponsesDrained", (methods: string[]) => {
    drainedMethods = methods;
  });
  (
    client as unknown as {
      socket: net.Socket;
    }
  ).socket = {
    write: (_data: Buffer, callback?: (error?: Error | null) => void) => {
      callback?.();
      return true;
    },
  } as unknown as net.Socket;

  const blocked = client.request("blocked");
  await assert.rejects(client.request("overflow"), /queue full/);
  await assert.rejects(blocked, /daemon timeout: blocked/);
  await assert.rejects(client.request("stalled"), /daemon stalled/);
  assert.equal(
    (client as unknown as { pending: Map<number, unknown> }).pending.size,
    0,
  );

  (client as unknown as { onData(chunk: Buffer): void }).onData(
    packJson({ t: "res", id: 1, ok: true, result: {} }),
  );
  assert.deepEqual(drainedMethods, ["blocked"]);
  const recovered = client.request("recovered");
  (client as unknown as { onData(chunk: Buffer): void }).onData(
    packJson({ t: "res", id: 2, ok: true, result: { ok: true } }),
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
