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
import { FrameReader, KIND_JSON, packJson } from "../src/daemon/wire.ts";

const PORT = 18795;
const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), "acro-e2e-computer-"));
const runtimeEntry = fileURLToPath(new URL("../src/index.ts", import.meta.url));
const helperBin = fileURLToPath(
  new URL("../../helper-macos/.build/debug/acro-helper", import.meta.url),
);
const permissionsStartedMarker = path.join(stateDir, "permissions-started");
const permissionsFinishedMarker = path.join(stateDir, "permissions-finished");

const env = {
  ...process.env,
  ACRO_STATE_DIR: stateDir,
  ACRO_PORT: String(PORT),
  ACRO_HELPER_SOCKET: path.join(stateDir, "helper.sock"),
  ACRO_HELPER_TESTING: "1",
  ACRO_DAEMON_TESTING: "1",
  ACRO_HELPER_TEST_PERMISSIONS_DELAY_MS: "300",
  ACRO_HELPER_TEST_PERMISSIONS_STARTED_MARKER: permissionsStartedMarker,
  ACRO_HELPER_TEST_PERMISSIONS_FINISHED_MARKER: permissionsFinishedMarker,
};

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

async function stopChild(child: ChildProcess): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return;
  child.kill("SIGTERM");
  const deadline = Date.now() + 3000;
  while (child.exitCode === null && child.signalCode === null && Date.now() < deadline) {
    await sleep(20);
  }
}

function daemonAcceptingConnections(socketPath: string): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = net.connect(socketPath);
    const done = (accepting: boolean) => {
      socket.destroy();
      resolve(accepting);
    };
    socket.once("connect", () => done(true));
    socket.once("error", () => done(false));
  });
}

function daemonRequest<T>(socketPath: string, method: string, params: unknown): Promise<T> {
  return new Promise((resolve, reject) => {
    const socket = net.connect(socketPath);
    const reader = new FrameReader();
    let settled = false;
    const finish = (error?: Error, result?: T) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      if (error) reject(error);
      else resolve(result as T);
    };
    const timer = setTimeout(() => finish(new Error(`daemon timeout: ${method}`)), 2000);
    socket.on("connect", () => {
      socket.write(packJson({ t: "req", id: 1, method, params }));
    });
    socket.on("data", (chunk) => {
      try {
        for (const message of reader.push(chunk)) {
          if (message.kind !== KIND_JSON) continue;
          const response = JSON.parse(message.body.toString("utf8")) as {
            t: string;
            id: number;
            ok: boolean;
            result?: T;
            error?: { message?: string };
          };
          if (response.t !== "res" || response.id !== 1) continue;
          if (response.ok) finish(undefined, response.result);
          else finish(new Error(response.error?.message ?? "daemon error"));
        }
      } catch (error) {
        finish(error as Error);
      }
    });
    socket.on("error", (error) => finish(error));
    socket.on("close", () => finish(new Error("daemon connection closed")));
  });
}

async function stopTestDaemon(): Promise<void> {
  const metaPath = path.join(stateDir, "daemon.meta.json");
  if (!fs.existsSync(metaPath)) return;
  const meta = JSON.parse(fs.readFileSync(metaPath, "utf8")) as { boot: string };
  const socketPath = path.join(stateDir, "daemon.sock");
  if (!(await daemonAcceptingConnections(socketPath))) return;
  await daemonRequest(socketPath, "daemon.shutdown", { boot: meta.boot });
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline && (await daemonAcceptingConnections(socketPath))) {
    await sleep(20);
  }
  assert.equal(await daemonAcceptingConnections(socketPath), false, "test daemon did not exit");
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

async function verifyCrossConnectionSerialization(): Promise<void> {
  const first = net.connect(env.ACRO_HELPER_SOCKET);
  await new Promise<void>((resolve, reject) => {
    first.once("connect", resolve);
    first.once("error", reject);
  });
  first.write(
    `${JSON.stringify({ id: 3, method: "ping", params: { delayMs: 300 } })}\n`,
  );
  await sleep(50);
  first.destroy();

  const startedAt = Date.now();
  const second = await rawHelperRequest({ id: 4, method: "ping", params: {} });
  const elapsedMs = Date.now() - startedAt;
  assert.equal(second.ok, true);
  assert.ok(elapsedMs >= 150, `new helper connection overlapped old handler (${elapsedMs}ms)`);
}

