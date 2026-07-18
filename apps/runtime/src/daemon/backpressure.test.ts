import assert from "node:assert/strict";
import test from "node:test";
import {
  daemonClientBufferExceeded,
  MAX_DAEMON_CLIENT_BUFFER_BYTES,
  PARSE_BACKLOG_HIGH_CHARS,
  PARSE_BACKLOG_LOW_CHARS,
  shouldPausePty,
} from "./backpressure.ts";

test("pty flow control uses high and low watermarks", () => {
  assert.equal(shouldPausePty(false, PARSE_BACKLOG_HIGH_CHARS - 1), false);
  assert.equal(shouldPausePty(false, PARSE_BACKLOG_HIGH_CHARS), true);
  assert.equal(shouldPausePty(true, PARSE_BACKLOG_LOW_CHARS + 1), true);
  assert.equal(shouldPausePty(true, PARSE_BACKLOG_LOW_CHARS), false);
});

test("daemon clients are dropped before their write queue exceeds the limit", () => {
  assert.equal(daemonClientBufferExceeded(0, MAX_DAEMON_CLIENT_BUFFER_BYTES), false);
  assert.equal(daemonClientBufferExceeded(1, MAX_DAEMON_CLIENT_BUFFER_BYTES), true);
});
