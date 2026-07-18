import assert from "node:assert/strict";
import test from "node:test";
import { encodeOutFrame } from "@acro/protocol";
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
          }
        >;
      }
    ).pending.set(1, {
      resolve,
      reject,
      beforeResolve: () => {
        attached = true;
      },
    });
  });
  const response = packJson({ t: "res", id: 1, ok: true, result: { handle: 7, seq: 3 } });
  const frame = packBin(encodeOutFrame(7, 4, Buffer.from("next")));

  (client as unknown as { onData(chunk: Buffer): void }).onData(Buffer.concat([response, frame]));

  assert.deepEqual(await result, { handle: 7, seq: 3 });
  assert.equal(frameSeen, true);
});
