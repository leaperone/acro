// 模拟器表面端到端:list → boot → attach 收 PNG 帧 → shutdown。
// 需要本机安装 Xcode 模拟器;boot 较慢,超时放宽。

import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { decodePairingOffer, FRAME_SIM } from "@acro/protocol";
import { E2eClient } from "./e2e-client.ts";

const PORT = 18793;
const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), "acro-e2e-sim-"));
const runtimeEntry = fileURLToPath(new URL("../src/index.ts", import.meta.url));

const env = {
  ...process.env,
  ACRO_STATE_DIR: stateDir,
  ACRO_PORT: String(PORT),
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
    const offer = decodePairingOffer(
      fs.readFileSync(path.join(stateDir, "bootstrap-offer.txt"), "utf8").trim(),
    );
    const client = new E2eClient();
    await client.connect(offer);
    const rpc = <T = any>(method: string, params: unknown = {}) =>
      client.rpc<T>(method, params, 180000);

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

    const attach = await rpc<{ channel: number }>("simulator.attach", {
      udid: target.udid,
    });
    assert.ok(attach.channel >= 1);
    const png = Buffer.from((await client.waitFrame(FRAME_SIM, 30000)).data);
    assert.ok(png[0] === 0x89 && png[1] === 0x50, "frame must be PNG");
    console.log(`[e2e] received sim frame, ${png.length}B`);

    await rpc("simulator.detach", { udid: target.udid });
    if (bootedUdid) {
      await rpc("simulator.shutdown", { udid: bootedUdid });
      console.log("[e2e] shutdown");
    }
    client.close();
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
