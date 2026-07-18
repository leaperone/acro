// Computer Use 链路冒烟:helper(Swift) ← runtime ← WS 客户端。
// 只验证无需系统权限的方法(permissions.check / window.list)。

import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { decodePairingOffer } from "@acro/protocol";
import { E2eClient } from "./e2e-client.ts";

const PORT = 18795;
const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), "acro-e2e-computer-"));
const runtimeEntry = fileURLToPath(new URL("../src/index.ts", import.meta.url));
const helperBin = fileURLToPath(
  new URL("../../helper-macos/.build/debug/acro-helper", import.meta.url),
);

const env = {
  ...process.env,
  ACRO_STATE_DIR: stateDir,
  ACRO_PORT: String(PORT),
  ACRO_HELPER_SOCKET: path.join(stateDir, "helper.sock"),
};

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

function sendOversizedRequest(): Promise<void> {
  return new Promise((resolve, reject) => {
    const socket = net.connect(env.ACRO_HELPER_SOCKET);
    const timeout = setTimeout(() => {
      socket.destroy();
      reject(new Error("helper did not reject oversized request"));
    }, 5000);
    socket.on("connect", () => socket.write(Buffer.alloc(2 * 1024 * 1024 + 1, 0x61)));
    socket.on("close", () => {
      clearTimeout(timeout);
      resolve();
    });
    socket.on("error", reject);
  });
}

function rawHelperRequest(request: unknown): Promise<{ ok: boolean; error?: string }> {
  return new Promise((resolve, reject) => {
    const socket = net.connect(env.ACRO_HELPER_SOCKET);
    let buffer = "";
    socket.on("connect", () => socket.write(`${JSON.stringify(request)}\n`));
    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      const newline = buffer.indexOf("\n");
      if (newline < 0) return;
      socket.end();
      resolve(JSON.parse(buffer.slice(0, newline)) as { ok: boolean; error?: string });
    });
    socket.on("error", reject);
  });
}

function disconnectBeforeHelperResponse(): Promise<void> {
  return new Promise((resolve, reject) => {
    const socket = net.connect(env.ACRO_HELPER_SOCKET);
    socket.on("connect", () => {
      socket.write(`${JSON.stringify({ id: 2, method: "permissions.check", params: {} })}\n`);
      socket.destroy();
      resolve();
    });
    socket.on("error", reject);
  });
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
    const offer = decodePairingOffer(
      fs.readFileSync(path.join(stateDir, "bootstrap-offer.txt"), "utf8").trim(),
    );
    assert.equal(fs.statSync(stateDir).mode & 0o777, 0o700);
    assert.equal(fs.statSync(path.join(stateDir, "helper.sock")).mode & 0o777, 0o600);
    await sendOversizedRequest();
    const invalidKey = await rawHelperRequest({
      id: 1,
      method: "input.key",
      params: { keyCode: -1 },
    });
    assert.equal(invalidKey.ok, false);
    assert.match(invalidKey.error ?? "", /keyCode out of range/);
    await disconnectBeforeHelperResponse();
    await sleep(200);
    const client = new E2eClient();
    await client.connect(offer);
    const rpc = <T = any>(method: string, params: unknown = {}) =>
      client.rpc<T>(method, params, 15000);

    const perms = await rpc<{ accessibility: boolean; screenRecording: boolean }>(
      "computer.permissions",
    );
    assert.equal(typeof perms.accessibility, "boolean");
    assert.equal(typeof perms.screenRecording, "boolean");
    console.log(`[e2e] permissions: ax=${perms.accessibility} screen=${perms.screenRecording}`);

    const { windows } = await rpc<{ windows: unknown[] }>("computer.windows");
    assert.ok(Array.isArray(windows) && windows.length > 0, "window list must be non-empty");
    console.log(`[e2e] windows: ${windows.length}`);

    client.close();
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
