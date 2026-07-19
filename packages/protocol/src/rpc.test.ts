import assert from "node:assert/strict";
import test from "node:test";
import { methods } from "./rpc.ts";

test("computer input parameters stay within helper-safe bounds", () => {
  const key = methods["computer.key"].params;
  assert.equal(key.safeParse({ keyCode: -1 }).success, false);
  assert.equal(key.safeParse({ keyCode: 65535 }).success, true);
  assert.equal(key.safeParse({ keyCode: 65536 }).success, false);

  const type = methods["computer.type"].params;
  assert.equal(type.safeParse({ text: "x".repeat(2048) }).success, true);
  assert.equal(type.safeParse({ text: "x".repeat(2049) }).success, false);
});

test("browser input parameters stay within bounded control payloads", () => {
  const input = methods["browser.input"].params;
  assert.equal(
    input.safeParse({ browserId: "browser", event: { kind: "key", key: "x".repeat(64) } })
      .success,
    true,
  );
  assert.equal(
    input.safeParse({ browserId: "browser", event: { kind: "key", key: "x".repeat(65) } })
      .success,
    false,
  );
  assert.equal(
    input.safeParse({ browserId: "browser", event: { kind: "type", text: "x".repeat(2048) } })
      .success,
    true,
  );
  assert.equal(
    input.safeParse({ browserId: "browser", event: { kind: "type", text: "x".repeat(2049) } })
      .success,
    false,
  );
});

test("simulator methods accept only fixed-size UDID values", () => {
  const valid = "00000000-0000-0000-0000-000000000000";
  for (const method of [
    "simulator.boot",
    "simulator.shutdown",
    "simulator.attach",
    "simulator.detach",
  ] as const) {
    assert.equal(methods[method].params.safeParse({ udid: valid }).success, true);
    assert.equal(methods[method].params.safeParse({ udid: "x".repeat(36) }).success, false);
    assert.equal(methods[method].params.safeParse({ udid: "x".repeat(900_000) }).success, false);
  }
  assert.equal(
    methods["simulator.list"].result.safeParse([
      { udid: valid, name: "iPhone", state: "Booted", runtime: "iOS" },
    ]).success,
    true,
  );
  assert.equal(
    methods["simulator.list"].result.safeParse([
      { udid: "not-a-udid", name: "iPhone", state: "Booted", runtime: "iOS" },
    ]).success,
    false,
  );
});

test("session removal accepts only UUID session ids", () => {
  const params = methods["session.remove"].params;
  assert.equal(
    params.safeParse({ sessionId: "00000000-0000-4000-8000-000000000000" }).success,
    true,
  );
  assert.equal(params.safeParse({ sessionId: "../workspace-state.json" }).success, false);
});