async function verifyBlockedResponseDoesNotHoldGate(): Promise<void> {
  const marker = path.join(stateDir, "large-response-started");
  const first = net.connect(env.ACRO_HELPER_SOCKET);
  first.on("error", () => {});
  await new Promise<void>((resolve, reject) => {
    first.once("connect", resolve);
    first.once("error", reject);
  });
  try {
    first.write(
      `${JSON.stringify({
        id: 5,
        method: "ping",
        params: { markerPath: marker, responseBytes: 8 * 1024 * 1024 },
      })}\n`,
    );
    const deadline = Date.now() + 2000;
    while (Date.now() < deadline && !fs.existsSync(marker)) await sleep(5);
    assert.equal(fs.existsSync(marker), true, "large helper response did not start");
    const second = await Promise.race([
      rawHelperRequest({ id: 6, method: "ping", params: {} }),
      sleep(750).then(() => {
        throw new Error("blocked helper response held the global request gate");
      }),
    ]);
    assert.equal(second.ok, true);
  } finally {
    first.destroy();
  }
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
    let healthy = false;
    while (Date.now() < deadline) {
      try {
        if ((await fetch(`http://127.0.0.1:${PORT}/health`)).ok) {
          healthy = true;
          break;
        }
      } catch {
        await sleep(150);
      }
    }
    assert.equal(healthy, true, "runtime health endpoint did not become ready");
    const bootstrapPath = path.join(stateDir, "bootstrap-offer.txt");
    while (Date.now() < deadline && !fs.existsSync(bootstrapPath)) await sleep(10);
    assert.equal(fs.existsSync(bootstrapPath), true, "runtime did not create bootstrap offer");
    while (Date.now() < deadline && !fs.existsSync(env.ACRO_HELPER_SOCKET)) await sleep(10);
    assert.equal(fs.existsSync(env.ACRO_HELPER_SOCKET), true, "helper socket did not become ready");
    const offer = decodePairingOffer(
      fs.readFileSync(bootstrapPath, "utf8").trim(),
    );
    assert.equal(fs.statSync(stateDir).mode & 0o777, 0o700);
    assert.equal(fs.statSync(path.join(stateDir, "helper.sock")).mode & 0o777, 0o600);
    await sendOversizedRequest();
    await verifyCrossConnectionSerialization();
    await verifyBlockedResponseDoesNotHoldGate();
    const invalidKey = await rawHelperRequest({
      id: 1,
      method: "input.key",
      params: { keyCode: -1 },
    });
    assert.equal(invalidKey.ok, false);
    assert.match(invalidKey.error ?? "", /keyCode out of range/);
    const revokedClient = new E2eClient();
    await revokedClient.connect(offer);
    const shared = await revokedClient.rpc<{ offer: string; deviceId: string }>("device.share", {
      name: "revoker",
      extraEndpoints: [`127.0.0.1:${PORT}`],
    });
    const activeClient = new E2eClient();
    await activeClient.connect(decodePairingOffer(shared.offer));

    const revokedRequest = revokedClient
      .rpc<{ accessibility: boolean; screenRecording: boolean }>("computer.permissions", {}, 2000)
      .then(
        () => ({ ok: true as const, error: null }),
        (error: Error) => ({ ok: false as const, error }),
      );
    const permissionsDeadline = Date.now() + 2000;
    while (Date.now() < permissionsDeadline && !fs.existsSync(permissionsStartedMarker)) {
      await sleep(5);
    }
    assert.equal(
      fs.existsSync(permissionsStartedMarker),
      true,
      "revoked device request never entered helper",
    );
    await activeClient.rpc("device.revoke", { deviceId: revokedClient.deviceId });
    const perms = await activeClient.rpc<{
      accessibility: boolean;
      screenRecording: boolean;
    }>("computer.permissions", {}, 2000);
    const revokedResult = await revokedRequest;
    assert.equal(revokedResult.ok, false);
    assert.match(revokedResult.error?.message ?? "", /connection closed/);
    assert.equal(
      fs.existsSync(permissionsFinishedMarker),
      true,
      "revoker completed before revoked helper handler released the gate",
    );
    assert.equal(typeof perms.accessibility, "boolean");
    assert.equal(typeof perms.screenRecording, "boolean");
    console.log(`[e2e] permissions: ax=${perms.accessibility} screen=${perms.screenRecording}`);

    const { windows } = await activeClient.rpc<{ windows: unknown[] }>("computer.windows");
    assert.ok(Array.isArray(windows) && windows.length > 0, "window list must be non-empty");
    console.log(`[e2e] windows: ${windows.length}`);

    // Computer Use 全局控制权:读操作共享,写操作单设备独占,显式 force 才能接管。
    const missingBundle = "invalid.acro.e2e.019f7830";
    assert.equal(await activeClient.rpc("computer.controlOwner"), null);
    await assert.rejects(
      activeClient.rpc("computer.activate", { bundleId: missingBundle }),
      /computer control is not claimed/,
    );
    assert.deepEqual(await activeClient.rpc("computer.claimControl"), { claimed: true });
    assert.deepEqual(
      await activeClient.rpc("computer.activate", { bundleId: missingBundle }),
      { activated: false },
    );
    assert.equal(
      (await activeClient.rpc<{ deviceId: string } | null>("computer.controlOwner"))?.deviceId,
      activeClient.deviceId,
    );
    const controlShare = await activeClient.rpc<{ offer: string }>("device.share", {
      name: "computer-seat",
      extraEndpoints: [`127.0.0.1:${PORT}`],
    });
    const controlSeat = new E2eClient();
    await controlSeat.connect(decodePairingOffer(controlShare.offer));
    const controlSeatMirror = new E2eClient();
    await controlSeatMirror.connect(decodePairingOffer(controlShare.offer));
    assert.equal(controlSeatMirror.deviceId, controlSeat.deviceId);
    assert.ok(
      Array.isArray((await controlSeat.rpc<{ windows: unknown[] }>("computer.windows")).windows),
    );
    await assert.rejects(
      controlSeat.rpc("computer.activate", { bundleId: missingBundle }),
      /computer controlled by another device/,
    );
    assert.deepEqual(await controlSeat.rpc("computer.claimControl"), { claimed: false });
    assert.deepEqual(
      await controlSeat.rpc("computer.claimControl", { force: true }),
      { claimed: true },
    );
    await assert.rejects(
      activeClient.rpc("computer.activate", { bundleId: missingBundle }),
      /computer controlled by another device/,
    );
    assert.deepEqual(
      await controlSeat.rpc("computer.activate", { bundleId: missingBundle }),
      { activated: false },
    );
    assert.ok(
      activeClient.events.some(
        (event) =>
          event.event === "computer.controlChanged" &&
          event.payload.deviceId === controlSeat.deviceId,
      ),
      "takeover must broadcast computer.controlChanged",
    );
    controlSeat.close();
    await sleep(200);
    assert.equal(
      (await activeClient.rpc<{ deviceId: string } | null>("computer.controlOwner"))?.deviceId,
      controlSeatMirror.deviceId,
      "one remaining connection must retain computer control",
    );
    assert.deepEqual(
      await controlSeatMirror.rpc("computer.activate", { bundleId: missingBundle }),
      { activated: false },
    );
    controlSeatMirror.close();
    await sleep(500);
    assert.equal(await activeClient.rpc("computer.controlOwner"), null);
    assert.ok(
      activeClient.events.some(
        (event) => event.event === "computer.controlChanged" && event.payload.deviceId === null,
      ),
      "disconnect must release computer control",
    );
    await assert.rejects(
      activeClient.rpc("computer.activate", { bundleId: missingBundle }),
      /computer control is not claimed/,
    );
    assert.deepEqual(await activeClient.rpc("computer.claimControl"), { claimed: true });
    assert.deepEqual(
      await activeClient.rpc("computer.activate", { bundleId: missingBundle }),
      { activated: false },
    );
    assert.equal(
      (await activeClient.rpc<{ deviceId: string } | null>("computer.controlOwner"))?.deviceId,
      activeClient.deviceId,
    );

    await revokedClient.waitClosed();
    activeClient.close();
    console.log("\nE2E-COMPUTER PASS ✅  helper 链路(permissions/window.list)通过");
  } finally {
    await Promise.all([stopChild(runtime), stopChild(helper)]);
    await stopTestDaemon();
    fs.rmSync(stateDir, { recursive: true, force: true });
  }
}

main().catch((err) => {
  console.error("E2E-COMPUTER FAIL ❌", err);
  process.exit(1);
});
