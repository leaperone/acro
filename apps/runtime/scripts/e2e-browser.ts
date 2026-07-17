// 浏览器表面端到端:开页面 → attach 收 screencast JPEG 帧 → 输入 → 导航 → 关闭。
// ACRO_BROWSER_HEADLESS=1 无头运行。

import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";
import { decodeFrame, encodeInFrame, FRAME_BROWSER } from "@acro/protocol";

const PORT = 18791;
const PAGE_PORT = 18792;
const PAIR_CODE = "E2EBROWSER1";
const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), "acro-e2e-browser-"));
const runtimeEntry = fileURLToPath(new URL("../src/index.ts", import.meta.url));

const env = {
  ...process.env,
  ACRO_STATE_DIR: stateDir,
  ACRO_PORT: String(PORT),
  ACRO_PAIR_CODE: PAIR_CODE,
  ACRO_PROJECT_ROOTS: stateDir,
  ACRO_BROWSER_HEADLESS: "1",
};

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

async function main(): Promise<void> {
  // 假 dev server:模拟项目里的 localhost 服务
  const page = http.createServer((req, res) => {
    res.writeHead(200, { "content-type": "text/html" });
    res.end(
      req.url === "/second"
        ? "<h1 style='font-size:120px'>SECOND</h1>"
        : "<h1 style='font-size:120px'>ACRO</h1><input id='box' style='font-size:60px'>",
    );
  });
  page.listen(PAGE_PORT);

  const runtime: ChildProcess = spawn(process.execPath, [runtimeEntry], {
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  runtime.stdout!.on("data", (d: Buffer) => process.stdout.write(`[runtime] ${d}`));
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
    const pairRes = await fetch(`http://127.0.0.1:${PORT}/pair`, {
      method: "POST",
      body: JSON.stringify({ code: PAIR_CODE, deviceName: "e2e-browser" }),
    });
    const { token } = (await pairRes.json()) as { token: string };

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
        if (frame.type === FRAME_BROWSER) frames.push(Buffer.from(frame.data));
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
    const rpc = <T = any>(method: string, params: unknown = {}): Promise<T> => {
      const id = nextId++;
      ws.send(JSON.stringify({ t: "req", id, method, params }));
      return new Promise<T>((resolve, reject) => {
        pending.set(id, { resolve, reject });
        setTimeout(() => {
          if (pending.delete(id)) reject(new Error(`rpc timeout: ${method}`));
        }, 30000);
      });
    };

    // 开浏览器指向假 dev server
    const { browserId } = await rpc<{ browserId: string }>("browser.open", {
      url: `http://127.0.0.1:${PAGE_PORT}/`,
      width: 800,
      height: 600,
    });
    console.log("[e2e] browser opened");

    const attach = await rpc<{ channel: number; width: number }>("browser.attach", { browserId });
    assert.equal(attach.width, 800);

    // 至少收到一帧合法 JPEG
    const frameDeadline = Date.now() + 15000;
    while (frames.length === 0 && Date.now() < frameDeadline) await sleep(200);
    assert.ok(frames.length > 0, "must receive screencast frames");
    const jpeg = frames[0]!;
    assert.ok(jpeg[0] === 0xff && jpeg[1] === 0xd8, "frame must be JPEG");
    console.log(`[e2e] received ${frames.length} screencast frame(s), first ${jpeg.length}B`);

    // 输入:点击输入框并打字(页面接受即可,验证输入链路不报错)
    await rpc("browser.input", { browserId, event: { kind: "click", x: 100, y: 200 } });
    await rpc("browser.input", { browserId, event: { kind: "type", text: "hello" } });
    console.log("[e2e] input ok");

    // 导航
    const nav = await rpc<{ url: string }>("browser.navigate", {
      browserId,
      url: `http://127.0.0.1:${PAGE_PORT}/second`,
    });
    assert.ok(nav.url.endsWith("/second"));
    const list = await rpc<Array<{ browserId: string; url: string }>>("browser.list");
    assert.equal(list.length, 1);
    assert.ok(list[0]!.url.endsWith("/second"));
    console.log("[e2e] navigate ok");

    await rpc("browser.close", { browserId });
    assert.equal((await rpc<any[]>("browser.list")).length, 0);
    ws.close();
    console.log("\nE2E-BROWSER PASS ✅  打开/取流/输入/导航/关闭 全部通过");
  } finally {
    runtime.kill("SIGTERM");
    page.close();
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
  console.error("E2E-BROWSER FAIL ❌", err);
  process.exit(1);
});
