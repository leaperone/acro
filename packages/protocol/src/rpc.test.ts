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
