import { test } from "node:test";
import assert from "node:assert/strict";
import { list, parseLsof } from "./ports.ts";

test("parseLsof groups name records under their process and sorts by port", () => {
  const stdout = ["p123", "cnode", "n*:5173", "n127.0.0.1:3000", "p456", "cpostgres", "n[::1]:5432"].join("\n");
  const listeners = parseLsof(stdout);
  assert.deepEqual(listeners, [
    { port: 3000, address: "127.0.0.1", pid: 123, process: "node" },
    { port: 5173, address: "*", pid: 123, process: "node" },
    { port: 5432, address: "[::1]", pid: 456, process: "postgres" },
  ]);
});

test("parseLsof dedupes identical address:port:pid (IPv4/IPv6 double-listing)", () => {
  const stdout = ["p1", "cvite", "n*:5173", "n*:5173"].join("\n");
  assert.equal(parseLsof(stdout).length, 1);
});

test("parseLsof skips names without a port", () => {
  const stdout = ["p1", "cx", "nsomething-without-colon"].join("\n");
  assert.deepEqual(parseLsof(stdout), []);
});

test("list returns an array on the real system (lsof present or gracefully empty)", async () => {
  const listeners = await list();
  assert.ok(Array.isArray(listeners));
  for (const l of listeners) {
    assert.equal(typeof l.port, "number");
    assert.ok(l.port > 0);
  }
});
