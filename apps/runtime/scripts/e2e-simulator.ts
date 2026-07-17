// 模拟器表面端到端:list → boot → attach 收 PNG 帧 → shutdown。
// 需要本机安装 Xcode 模拟器;boot 较慢,超时放宽。

import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";
import { decodeFrame, FRAME_SIM } from "@acro/protocol";

const PORT = 18793;
const PAIR_CODE = "E2ESIMULATOR";
const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), "acro-e2e-sim-"));
const runtimeEntry = fileURLToPath(new URL("../src/index.ts", import.meta.url));

const env = {
  ...process.env,
  ACRO_STATE_DIR: stateDir,
  ACRO_PORT: String(PORT),
  ACRO_PAIR_CODE: PAIR_CODE,
  ACRO_PROJECT_ROOTS: stateDir,
};

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

async function main(): Promise<void> {
  const runtime: ChildProcess = spawn(process.execPath, [runtimeEntry], {
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  runtime.stderr!.on("data", (d: Buffer) => process.stderr.write(`[runtime!] ${d}`));

  let bootedUdid: string | null = null;
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
        body: JSON.stringify({ code: PAIR_CODE, deviceName: "e2e-sim" }),
      })
    ).json()) as { token: string };

    const ws = new WebSocket(`ws://127.0.0.1:${PORT}/ws?token=${token}`);
    await new Promise<void>((resolve, reject) => {
      ws.on("open", () => resolve());
      ws.on("error", reject);
    });
    let nextId = 1;
    const pending = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
    const frames: Buffer[] = [];
    ws.on("message", (raw: Buffer, isBinary: boolean) => {
      if (isBinary) {
        const frame = decodeFrame(raw);
        if (frame.type === FRAME_SIM) frames.push(Buffer.from(frame.data));
        return;
      }
      const msg = JSON.parse(raw.toString("utf8"));
      if (msg.t !== "res") return;
      const p = pending.get(msg.id);
      if (!p) return;
      pending.delete(msg.id);
      if (msg.ok) p.resolve(msg.result);
      else p.reject(new Error(`${msg.error.code}: ${msg.error.message}`));
    });
    const rpc = <T = any>(method: string, params: unknown = {}, timeoutMs = 180000): Promise<T> => {
      const id = nextId++;
      ws.send(JSON.stringify({ t: "req", id, method, params }));
      return new Promise<T>((resolve, reject) => {
        pending.set(id, { resolve, reject });
        setTimeout(() => {
          if (pending.delete(id)) reject(new Error(`rpc timeout: ${method}`));
        }, timeoutMs);
      });
    };

    const devices = await rpc<Array<{ udid: string; name: string; state: string }>>(
      "simulator.list",
    );
    assert.ok(devices.length > 0, "must have at least one simulator");
    const target = devices.find((d) => d.state === "Booted") ?? devices.find((d) => d.name.includes("iPhone"))!;
    assert.ok(target, "need an iPhone simulator");
    console.log(`[e2e] target: ${target.name} (${target.state})`);

    if (target.state !== "Booted") {
      const boot = await rpc<{ state: string }>("simulator.boot", { udid: target.udid });
      assert.equal(boot.state, "Booted");
      bootedUdid = target.udid;
      console.log("[e2e] booted");
    }

    const attach = await rpc<{ channel: number }>("simulator.attach", { udid: target.udid });
    assert.ok(attach.channel >= 1);
    const frameDeadline = Date.now() + 30000;
    while (frames.length === 0 && Date.now() < frameDeadline) await sleep(300);
    assert.ok(frames.length > 0, "must receive simulator frames");
    const png = frames[0]!;
    assert.ok(png[0] === 0x89 && png[1] === 0x50, "frame must be PNG");
    console.log(`[e2e] received ${frames.length} sim frame(s), first ${png.length}B`);

    await rpc("simulator.detach", { udid: target.udid });
    if (bootedUdid) {
      await rpc("simulator.shutdown", { udid: bootedUdid });
      console.log("[e2e] shutdown");
    }
    ws.close();
    console.log("\nE2E-SIMULATOR PASS ✅  list/boot/画面流/shutdown 全部通过");
  } finally {
    runtime.kill("SIGTERM");
    await sleep(500);
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
  console.error("E2E-SIMULATOR FAIL ❌", err);
  process.exit(1);
});
