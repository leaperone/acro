// CLI 端到端:pair → run(管道模式跑命令并收输出) → sessions。

import assert from "node:assert/strict";
import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const PORT = 18794;
const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), "acro-e2e-cli-state-"));
const clientDir = fs.mkdtempSync(path.join(os.tmpdir(), "acro-e2e-cli-client-"));
const projectsRoot = fs.mkdtempSync(path.join(os.tmpdir(), "acro-e2e-cli-projects-"));
const runtimeEntry = fileURLToPath(new URL("../../runtime/src/index.ts", import.meta.url));
const cliEntry = fileURLToPath(new URL("../src/cli.ts", import.meta.url));
const clientConfig = path.join(clientDir, "client.json");
const localClientConfig = path.join(clientDir, "local-client.json");

const runtimeEnv = {
  ...process.env,
  ACRO_STATE_DIR: stateDir,
  ACRO_PORT: String(PORT),
};
const cliEnv = { ...process.env, ACRO_CLIENT_CONFIG: clientConfig };

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

function cli(...args: string[]): string {
  return execFileSync(process.execPath, [cliEntry, ...args], { env: cliEnv, encoding: "utf8" });
}

function cliWithInput(input: string, ...args: string[]): string {
  return execFileSync(process.execPath, [cliEntry, ...args], {
    env: cliEnv,
    encoding: "utf8",
    input,
  });
}

async function main(): Promise<void> {
  fs.chmodSync(clientDir, 0o755);
  fs.writeFileSync(clientConfig, "{}", { mode: 0o644 });

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

    const offer = fs.readFileSync(path.join(stateDir, "bootstrap-offer.txt"), "utf8").trim();
    const localPairOut = execFileSync(process.execPath, [cliEntry, "pair", "--name", "e2e-local"], {
      env: { ...cliEnv, ACRO_CLIENT_CONFIG: localClientConfig, ACRO_STATE_DIR: stateDir },
      encoding: "utf8",
    });
    assert.match(localPairOut, /已配对 e2e-local/);
    console.log("[e2e] local bootstrap pair ok");

    const pairOut = cliWithInput(`${offer}\n`, "pair", "--name", "e2e-cli");
    assert.match(pairOut, /已配对 e2e-cli/);
    assert.equal(fs.statSync(clientDir).mode & 0o777, 0o700);
    assert.equal(fs.statSync(clientConfig).mode & 0o777, 0o600);
    console.log("[e2e] pair ok");

    const config = JSON.parse(fs.readFileSync(clientConfig, "utf8"));
    const primary = config.servers[0];
    config.servers.push({ ...primary, localId: "server-b", name: "server-b" });
    fs.writeFileSync(clientConfig, JSON.stringify(config, null, 2));
    cli("--server", "server-b", "endpoints", "add", "b.example:9999");
    const updatedConfig = JSON.parse(fs.readFileSync(clientConfig, "utf8"));
    assert.equal(updatedConfig.servers[0].endpoints.includes("b.example:9999"), false);
    assert.equal(updatedConfig.servers[1].endpoints.includes("b.example:9999"), true);
    console.log("[e2e] server-scoped endpoints ok");

    // run:管道模式,命令自然退出,CLI 跟随退出并带回输出
    const runOut = execFileSync(
      process.execPath,
      [cliEntry, "run", "--cwd", repo, "echo CLI_RUN_OK && pwd"],
      { env: cliEnv, encoding: "utf8" },
    );
    assert.match(runOut, /CLI_RUN_OK/);
    assert.match(runOut, /demo/);
    console.log("[e2e] run ok");

    const passthroughOut = execFileSync(
      process.execPath,
      [
        cliEntry,
        "run",
        "--cwd",
        repo,
        "--",
        "printf",
        "CLI_ARGS:<%s>:<%s>:<%s>:<%s>:<%s>:<%s>\\n",
        "--server",
        "server-b",
        "--cwd",
        "/inside path",
        "$HOME",
        "",
      ],
      { env: cliEnv, encoding: "utf8" },
    );
    assert.match(
      passthroughOut,
      /CLI_ARGS:<--server>:<server-b>:<--cwd>:<\/inside path>:<\$HOME>:<>/,
    );
    console.log("[e2e] double-dash passthrough ok");

    const sessions = cli("sessions");
    assert.match(sessions, /exit=0/);
    console.log("[e2e] sessions ok");

    console.log("\nE2E-CLI PASS ✅  pair/run/sessions 全部通过");
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
