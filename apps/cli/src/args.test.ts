import assert from "node:assert/strict";
import test from "node:test";
import {
  parseCommandLine,
  parsePairArgs,
  parseRunArgs,
  parseSshArgs,
  selectPairEndpoints,
  shellQuote,
} from "./args.ts";

test("parseSshArgs takes a single target plus options and defaults pair off", () => {
  assert.deepEqual(parseSshArgs(["user@host"]), {
    target: "user@host",
    name: undefined,
    repo: undefined,
    branch: undefined,
    endpoint: undefined,
    pair: false,
  });
  assert.deepEqual(
    parseSshArgs(["prod", "--pair", "--endpoint", "1.2.3.4:8790", "--branch", "dev"]),
    {
      target: "prod",
      name: undefined,
      repo: undefined,
      branch: "dev",
      endpoint: "1.2.3.4:8790",
      pair: true,
    },
  );
});

test("parseSshArgs fails closed on missing target, dupes, and unknown flags", () => {
  assert.throws(() => parseSshArgs(["--pair"]), /usage: acro ssh/);
  assert.throws(() => parseSshArgs(["a", "b"]), /single target/);
  assert.throws(() => parseSshArgs(["a", "--endpoint"]), /requires a value/);
  assert.throws(
    () => parseSshArgs(["a", "--branch", "x", "--branch", "y"]),
    /only be specified once/,
  );
  assert.throws(() => parseSshArgs(["a", "--tunnel"]), /unknown ssh option/);
  // 目标以 - 开头会被 ssh 当选项(参数注入),拒绝
  assert.throws(() => parseSshArgs(["-oProxyCommand=x"]), /invalid ssh target/);
});

test("selectPairEndpoints drops loopback and puts an explicit endpoint first", () => {
  const offer = ["192.168.1.5:8790", "127.0.0.1:8790", "[::1]:8790", "localhost:8790"];
  assert.deepEqual(selectPairEndpoints(offer), ["192.168.1.5:8790"]);
  assert.deepEqual(selectPairEndpoints(offer, "acro.example:8790"), [
    "acro.example:8790",
    "192.168.1.5:8790",
  ]);
  // explicit endpoint already present is not duplicated
  assert.deepEqual(selectPairEndpoints(offer, "192.168.1.5:8790"), ["192.168.1.5:8790"]);
  // only-loopback offer yields nothing to connect to
  assert.deepEqual(selectPairEndpoints(["127.0.0.1:8790"]), []);
});

test("double dash keeps target command flags outside Acro parsing", () => {
  const parsed = parseCommandLine([
    "--server",
    "server-a",
    "run",
    "--cwd",
    "/repo",
    "--",
    "tool",
    "--server",
    "server-b",
    "--cwd",
    "/inside",
  ]);
  assert.deepEqual(parsed, {
    command: "run",
    args: ["--cwd", "/repo"],
    passthrough: ["tool", "--server", "server-b", "--cwd", "/inside"],
    serverRef: "server-a",
  });
  assert.deepEqual(parseRunArgs(parsed.args, parsed.passthrough), {
    cwd: "/repo",
    command: "'tool' '--server' 'server-b' '--cwd' '/inside'",
  });
});

test("recognized options work after the command but before double dash", () => {
  const parsed = parseCommandLine(["run", "echo", "ok", "--server", "server-a"]);
  assert.equal(parsed.serverRef, "server-a");
  assert.deepEqual(parseRunArgs(parsed.args, parsed.passthrough), {
    cwd: undefined,
    command: "echo ok",
  });
});

test("missing or duplicate CLI option values fail closed", () => {
  assert.throws(() => parseCommandLine(["run", "--server"]), /requires a value/);
  assert.throws(
    () => parseCommandLine(["--server", "a", "run", "--server", "b"]),
    /only be specified once/,
  );
  assert.throws(() => parseRunArgs(["--cwd"], null), /requires a value/);
  assert.throws(() => parseCommandLine(["run", "--server", "--cwd", "/repo"]), /requires a value/);
  assert.throws(() => parseRunArgs(["--cwd", "--cwd", "/repo"], null), /requires a value/);
  assert.deepEqual(parsePairArgs(["--name", "MacBook"]), { name: "MacBook" });
  assert.throws(() => parsePairArgs(["offer"]), /provided on stdin/);
  assert.throws(() => parsePairArgs(["--offer", "secret"]), /unknown pair option/);
});

test("double-dash command tokens survive shell parsing exactly", () => {
  assert.equal(shellQuote("can't"), "'can'\\''t'");
  assert.deepEqual(
    parseRunArgs([], ["printf", "<%s>\\n", "a b", "$HOME", "", "can't"]),
    {
      cwd: undefined,
      command: "'printf' '<%s>\\n' 'a b' '$HOME' '' 'can'\\''t'",
    },
  );
});
