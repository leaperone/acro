// CLI 端到端:pair → projects → run(管道模式跑命令并收输出) → sessions。

import assert from "node:assert/strict";
import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const PORT = 18794;
const PAIR_CODE = "E2ECLITEST1";
const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), "acro-e2e-cli-state-"));
const clientDir = fs.mkdtempSync(path.join(os.tmpdir(), "acro-e2e-cli-client-"));
const projectsRoot = fs.mkdtempSync(path.join(os.tmpdir(), "acro-e2e-cli-projects-"));
const runtimeEntry = fileURLToPath(new URL("../../runtime/src/index.ts", import.meta.url));
const cliEntry = fileURLToPath(new URL("../src/cli.ts", import.meta.url));

const runtimeEnv = {
  ...process.env,
  ACRO_STATE_DIR: stateDir,
  ACRO_PORT: String(PORT),
  ACRO_PAIR_CODE: PAIR_CODE,
  ACRO_PROJECT_ROOTS: projectsRoot,
};
const cliEnv = { ...process.env, ACRO_CLIENT_CONFIG: path.join(clientDir, "client.json") };

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

function cli(...args: string[]): string {
  return execFileSync(process.execPath, [cliEntry, ...args], { env: cliEnv, encoding: "utf8" });
}

async function main(): Promise<void> {
  // fixture repo
  const repo = path.join(projectsRoot, "demo");
  fs.mkdirSync(repo);
  const git = (...a: string[]) =>
    execFileSync("git", ["-C", repo, "-c", "user.email=e2e@t", "-c", "user.name=e2e", ...a]);
  git("init", "-b", "main");
  fs.writeFileSync(path.join(repo, "f.txt"), "x\n");
  git("add", ".");
  git("commit", "-m", "init");

  const runtime: ChildProcess = spawn(process.execPath, [runtimeEntry], {
    env: runtimeEnv,
    stdio: ["ignore", "ignore", "pipe"],
  });
  runtime.stderr!.on("data", (d: Buffer) => process.stderr.write(`[runtime!] ${d}`));

  try {
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
      try {
        if ((await fetch(`http://127.0.0.1:${PORT}/health`)).ok) break;
      } catch {
        await sleep(150);
      }
    }

    const pairOut = cli("pair", `127.0.0.1:${PORT}`, "--code", PAIR_CODE, "--name", "e2e-cli");
    assert.match(pairOut, /paired as e2e-cli/);
    console.log("[e2e] pair ok");

    const projects = cli("projects");
    assert.match(projects, /demo/);

    // run:管道模式,命令自然退出,CLI 跟随退出并带回输出
    const runOut = execFileSync(
      process.execPath,
      [cliEntry, "run", "--project", "demo", "echo CLI_RUN_OK && pwd"],
      { env: cliEnv, encoding: "utf8" },
    );
    assert.match(runOut, /CLI_RUN_OK/);
    assert.match(runOut, /demo/);
    console.log("[e2e] run ok");

    const sessions = cli("sessions");
    assert.match(sessions, /exit=0/);
    console.log("[e2e] sessions ok");

    console.log("\nE2E-CLI PASS ✅  pair/projects/run/sessions 全部通过");
  } finally {
    runtime.kill("SIGTERM");
    await sleep(300);
    try {
      const meta = JSON.parse(fs.readFileSync(path.join(stateDir, "daemon.meta.json"), "utf8"));
      process.kill(meta.pid, "SIGTERM");
    } catch {
      // daemon 未启动
    }
    for (const dir of [stateDir, clientDir, projectsRoot]) {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  }
}

main().catch((err) => {
  console.error("E2E-CLI FAIL ❌", err);
  process.exit(1);
});
