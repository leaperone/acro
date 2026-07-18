import assert from "node:assert/strict";
import test from "node:test";
import { parseServerConfig } from "./client.ts";
import { mapContainedPoint } from "./surface.ts";

test("parseServerConfig rejects corrupt and legacy values", () => {
  assert.equal(parseServerConfig("{"), null);
  assert.equal(parseServerConfig(JSON.stringify({ host: "127.0.0.1", token: "old" })), null);
  assert.equal(
    parseServerConfig(
      JSON.stringify({
        name: "iPhone",
        deviceId: "device-1",
        token: "token",
        pub: "public-key",
        endpoints: ["127.0.0.1:7700"],
      }),
    )?.deviceId,
    "device-1",
  );
});

test("mapContainedPoint ignores letterbox padding", () => {
  assert.deepEqual(
    mapContainedPoint({ x: 150, y: 300 }, { w: 300, h: 600 }, { w: 1000, h: 500 }),
    { x: 500, y: 250 },
  );
  assert.equal(
    mapContainedPoint({ x: 150, y: 100 }, { w: 300, h: 600 }, { w: 1000, h: 500 }),
    null,
  );
  assert.deepEqual(
    mapContainedPoint({ x: 300, y: 150 }, { w: 600, h: 300 }, { w: 500, h: 1000 }),
    { x: 250, y: 500 },
  );
  assert.equal(
    mapContainedPoint({ x: 100, y: 150 }, { w: 600, h: 300 }, { w: 500, h: 1000 }),
    null,
  );
});
