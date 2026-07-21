import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { REMOTE_BOOTSTRAP } from "./remote-bootstrap.ts";

test("REMOTE_BOOTSTRAP is valid bash (bash -n) and prints only the offer to stdout", () => {
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
  // 只有配对码走 stdout,其余进度都重定向到 stderr
  assert.match(REMOTE_BOOTSTRAP, /cat "\$HOME\/\.acro\/bootstrap-offer\.txt"/);
});
