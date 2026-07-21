import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { REMOTE_BOOTSTRAP } from "./remote-bootstrap.ts";

test("REMOTE_BOOTSTRAP is valid bash and (re)starts the service to load new code", () => {
  const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "acro-boot-")), "bootstrap.sh");
  fs.writeFileSync(file, REMOTE_BOOTSTRAP);
  try {
    // 语法检查:模板里的 shell 转义(如 \${VAR:-…}、printf 的 \n)没写坏
    execFileSync("bash", ["-n", file]);
  } finally {
    fs.rmSync(path.dirname(file), { recursive: true, force: true });
  }
  // JS 模板不得意外把 \n 变成真实换行:printf 里必须是字面量反斜杠-n
  assert.match(REMOTE_BOOTSTRAP, /printf '\[acro-ssh\] %s\\n'/);
  // restart(而非 enable --now)才能在更新重跑时加载新代码
  assert.match(REMOTE_BOOTSTRAP, /systemctl --user restart acro-runtime\.service/);
  // 配对码由客户端另一段 ssh 取回,脚本自身不 cat offer
  assert.doesNotMatch(REMOTE_BOOTSTRAP, /cat .*bootstrap-offer/);
});
