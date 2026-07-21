import { test } from "node:test";
import assert from "node:assert/strict";
import { list, parseLsof, parseSs } from "./ports.ts";

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

test("parseSs extracts port/address/pid/process, strips IPv6 brackets, sorts by port", () => {
  const stdout = [
    'LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:(("nginx",pid=1234,fd=6))',
    'LISTEN 0 128 127.0.0.1:5432 0.0.0.0:* users:(("postgres",pid=999,fd=5))',
    'LISTEN 0 511 [::]:443 [::]:* users:(("nginx",pid=1234,fd=7))',
  ].join("\n");
  assert.deepEqual(parseSs(stdout), [
    { port: 80, address: "0.0.0.0", pid: 1234, process: "nginx" },
    { port: 443, address: "::", pid: 1234, process: "nginx" },
    { port: 5432, address: "127.0.0.1", pid: 999, process: "postgres" },
  ]);
});

test("parseSs handles sockets with no process column (no -p permission)", () => {
  assert.deepEqual(parseSs("LISTEN 0 128 0.0.0.0:22 0.0.0.0:*"), [
    { port: 22, address: "0.0.0.0", pid: 0, process: "" },
  ]);
});

test("list returns an array on the real system (lsof present or gracefully empty)", async () => {
  const listeners = await list();
  assert.ok(Array.isArray(listeners));
  for (const l of listeners) {
    assert.equal(typeof l.port, "number");
    assert.ok(l.port > 0);
  }
});
