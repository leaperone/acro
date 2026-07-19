// 浏览器表面端到端:开页面 → attach 收 screencast JPEG 帧 → 输入 → 导航 → 关闭。
// ACRO_BROWSER_HEADLESS=1 无头运行。

import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { decodePairingOffer, FRAME_BROWSER } from "@acro/protocol";
import { E2eClient } from "./e2e-client.ts";

const PORT = 18791;
const PAGE_PORT = 18792;
const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), "acro-e2e-browser-"));
const runtimeEntry = fileURLToPath(new URL("../src/index.ts", import.meta.url));

const env = {
  ...process.env,
  ACRO_STATE_DIR: stateDir,
  ACRO_PORT: String(PORT),
  ACRO_BROWSER_HEADLESS: "1",
};

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

async function main(): Promise<void> {
  // 假 dev server:模拟项目里的 localhost 服务
  let resolveAbandonedNavigation!: () => void;
  const abandonedNavigation = new Promise<void>((resolve) => {
    resolveAbandonedNavigation = resolve;
  });
  let resolveTakeoverNavigation!: () => void;
  const takeoverNavigation = new Promise<void>((resolve) => {
    resolveTakeoverNavigation = resolve;
  });
  let resolveInterruptedOpen!: () => void;
  const interruptedOpenRequest = new Promise<void>((resolve) => {
    resolveInterruptedOpen = resolve;
  });
  const page = http.createServer((req, res) => {
    if (req.url === "/abandoned-slow") {
      resolveAbandonedNavigation();
      setTimeout(() => {
        res.writeHead(200, { "content-type": "text/html" });
        res.end("<h1>ABANDONED SLOW</h1>");
      }, 300);
      return;
    }
    if (req.url === "/takeover-slow") {
      resolveTakeoverNavigation();
      setTimeout(() => {
        res.writeHead(200, { "content-type": "text/html" });
        res.end("<h1>TAKEOVER SLOW</h1>");
      }, 300);
      return;
    }
    if (req.url === "/open-slow") {
      resolveInterruptedOpen();
      setTimeout(() => {
        res.writeHead(200, { "content-type": "text/html" });
        res.end("<h1>OPEN SLOW</h1>");
      }, 300);
      return;
    }
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
    const offer = decodePairingOffer(
      fs.readFileSync(path.join(stateDir, "bootstrap-offer.txt"), "utf8").trim(),
    );
    const client = new E2eClient();
    await client.connect(offer);
    const rpc = <T = any>(method: string, params: unknown = {}) =>
      client.rpc<T>(method, params, 30000);

    // 冷启动并发 open 必须复用同一个 persistent context,不能争抢 profile 锁
    const [{ browserId }, { browserId: secondBrowserId }] = await Promise.all([
      rpc<{ browserId: string }>("browser.open", {
        url: `http://127.0.0.1:${PAGE_PORT}/`,
        width: 800,
        height: 600,
      }),
      rpc<{ browserId: string }>("browser.open", {
        url: `http://127.0.0.1:${PAGE_PORT}/second`,
        width: 640,
        height: 480,
      }),
    ]);
    console.log("[e2e] concurrent browser open ok");

    const controls = await rpc<Array<{ browserId: string; deviceId: string }>>(
      "browser.controlList",
    );
    assert.equal(
      controls.find((control) => control.browserId === browserId)?.deviceId,
      client.deviceId,
    );

    const attach = await rpc<{ channel: number; width: number }>("browser.attach", {
      browserId,
    });
    assert.equal(attach.width, 800);

    // 至少收到一帧合法 JPEG
    const jpeg = Buffer.from((await client.waitFrame(FRAME_BROWSER)).data);
    assert.ok(jpeg[0] === 0xff && jpeg[1] === 0xd8, "frame must be JPEG");
    console.log(`[e2e] received screencast frame, ${jpeg.length}B`);

    // 输入:点击输入框并打字(页面接受即可,验证输入链路不报错)
    await rpc("browser.input", {
      browserId,
      event: { kind: "click", x: 100, y: 200 },
    });
    await rpc("browser.input", {
      browserId,
      event: { kind: "type", text: "hello" },
    });
    console.log("[e2e] input ok");

    // 多设备可以同时查看,但非控制设备不能输入、导航或关闭;接管必须显式 force。
    const seatShare = await rpc<{ offer: string }>("device.share", {
      name: "browser-seat",
    });
    let seat = new E2eClient();
    await seat.connect(decodePairingOffer(seatShare.offer));
    const seatAttach = await seat.rpc<{ channel: number }>("browser.attach", { browserId });
    assert.equal(seatAttach.channel, attach.channel);
    await assert.rejects(
      seat.rpc("browser.input", {
        browserId,
        event: { kind: "click", x: 100, y: 200 },
      }),
      /browser controlled by another device/,
    );
    await assert.rejects(
      seat.rpc("browser.navigate", {
        browserId,
        url: `http://127.0.0.1:${PAGE_PORT}/second`,
      }),
      /browser controlled by another device/,
    );
    await assert.rejects(
      seat.rpc("browser.close", { browserId }),
      /browser controlled by another device/,
    );
    assert.deepEqual(
      await seat.rpc("browser.claimControl", { browserId }),
      { claimed: false },
    );

    // 排队等待的接管请求若设备先断线,执行时必须失败,不能登记脏 owner。
    const abandonedSlowNavigation = rpc<{ url: string }>("browser.navigate", {
      browserId,
      url: `http://127.0.0.1:${PAGE_PORT}/abandoned-slow`,
    });
    await abandonedNavigation;
    const abandonedClaim = seat.rpc("browser.claimControl", { browserId, force: true });
    await sleep(50);
    seat.close();
    await assert.rejects(abandonedClaim, /connection closed/);
    assert.ok((await abandonedSlowNavigation).url.endsWith("/abandoned-slow"));
    await sleep(50);
    assert.equal(
      (await rpc<Array<{ browserId: string; deviceId: string }>>("browser.controlList")).find(
        (control) => control.browserId === browserId,
      )?.deviceId,
      client.deviceId,
    );

    seat = new E2eClient();
    await seat.connect(decodePairingOffer(seatShare.offer));
    await seat.rpc("browser.attach", { browserId });
    const slowNavigation = rpc<{ url: string }>("browser.navigate", {
      browserId,
      url: `http://127.0.0.1:${PAGE_PORT}/takeover-slow`,
    });
    await takeoverNavigation;
    let takeoverResolved = false;
    const takeover = seat
      .rpc<{ claimed: boolean }>("browser.claimControl", { browserId, force: true })
      .then((result) => {
        takeoverResolved = true;
        return result;
      });
    await sleep(50);
    assert.equal(takeoverResolved, false, "takeover must wait for the old owner's operation");
    assert.ok((await slowNavigation).url.endsWith("/takeover-slow"));
    assert.deepEqual(await takeover, { claimed: true });
    assert.ok(
      client.events.some(
        (event) =>
          event.event === "browser.controlChanged" &&
          event.payload.browserId === browserId &&
          event.payload.deviceId === seat.deviceId,
      ),
      "takeover must broadcast browser.controlChanged",
    );

    // 导航
    await assert.rejects(
      rpc("browser.navigate", {
        browserId,
        url: `http://127.0.0.1:${PAGE_PORT}/second`,
      }),
      /browser controlled by another device/,
    );
    const nav = await seat.rpc<{ url: string }>("browser.navigate", {
      browserId,
      url: `http://127.0.0.1:${PAGE_PORT}/second`,
    });
    assert.ok(nav.url.endsWith("/second"));
    const list = await rpc<Array<{ browserId: string; url: string }>>("browser.list");
    assert.equal(list.length, 2);
    assert.ok(list.find((item) => item.browserId === browserId)?.url.endsWith("/second"));
    console.log("[e2e] navigate ok");

    // open 尚在导航时断线,新页面必须回滚;已有控制权也要在最后一条连接断开后释放。
    const interruptedOpen = seat.rpc("browser.open", {
      url: `http://127.0.0.1:${PAGE_PORT}/open-slow`,
    });
    await interruptedOpenRequest;
    seat.close();
    await assert.rejects(interruptedOpen, /connection closed/);
    const cleanupDeadline = Date.now() + 5000;
    let remainingBrowsers = await rpc<any[]>("browser.list");
    while (remainingBrowsers.length !== 2 && Date.now() < cleanupDeadline) {
      await sleep(50);
      remainingBrowsers = await rpc<any[]>("browser.list");
    }
    assert.equal(remainingBrowsers.length, 2, "interrupted browser.open must roll back its page");
    assert.ok(
      client.events.some(
        (event) =>
          event.event === "browser.controlChanged" &&
          event.payload.browserId === browserId &&
          event.payload.deviceId === null,
      ),
      "disconnect must release browser control",
    );
    assert.equal(
      (await rpc<Array<{ browserId: string }>>("browser.controlList")).some(
        (control) => control.browserId === browserId,
      ),
      false,
    );
    assert.deepEqual(
      await rpc("browser.claimControl", { browserId }),
      { claimed: true },
    );

    await rpc("browser.close", { browserId });
    await rpc("browser.close", { browserId: secondBrowserId });
    assert.equal((await rpc<any[]>("browser.list")).length, 0);
    assert.equal((await rpc<any[]>("browser.controlList")).length, 0);
    client.close();
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
