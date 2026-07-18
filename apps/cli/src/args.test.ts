import assert from "node:assert/strict";
import test from "node:test";
import { parseCommandLine, parsePairArgs, parseRunArgs, shellQuote } from "./args.ts";

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
  assert.deepEqual(parsePairArgs(["offer", "--name", "MacBook"]), {
    offer: "offer",
    name: "MacBook",
  });
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
