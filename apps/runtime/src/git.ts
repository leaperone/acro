// Git 状态数据层(只读)。仓库在 Mac mini 上,runtime 跑系统 git;客户端经 git.status /
// git.diff 只读展示。不做 stage/commit/push——那属于终端 Agent 的边界。
// GIT_OPTIONAL_LOCKS=0:只读查询不抢 index.lock。

import { execFile } from "node:child_process";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import type { GitFileStatus, GitStatus } from "@acro/protocol";

const exec = promisify(execFile);
const DIFF_MAX_BYTES = 512 * 1024;
const GIT_ENV = { ...process.env, GIT_OPTIONAL_LOCKS: "0" };

function resolvePath(input: string): string {
  const raw = input.trim();
  if (raw === "") return os.homedir();
  const expanded = raw === "~" || raw.startsWith("~/") ? path.join(os.homedir(), raw.slice(1)) : raw;
  return path.resolve(expanded);
}

async function git(cwd: string, args: string[], maxBytes = 1024 * 1024): Promise<string> {
  const { stdout } = await exec("git", ["-C", cwd, ...args], {
    env: GIT_ENV,
    maxBuffer: maxBytes,
    encoding: "utf8",
  });
  return stdout;
}

// porcelain v1 的两位状态码 → 我们的枚举 + 是否已 stage。
function mapStatus(xy: string): { status: GitFileStatus["status"]; staged: boolean } {
  if (xy === "??") return { status: "untracked", staged: false };
  const x = xy[0] ?? " ";
  const y = xy[1] ?? " ";
  const staged = x !== " " && x !== "?";
  if (x === "U" || y === "U" || xy === "AA" || xy === "DD") return { status: "conflicted", staged };
  if (x === "R" || y === "R") return { status: "renamed", staged };
  if (x === "A") return { status: "added", staged };
  if (x === "D" || y === "D") return { status: "deleted", staged };
  return { status: "modified", staged };
}

export async function status(input: string): Promise<GitStatus> {
  const dir = resolvePath(input);
  let root: string;
  try {
    root = (await git(dir, ["rev-parse", "--show-toplevel"])).trim();
  } catch {
    return { isRepo: false, root: null, branch: null, files: [] };
  }

  let branch: string | null = null;
  try {
    const head = (await git(root, ["rev-parse", "--abbrev-ref", "HEAD"])).trim();
    branch = head === "HEAD" ? null : head; // detached HEAD
  } catch {
    branch = null;
  }

  const files: GitFileStatus[] = [];
  try {
    const raw = await git(root, ["status", "--porcelain=v1", "-z"]);
    // -z:条目以 NUL 分隔;重命名/复制会多占一个 NUL 段(旧路径),跳过它。
    const tokens = raw.split("\0");
    for (let i = 0; i < tokens.length; i++) {
      const token = tokens[i];
      if (!token) continue;
      const xy = token.slice(0, 2);
      const rel = token.slice(3);
      const { status: st, staged } = mapStatus(xy);
      files.push({ path: path.join(root, rel), status: st, staged });
      if (xy[0] === "R" || xy[0] === "C") i++; // 消费旧路径段
    }
  } catch {
    /* status 失败:返回已知的 root/branch + 空列表 */
  }

  return { isRepo: true, root, branch, files };
}

export async function diff(input: string): Promise<{ diff: string; truncated: boolean }> {
  const file = resolvePath(input);
  const dir = path.dirname(file);
  let root: string;
  try {
    root = (await git(dir, ["rev-parse", "--show-toplevel"])).trim();
  } catch {
    return { diff: "", truncated: false };
  }
  try {
    // 相对 HEAD 的全部改动(含已 stage)。截断超大 diff。
    const out = await git(root, ["diff", "HEAD", "--", file], DIFF_MAX_BYTES + 1024);
    if (out.length > DIFF_MAX_BYTES) {
      return { diff: out.slice(0, DIFF_MAX_BYTES), truncated: true };
    }
    return { diff: out, truncated: false };
  } catch {
    // 新文件(HEAD 无此路径)git diff HEAD 会失败:回退到 no-index 与 /dev/null 比。
    try {
      const out = await git(root, ["diff", "--no-index", "--", "/dev/null", file], DIFF_MAX_BYTES + 1024);
      return { diff: out.slice(0, DIFF_MAX_BYTES), truncated: out.length > DIFF_MAX_BYTES };
    } catch (err) {
      // --no-index 有差异时退出码为 1,stdout 仍是 diff:execFile 会把它塞进 error。
      const stdout = (err as { stdout?: string }).stdout ?? "";
      return { diff: stdout.slice(0, DIFF_MAX_BYTES), truncated: stdout.length > DIFF_MAX_BYTES };
    }
  }
}
