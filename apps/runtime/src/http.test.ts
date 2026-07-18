import assert from "node:assert/strict";
import type { IncomingMessage, ServerResponse } from "node:http";
import test from "node:test";
import { createHttpHandler } from "./http.ts";

test("HTTP never exposes a local pairing offer", () => {
  let status = 0;
  let body = "";
  const request = { method: "POST", url: "/local-offer" } as IncomingMessage;
  const response = {
    writeHead(value: number) {
      status = value;
    },
    end(value: string) {
      body = value;
    },
  } as unknown as ServerResponse;

  createHttpHandler()(request, response);

  assert.equal(status, 404);
  assert.deepEqual(JSON.parse(body), { error: "not_found" });
});
