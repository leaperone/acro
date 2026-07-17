// Computer Use 链路冒烟:helper(Swift) ← runtime ← WS 客户端。
// 只验证无需系统权限的方法(permissions.check / window.list)。

import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";

const PORT = 18795;
const PAIR_CODE = "E2ECOMPUTER";
const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), "acro-e2e-computer-"));
const runtimeEntry = fileURLToPath(new URL("../src/index.ts", import.meta.url));
const helperBin = fileURLToPath(
  new URL("../../helper-macos/.build/debug/acro-helper", import.meta.url),
);

const env = {
  ...process.env,
  ACRO_STATE_DIR: stateDir,
  ACRO_PORT: String(PORT),
  ACRO_PAIR_CODE: PAIR_CODE,
  ACRO_PROJECT_ROOTS: stateDir,
  ACRO_HELPER_SOCKET: path.join(stateDir, "helper.sock"),
};

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

async function main(): Promise<void> {
  assert.ok(fs.existsSync(helperBin), "build helper first: swift build in apps/helper-macos");
  const helper: ChildProcess = spawn(helperBin, [], { env, stdio: "ignore" });
  const runtime: ChildProcess = spawn(process.execPath, [runtimeEntry], {
    env,
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
    const { token } = (await (
      await fetch(`http://127.0.0.1:${PORT}/pair`, {
        method: "POST",
        body: JSON.stringify({ code: PAIR_CODE, deviceName: "e2e-computer" }),
      })
    ).json()) as { token: string };

    const ws = new WebSocket(`ws://127.0.0.1:${PORT}/ws?token=${token}`);
    await new Promise<void>((resolve, reject) => {
      ws.on("open", () => resolve());
      ws.on("error", reject);
    });
    let nextId = 1;
    const pending = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
    ws.on("message", (raw: Buffer, isBinary: boolean) => {
      if (isBinary) return;
      const msg = JSON.parse(raw.toString("utf8"));
      if (msg.t !== "res") return;
      const p = pending.get(msg.id);
      if (!p) return;
      pending.delete(msg.id);
      if (msg.ok) p.resolve(msg.result);
      else p.reject(new Error(`${msg.error.code}: ${msg.error.message}`));
    });
    const rpc = <T = any>(method: string, params: unknown = {}): Promise<T> => {
      const id = nextId++;
      ws.send(JSON.stringify({ t: "req", id, method, params }));
      return new Promise<T>((resolve, reject) => {
        pending.set(id, { resolve, reject });
        setTimeout(() => {
          if (pending.delete(id)) reject(new Error(`rpc timeout: ${method}`));
        }, 15000);
      });
    };

    const perms = await rpc<{ accessibility: boolean; screenRecording: boolean }>(
      "computer.permissions",
    );
    assert.equal(typeof perms.accessibility, "boolean");
    assert.equal(typeof perms.screenRecording, "boolean");
    console.log(`[e2e] permissions: ax=${perms.accessibility} screen=${perms.screenRecording}`);

    const { windows } = await rpc<{ windows: unknown[] }>("computer.windows");
    assert.ok(Array.isArray(windows) && windows.length > 0, "window list must be non-empty");
    console.log(`[e2e] windows: ${windows.length}`);

    ws.close();
    console.log("\nE2E-COMPUTER PASS ✅  helper 链路(permissions/window.list)通过");
  } finally {
    runtime.kill("SIGTERM");
    helper.kill("SIGTERM");
    await sleep(300);
    try {
      const meta = JSON.parse(fs.readFileSync(path.join(stateDir, "daemon.meta.json"), "utf8"));
      process.kill(meta.pid, "SIGTERM");
    } catch {
      // daemon 未启动
    }
    fs.rmSync(stateDir, { recursive: true, force: true });
  }
}

main().catch((err) => {
  console.error("E2E-COMPUTER FAIL ❌", err);
  process.exit(1);
});
