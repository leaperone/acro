import { test } from "node:test";
import assert from "node:assert/strict";
import { buildSessionEnv } from "./env.ts";

test("session env strips color-suppressing and stale terminal identity vars", () => {
  const env = buildSessionEnv({
    PATH: "/usr/bin",
    HOME: "/Users/harry",
    NO_COLOR: "1",
    TERM: "dumb",
    COLORTERM: "",
    TERM_PROGRAM: "ghostty",
    TERM_PROGRAM_VERSION: "1.3.2",
    TERMINFO: "/Applications/cmux.app/Contents/Resources/terminfo",
  });
  // 颜色抑制与冒充的终端标识全部清掉
  assert.equal(env.NO_COLOR, undefined);
  assert.equal(env.TERM_PROGRAM, undefined);
  assert.equal(env.TERM_PROGRAM_VERSION, undefined);
  assert.equal(env.TERMINFO, undefined);
  // 声明自己的终端身份,覆盖启动环境里的 dumb/空值
  assert.equal(env.TERM, "xterm-256color");
  assert.equal(env.COLORTERM, "truecolor");
  // 其余环境原样保留
  assert.equal(env.PATH, "/usr/bin");
  assert.equal(env.HOME, "/Users/harry");
});

test("session env drops undefined values", () => {
  const env = buildSessionEnv({ PATH: "/usr/bin", MISSING: undefined });
  assert.equal("MISSING" in env, false);
  assert.equal(env.PATH, "/usr/bin");
});
