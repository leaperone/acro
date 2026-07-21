import { test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import nodeFs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { diff, status } from "./git.ts";

const exec = promisify(execFile);

async function initRepo(): Promise<string> {
  const dir = await nodeFs.mkdtemp(path.join(os.tmpdir(), "acro-git-test-"));
  await exec("git", ["-C", dir, "init", "-q"]);
  await exec("git", ["-C", dir, "config", "user.email", "t@t.dev"]);
  await exec("git", ["-C", dir, "config", "user.name", "t"]);
  await exec("git", ["-C", dir, "config", "commit.gpgsign", "false"]);
  return dir;
}

test("status: non-repo returns isRepo false", async () => {
  const dir = await nodeFs.mkdtemp(path.join(os.tmpdir(), "acro-nogit-"));
  const s = await status(dir);
  assert.equal(s.isRepo, false);
  assert.deepEqual(s.files, []);
});

test("status: lists modified, untracked and reports branch", async () => {
  const dir = await initRepo();
  await nodeFs.writeFile(path.join(dir, "tracked.ts"), "v1\n");
  await exec("git", ["-C", dir, "add", "-A"]);
  await exec("git", ["-C", dir, "commit", "-q", "-m", "init"]);
  await nodeFs.writeFile(path.join(dir, "tracked.ts"), "v2\n");    // modified
  await nodeFs.writeFile(path.join(dir, "fresh.ts"), "new\n");     // untracked

  const s = await status(dir);
  assert.equal(s.isRepo, true);
  assert.ok(s.branch && s.branch.length > 0);
  const byName = Object.fromEntries(s.files.map((f) => [path.basename(f.path), f]));
  assert.equal(byName["tracked.ts"]!.status, "modified");
  assert.equal(byName["fresh.ts"]!.status, "untracked");
  assert.equal(byName["fresh.ts"]!.staged, false);
  // 路径是锚定在 git toplevel 的绝对路径(macOS 上 git 会解析 /var → /private/var 软链)
  assert.ok(path.isAbsolute(byName["tracked.ts"]!.path));
  assert.ok(byName["tracked.ts"]!.path.endsWith(`${path.sep}tracked.ts`));
});

test("diff: shows changes for a modified tracked file", async () => {
  const dir = await initRepo();
  const file = path.join(dir, "a.ts");
  await nodeFs.writeFile(file, "old\n");
  await exec("git", ["-C", dir, "add", "-A"]);
  await exec("git", ["-C", dir, "commit", "-q", "-m", "init"]);
  await nodeFs.writeFile(file, "new\n");

  const d = await diff(file);
  assert.match(d.diff, /-old/);
  assert.match(d.diff, /\+new/);
  assert.equal(d.truncated, false);
});
