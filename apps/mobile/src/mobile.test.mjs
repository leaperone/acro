import assert from "node:assert/strict";
import test from "node:test";
import { parseServerConfig } from "./client.ts";
import { mapContainedPoint } from "./surface.ts";
import {
  isTerminalDocumentUrl,
  parseTerminalBridgeMessage,
  safeTerminalExternalUrl,
  TERMINAL_DOCUMENT_ORIGIN,
  TERMINAL_DOCUMENT_URL,
} from "./terminal-bridge.ts";
import { createTerminalHtml } from "./terminal-html.ts";

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

test("terminal navigation stays inside the trusted inline document", () => {
  assert.equal(isTerminalDocumentUrl(TERMINAL_DOCUMENT_URL), true);
  assert.equal(isTerminalDocumentUrl(TERMINAL_DOCUMENT_ORIGIN), true);
  assert.equal(isTerminalDocumentUrl("about:blank"), true);
  assert.equal(isTerminalDocumentUrl("https://attacker.example/"), false);
  assert.equal(safeTerminalExternalUrl("https://example.com/docs"), "https://example.com/docs");
  assert.equal(safeTerminalExternalUrl("javascript:alert(1)"), null);
  assert.equal(safeTerminalExternalUrl("acro://pair?c=secret"), null);
});

test("terminal bridge rejects foreign, malformed, and out-of-range messages", () => {
  const token = "bridge-token";
  const input = JSON.stringify({ type: "input", dataB64: "aGk=", bridgeToken: token });
  assert.deepEqual(parseTerminalBridgeMessage(input, TERMINAL_DOCUMENT_URL, token), {
    type: "input",
    dataB64: "aGk=",
  });
  assert.equal(
    parseTerminalBridgeMessage(input, "https://attacker.example/", token),
    null,
  );
  assert.equal(parseTerminalBridgeMessage(input, TERMINAL_DOCUMENT_URL, "wrong-token"), null);
  assert.equal(parseTerminalBridgeMessage("{", TERMINAL_DOCUMENT_URL, token), null);
  assert.deepEqual(
    parseTerminalBridgeMessage(
      JSON.stringify({ type: "open", url: "https://example.com/docs", bridgeToken: token }),
      TERMINAL_DOCUMENT_URL,
      token,
    ),
    { type: "open", url: "https://example.com/docs" },
  );
  assert.equal(
    parseTerminalBridgeMessage(
      JSON.stringify({ type: "open", url: "javascript:alert(1)", bridgeToken: token }),
      TERMINAL_DOCUMENT_URL,
      token,
    ),
    null,
  );
  assert.equal(
    parseTerminalBridgeMessage(
      JSON.stringify({ type: "resize", cols: 1, rows: 40, bridgeToken: token }),
      TERMINAL_DOCUMENT_URL,
      token,
    ),
    null,
  );
  assert.equal(
    parseTerminalBridgeMessage(
      JSON.stringify({ type: "input", dataB64: "not base64", bridgeToken: token }),
      TERMINAL_DOCUMENT_URL,
      token,
    ),
    null,
  );
});

test("terminal HTML scopes the native bridge to its instance token", () => {
  const html = createTerminalHtml("unique-token");
  assert.match(html, /const bridgeToken = "unique-token"/);
  assert.match(html, /const bridgeName = "__acro_unique-token"/);
  assert.match(html, /window\[bridgeName\]/);
  assert.match(html, /window\.open = \(url\)/);
  assert.doesNotMatch(html, /window\.__acro/);
});
