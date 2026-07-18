import assert from "node:assert/strict";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
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

test("concurrent helper requests share one socket", async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-helper-client-"));
  const socketPath = path.join(directory, "helper.sock");
  const sockets = new Set<net.Socket>();
  let connections = 0;
  const server = net.createServer((socket) => {
    connections += 1;
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    let buffer = "";
    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      let newline = buffer.indexOf("\n");
      while (newline >= 0) {
        const request = JSON.parse(buffer.slice(0, newline)) as { id: number; method: string };
        buffer = buffer.slice(newline + 1);
        socket.write(
          `${JSON.stringify({ id: request.id, ok: true, result: request.method })}\n`,
        );
        newline = buffer.indexOf("\n");
      }
    });
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolve);
  });
  const client = new HelperClient(socketPath);

  try {
    assert.deepEqual(await Promise.all([client.request("first"), client.request("second")]), [
      "first",
      "second",
    ]);
    assert.equal(connections, 1);
  } finally {
    client.close();
    for (const socket of sockets) socket.destroy();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
