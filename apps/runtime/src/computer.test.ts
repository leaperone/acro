import assert from "node:assert/strict";
import test from "node:test";
import type { StringDecoder } from "node:string_decoder";
import { HelperClient } from "./computer.ts";

test("helper responses preserve unicode split across socket chunks", async () => {
  const client = new HelperClient();
  const internals = client as unknown as {
    decoder: StringDecoder;
    onData(text: string): void;
    pending: Map<
      number,
      { resolve: (value: unknown) => void; reject: (error: Error) => void; timer: NodeJS.Timeout }
    >;
  };
  const response = Buffer.from(
    `${JSON.stringify({ id: 1, ok: true, result: { title: "终端" } })}\n`,
    "utf8",
  );
  const marker = Buffer.from("终", "utf8");
  const split = response.indexOf(marker) + 1;

  const result = new Promise<unknown>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("test timeout")), 1000);
    internals.pending.set(1, { resolve, reject, timer });
  });
  internals.onData(internals.decoder.write(response.subarray(0, split)));
  internals.onData(internals.decoder.write(response.subarray(split)));

  assert.deepEqual(await result, { title: "终端" });
});
