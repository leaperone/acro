import assert from "node:assert/strict";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import type { StringDecoder } from "node:string_decoder";
import { HelperClient } from "./computer.ts";

async function waitFor(predicate: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  assert.fail("condition was not met");
}

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

test("helper requests execute one at a time on one socket", async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-helper-client-"));
  const socketPath = path.join(directory, "helper.sock");
  const sockets = new Set<net.Socket>();
  const requests: Array<{ id: number; method: string; deadlineMs: number }> = [];
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
        const request = JSON.parse(buffer.slice(0, newline)) as {
          id: number;
          method: string;
          deadlineMs: number;
        };
        buffer = buffer.slice(newline + 1);
        requests.push(request);
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
    const first = client.request("first");
    const second = client.request("second");
    await waitFor(() => requests.length === 1);
    assert.equal(requests[0]?.method, "first");
    assert.ok(requests[0]!.deadlineMs > Date.now());
    [...sockets][0]!.write(`${JSON.stringify({ id: requests[0]!.id, ok: true, result: "first" })}\n`);
    assert.equal(await first, "first");

    await waitFor(() => requests.length === 2);
    assert.equal(requests[1]?.method, "second");
    [...sockets][0]!.write(`${JSON.stringify({ id: requests[1]!.id, ok: true, result: "second" })}\n`);
    assert.equal(await second, "second");
    assert.equal(connections, 1);
  } finally {
    client.close();
    for (const socket of sockets) socket.destroy();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("helper timeout drops the connection and queued work resumes on a new deadline", async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-helper-timeout-"));
  const socketPath = path.join(directory, "helper.sock");
  const sockets = new Set<net.Socket>();
  const requests: Array<{ id: number; method: string; deadlineMs: number }> = [];
  let connections = 0;
  const server = net.createServer((socket) => {
    connections += 1;
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    let buffer = "";
    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      const newline = buffer.indexOf("\n");
      if (newline < 0) return;
      const request = JSON.parse(buffer.slice(0, newline)) as {
        id: number;
        method: string;
        deadlineMs: number;
      };
      requests.push(request);
      if (request.method === "second") {
        socket.write(`${JSON.stringify({ id: request.id, ok: true, result: "second" })}\n`);
      }
    });
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolve);
  });
  const client = new HelperClient(socketPath, 30, 1);

  try {
    const first = client.request("first");
    const second = client.request("second");
    await assert.rejects(client.request("third"), /queue full/);
    await assert.rejects(first, /helper timeout: first/);
    assert.equal(await second, "second");
    assert.equal(connections, 2);
    assert.equal(requests.length, 2);
    assert.ok(requests[1]!.deadlineMs > requests[0]!.deadlineMs);
  } finally {
    client.close();
    for (const socket of sockets) socket.destroy();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
