import assert from "node:assert/strict";
import test from "node:test";
import {
  daemonClientBufferExceeded,
  daemonClientWriteAllowed,
  daemonRequestCapacityExceeded,
  daemonRequestExpired,
  daemonSessionCapacityExceeded,
  MAX_DAEMON_CLIENT_BUFFER_BYTES,
  MAX_DAEMON_REQUESTS,
  MAX_LIVE_SESSIONS,
  PARSE_BACKLOG_HIGH_CHARS,
  PARSE_BACKLOG_LOW_CHARS,
  shouldPausePty,
  writeDaemonClient,
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
  assert.equal(daemonClientWriteAllowed(0, MAX_DAEMON_CLIENT_BUFFER_BYTES * 2), true);
  assert.equal(daemonClientWriteAllowed(1, MAX_DAEMON_CLIENT_BUFFER_BYTES), false);
});

test("daemon clients are dropped when socket.write throws synchronously", () => {
  let destroyed = false;
  const client = {
    destroyed: false,
    writableLength: 0,
    write: () => {
      throw new Error("sync write failed");
    },
    destroy: () => {
      destroyed = true;
    },
  };

  assert.equal(writeDaemonClient(client, Buffer.from("response")), false);
  assert.equal(destroyed, true);
});

test("daemon rejects new PTYs after reaching the live session limit", () => {
  assert.equal(daemonSessionCapacityExceeded(MAX_LIVE_SESSIONS - 1), false);
  assert.equal(daemonSessionCapacityExceeded(MAX_LIVE_SESSIONS), true);
});

test("daemon bounds active and queued requests", () => {
  assert.equal(daemonRequestCapacityExceeded(MAX_DAEMON_REQUESTS - 1), false);
  assert.equal(daemonRequestCapacityExceeded(MAX_DAEMON_REQUESTS), true);
});

test("daemon drops malformed and expired request deadlines", () => {
  assert.equal(daemonRequestExpired(undefined, 100), false);
  assert.equal(daemonRequestExpired(101, 100), false);
  assert.equal(daemonRequestExpired(100, 100), true);
  assert.equal(daemonRequestExpired("100", 100), true);
});
