import fs from "node:fs";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { Project, Worktree } from "@acro/protocol";
import { idForPath } from "./projects.ts";

const execFileP = promisify(execFile);

async function git(cwd: string, ...args: string[]): Promise<string> {
  try {
    const { stdout } = await execFileP("git", ["-C", cwd, ...args]);
    return stdout;
  } catch (err) {
    const e = err as { stderr?: string; message: string };
    throw new Error(e.stderr?.trim() || e.message);
  }
}

export async function listWorktrees(project: Project): Promise<Worktree[]> {
  const out = await git(project.path, "worktree", "list", "--porcelain");
  const worktrees: Worktree[] = [];
  let current: Partial<Worktree> = {};
  for (const line of `${out}\n`.split("\n")) {
    if (line.startsWith("worktree ")) {
      current = { path: line.slice(9), branch: null, head: null };
    } else if (line.startsWith("HEAD ")) {
      current.head = line.slice(5);
    } else if (line.startsWith("branch ")) {
      current.branch = line.slice(7).replace("refs/heads/", "");
    } else if (line === "" && current.path) {
      worktrees.push({
        id: idForPath(current.path),
        projectId: project.id,
        path: current.path,
        branch: current.branch ?? null,
        head: current.head ?? null,
        isMain: worktrees.length === 0,
      });
      current = {};
    }
  }
  return worktrees;
}

function slugify(branch: string): string {
  return branch.toLowerCase().replace(/\//g, "-");
}

// ponytail: 统一放 <repo>/.claude/worktrees/<slug>,仓库自定义 worktree 脚本的接入以后加
export async function createWorktree(
  project: Project,
  branch: string,
  base?: string,
): Promise<Worktree> {
  const dir = path.join(project.path, ".claude", "worktrees", slugify(branch));
  if (fs.existsSync(dir)) throw new Error(`worktree path already exists: ${dir}`);

  // 保证 .claude/worktrees/ 被忽略,不污染仓库状态
  const commonDir = (await git(project.path, "rev-parse", "--git-common-dir")).trim();
  const excludeFile = path.join(
    path.isAbsolute(commonDir) ? commonDir : path.join(project.path, commonDir),
    "info",
    "exclude",
  );
  const excludeLine = ".claude/worktrees/";
  fs.mkdirSync(path.dirname(excludeFile), { recursive: true });
  const existing = fs.existsSync(excludeFile) ? fs.readFileSync(excludeFile, "utf8") : "";
  if (!existing.split("\n").includes(excludeLine)) {
    fs.writeFileSync(excludeFile, `${existing.replace(/\n?$/, "\n")}${excludeLine}\n`);
  }

  await git(project.path, "worktree", "add", dir, "-b", branch, base ?? "HEAD");
  // git 输出的是 realpath(macOS 上 /var → /private/var),按 realpath 对齐
  const realDir = fs.realpathSync(dir);
  const created = (await listWorktrees(project)).find((w) => w.path === realDir);
  if (!created) throw new Error("worktree created but not found in list");
  return created;
}

export async function removeWorktree(
  project: Project,
  worktreeId: string,
  force = false,
): Promise<void> {
  const target = (await listWorktrees(project)).find((w) => w.id === worktreeId);
  if (!target) throw new Error("worktree not found");
  if (target.isMain) throw new Error("refusing to remove main worktree");
  if (!force) {
    const dirty = (await git(target.path, "status", "--porcelain")).trim();
    if (dirty) throw new Error("worktree is dirty; pass force to remove anyway");
  }
  const args = ["worktree", "remove", target.path];
  if (force) args.push("--force");
  await git(project.path, ...args);
}
