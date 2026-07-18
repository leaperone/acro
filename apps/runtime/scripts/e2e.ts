// 端到端验证:配对 → Workspace → 项目 → 会话 → 断线重连 → Runtime 重启会话存活。
// 全部走真实进程和真实 WS,不 mock。失败即 assert 抛错。

import assert from "node:assert/strict";
import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  decodePairingOffer,
  type Session,
  type Workspace,
  type WorkspaceGroup,
} from "@acro/protocol";
import { E2eClient as Client } from "./e2e-client.ts";

const PORT = 18790;
const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), "acro-e2e-state-"));
const projectsRoot = fs.mkdtempSync(path.join(os.tmpdir(), "acro-e2e-projects-"));
const runtimeEntry = fileURLToPath(new URL("../src/index.ts", import.meta.url));

const env = {
  ...process.env,
  ACRO_STATE_DIR: stateDir,
  ACRO_PORT: String(PORT),
};

function log(msg: string): void {
  console.log(`[e2e] ${msg}`);
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

function makeFixtureRepo(): string {
  const repo = path.join(projectsRoot, "demo");
  fs.mkdirSync(repo);
  const git = (...args: string[]) =>
    execFileSync("git", ["-C", repo, "-c", "user.email=e2e@test", "-c", "user.name=e2e", ...args]);
  git("init", "-b", "main");
  fs.writeFileSync(path.join(repo, "README.md"), "# demo\n");
  git("add", ".");
  git("commit", "-m", "init");
  return repo;
}

function startRuntime(): ChildProcess {
  const child = spawn(process.execPath, [...process.execArgv, runtimeEntry], {
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  child.stdout!.on("data", (d: Buffer) => process.stdout.write(`[runtime] ${d}`));
  child.stderr!.on("data", (d: Buffer) => process.stderr.write(`[runtime!] ${d}`));
  return child;
}

async function waitHealthy(timeoutMs = 15000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`http://127.0.0.1:${PORT}/health`);
      if (res.ok) return;
    } catch {
      // not up yet
    }
    await sleep(150);
  }
  throw new Error("runtime did not become healthy");
}

async function main(): Promise<void> {
  fs.chmodSync(stateDir, 0o755);
  fs.mkdirSync(path.join(stateDir, "sessions"), { mode: 0o755 });
  const fixtureRepo = makeFixtureRepo();
  let runtime = startRuntime();

  try {
    await waitHealthy();
    log("runtime healthy");
    assert.equal(fs.statSync(stateDir).mode & 0o777, 0o700);
    assert.equal(fs.statSync(path.join(stateDir, "sessions")).mode & 0o777, 0o700);
    assert.equal(fs.statSync(path.join(stateDir, "daemon.sock")).mode & 0o777, 0o600);
    log("state permissions ok");

    const localOfferPath = path.join(stateDir, "local-offer.txt");
    assert.equal(fs.statSync(localOfferPath).mode & 0o777, 0o600);
    const localOffer = decodePairingOffer(fs.readFileSync(localOfferPath, "utf8").trim());
    assert.ok(localOffer.endpoints.includes(`127.0.0.1:${PORT}`));
    const localOfferResponse = await fetch(`http://127.0.0.1:${PORT}/local-offer`, {
      method: "POST",
    });
    assert.equal(localOfferResponse.status, 404);
    log("local offer file boundary ok");

    // 配对:首启的 bootstrap 配对码写在 state 目录
    const offerRaw = fs.readFileSync(path.join(stateDir, "bootstrap-offer.txt"), "utf8").trim();
    const offer = decodePairingOffer(offerRaw);
    assert.ok(offer.token.length >= 32);
    assert.ok(offer.endpoints.includes(`127.0.0.1:${PORT}`));
    log("bootstrap offer ok");

    // 错误 token 必须被断开
    await assert.rejects(
      new Client().connect(offer, "0".repeat(64)),
      "wrong token must be rejected",
    );

    let client = new Client();
    await client.connect(offer);
    assert.ok(client.deviceId.length > 0);
    log("e2ee ws connected");

    // 首个设备认证后 bootstrap 配对码文件必须被清理
    await sleep(200);
    assert.ok(!fs.existsSync(path.join(stateDir, "bootstrap-offer.txt")));

    // 授权管理:再 mint 一个,撤销后它的活动连接立即断开
    const share = await client.rpc<{ offer: string; deviceId: string }>("device.share", {
      name: "second-device",
      extraEndpoints: ["frp.example.com:7100"],
    });
    const shareOffer = decodePairingOffer(share.offer);
    assert.ok(shareOffer.endpoints.includes("frp.example.com:7100"));
    const second = new Client();
    await second.connect(shareOffer);
    assert.equal(second.deviceId, share.deviceId);
    const closedPromise = second.waitClosed();
    await client.rpc("device.revoke", { deviceId: share.deviceId });
    await closedPromise;
    // 被撤销的 token 不能再连
    await assert.rejects(new Client().connect(shareOffer), "revoked token must fail");
    log("share + revoke ok");

    const [workspace] = await client.rpc<Workspace[]>("workspace.list");
    assert.equal(workspace?.name, "工作区 1");
    const initialSession = (await client.rpc<Session[]>("session.list")).find((session) =>
      workspace?.sessionIds.includes(session.id),
    );
    assert.equal(initialSession?.alive, true, "first startup must create a live terminal");
    await client.rpc("session.kill", { sessionId: initialSession!.id });
    await sleep(500);
    client.close();
    runtime.kill("SIGTERM");
    await sleep(800);
    runtime = startRuntime();
    await waitHealthy();
    client = new Client();
    await client.connect(offer);
    const repairedWorkspace = (await client.rpc<Workspace[]>("workspace.list")).find(
      (item) => item.id === workspace?.id,
    );
    const repairedSession = (await client.rpc<Session[]>("session.list")).find(
      (session) => session.alive && repairedWorkspace?.sessionIds.includes(session.id),
    );
    assert.notEqual(repairedSession?.id, initialSession?.id);
    assert.equal(repairedSession?.alive, true, "startup must repair an empty workspace");
    await client.rpc("session.kill", { sessionId: repairedSession!.id });
    log("initial workspace + terminal repair ok");

    const workspaceGroup = await client.rpc<WorkspaceGroup>("workspaceGroup.create", {
      name: "E2E Group",
    });
    const updatedWorkspace = await client.rpc<Workspace>("workspace.update", {
      workspaceId: workspace!.id,
      name: "E2E",
      workspaceGroupId: workspaceGroup.id,
    });
    assert.deepEqual(
      (await client.rpc<WorkspaceGroup[]>("workspaceGroup.list"))[0]?.workspaceIds,
      [updatedWorkspace.id],
    );
    log("workspace updated");

    // 会话:显式 cwd 指到 fixture 仓库,跑 /bin/sh(避免用户 shell 配置噪音)
    const session = await client.rpc<Session>("session.create", {
      workspaceId: updatedWorkspace.id,
      cwd: fixtureRepo,
      command: "/bin/sh",
      cols: 80,
      rows: 24,
    });
    assert.equal(session.alive, true);
    assert.equal(session.cwd, fixtureRepo);

    const workspaceWithSession = (await client.rpc<Workspace[]>("workspace.list")).find(
      (item) => item.id === updatedWorkspace.id,
    );
    assert.ok(workspaceWithSession?.sessionIds.includes(session.id));
    await assert.rejects(
      client.rpc("workspace.remove", { workspaceId: updatedWorkspace.id }),
      /workspace has active sessions/,
    );

    const attach1 = await client.rpc<{ channel: number; snapshot: string; seq: number }>(
      "session.attach",
      { sessionId: session.id },
    );
    client.sendInput(attach1.channel, "echo MARK_${RANDOM}_ONE; pwd\n");
    client.sendInput(attach1.channel, "echo BEFORE_DISCONNECT_XYZ\n");
    await client.waitOutput("BEFORE_DISCONNECT_XYZ");
    await client.waitOutput(fixtureRepo); // pwd 确认跑在指定目录里
    log("session io ok");

    // attach 屏障:持续输出期间新连接拿到的 snapshot + live frames 必须连续不缺号
    const gapShare = await client.rpc<{ offer: string }>("device.share", {
      name: "attach-gap",
    });
    const gapClient = new Client();
    await gapClient.connect(decodePairingOffer(gapShare.offer));
    client.sendInput(
      attach1.channel,
      "i=1; while [ $i -le 600 ]; do printf 'ATTACH_GAP_%04d\\n' \"$i\"; i=$((i+1)); sleep 0.002; done\n",
    );
    await client.waitOutput("ATTACH_GAP_0001");
    const gapAttach = await gapClient.rpc<{ snapshot: string }>("session.attach", {
      sessionId: session.id,
    });
    await client.waitOutput("ATTACH_GAP_0600", 15000);
    await sleep(300);
    const gapCombined =
      Buffer.from(gapAttach.snapshot, "base64").toString("utf8") + gapClient.output;
    const gapNumbers = new Set(
      [...gapCombined.matchAll(/ATTACH_GAP_(\d{4})/g)].map((match) => Number(match[1])),
    );
    for (let i = 1; i <= 600; i += 1) {
      assert.ok(gapNumbers.has(i), `attach output missing sequence ${i}`);
    }
    gapClient.close();
    log("attach replay barrier ok");

    // 路径继承既定事实:源会话 cd 之后,不传 cwd 的新会话应落在它的实时目录
    client.sendInput(attach1.channel, "cd /private/tmp && echo CD_DONE_XYZ\n");
    await client.waitOutput("CD_DONE_XYZ");
    const inherited = await client.rpc<Session>("session.create", {
      workspaceId: updatedWorkspace.id,
      inheritCwdFrom: session.id,
      command: "/bin/sh",
      cols: 80,
      rows: 24,
    });
    assert.equal(inherited.cwd, "/private/tmp", "inherited session must start in source live cwd");
    await client.rpc("session.kill", { sessionId: inherited.id });
    log("cwd inheritance ok");

    // 终端占用锁:占用后其他设备输入被丢弃,显式接管后恢复,设备断开自动释放
    const seatShare = await client.rpc<{ offer: string; deviceId: string }>("device.share", {
      name: "second-seat",
    });
    const seat = new Client();
    await seat.connect(decodePairingOffer(seatShare.offer));
    await client.rpc("session.claimFocus", { sessionId: session.id });
    const owners = await client.rpc<Array<{ sessionId: string; deviceId: string }>>(
      "session.focusList",
    );
    assert.equal(owners.find((o) => o.sessionId === session.id)?.deviceId, client.deviceId);

    const seatAttach = await seat.rpc<{ channel: number }>("session.attach", {
      sessionId: session.id,
    });
    seat.sendInput(seatAttach.channel, "echo LOCKED_OUT_XYZ\n");
    await sleep(800);
    assert.ok(!seat.output.includes("LOCKED_OUT_XYZ"), "non-owner input must be dropped");

    // 非 force 拿不到别人手里的会话;显式接管必须 force
    const denied = await seat.rpc<{ claimed: boolean }>("session.claimFocus", {
      sessionId: session.id,
    });
    assert.equal(denied.claimed, false, "silent claim must not steal an owned session");
    await seat.rpc("session.claimFocus", { sessionId: session.id, force: true });
    seat.sendInput(seatAttach.channel, "echo TAKEN_OVER_XYZ\n");
    await seat.waitOutput("TAKEN_OVER_XYZ");
    assert.ok(
      client.events.some(
        (e) => e.event === "session.focusChanged" && e.payload.deviceId === seat.deviceId,
      ),
      "takeover must broadcast focusChanged",
    );

    // 占用设备断开 → 自动释放并广播 null
    seat.close();
    await sleep(500);
    assert.ok(
      client.events.some(
        (e) =>
          e.event === "session.focusChanged" &&
          e.payload.sessionId === session.id &&
          e.payload.deviceId === null,
      ),
      "disconnect must release the focus lock",
    );
    assert.equal((await client.rpc<unknown[]>("session.focusList")).length, 0);
    log("focus lock ok");

    // 尺寸仲裁:PTY = 各在挂客户端的最小值;小端断开后回涨
    const sizeSeatShare = await client.rpc<{ offer: string }>("device.share", {
      name: "size-seat",
    });
    const sizeSeat = new Client();
    await sizeSeat.connect(decodePairingOffer(sizeSeatShare.offer));
    await client.rpc("session.attach", { sessionId: session.id });
    await sizeSeat.rpc("session.attach", { sessionId: session.id });
    await client.rpc("session.resize", { sessionId: session.id, cols: 200, rows: 50 });
    await sizeSeat.rpc("session.resize", { sessionId: session.id, cols: 100, rows: 30 });
    const sized = (await client.rpc<Session[]>("session.list")).find((s) => s.id === session.id);
    assert.equal(sized?.cols, 100, "pty cols must be the min across attached clients");
    assert.equal(sized?.rows, 30, "pty rows must be the min across attached clients");
    sizeSeat.close();
    await sleep(500);
    const regrown = (await client.rpc<Session[]>("session.list")).find((s) => s.id === session.id);
    assert.equal(regrown?.cols, 200, "pty must regrow after the smaller client leaves");
    assert.equal(regrown?.rows, 50, "pty must regrow after the smaller client leaves");
    log("resize arbitration ok");

    // 断开重连:会话必须还在,快照必须包含断开前的输出,且不重发旧帧
    client.close();
    await sleep(500);
    const client2 = new Client();
    await client2.connect(offer);
    const attach2 = await client2.rpc<{ channel: number; snapshot: string; seq: number }>(
      "session.attach",
      { sessionId: session.id },
    );
    const snapshot2 = Buffer.from(attach2.snapshot, "base64").toString("utf8");
    assert.ok(
      snapshot2.includes("BEFORE_DISCONNECT_XYZ"),
      "snapshot must contain output from before disconnect",
    );
    client2.sendInput(attach2.channel, "echo AFTER_RECONNECT_XYZ\n");
    await client2.waitOutput("AFTER_RECONNECT_XYZ");
    assert.ok(
      !client2.output.includes("BEFORE_DISCONNECT_XYZ"),
      "old output must come from snapshot, not replayed frames",
    );
    log("reconnect ok");

    // Runtime 重启:daemon 独立存活,会话不受影响
    client2.close();
    runtime.kill("SIGTERM");
    await sleep(800);
    runtime = startRuntime();
    await waitHealthy();
    const client3 = new Client();
    await client3.connect(offer);
    const sessions = await client3.rpc<Session[]>("session.list");
    const survived = sessions.find((s) => s.id === session.id);
    assert.ok(survived?.alive, "session must survive runtime restart");
    const restoredWorkspace = (await client3.rpc<Workspace[]>("workspace.list")).find(
      (item) => item.id === updatedWorkspace.id,
    );
    assert.ok(restoredWorkspace?.sessionIds.includes(session.id));
    const attach3 = await client3.rpc<{ channel: number; snapshot: string }>("session.attach", {
      sessionId: session.id,
    });
    const snapshot3 = Buffer.from(attach3.snapshot, "base64").toString("utf8");
    assert.ok(snapshot3.includes("AFTER_RECONNECT_XYZ"));
    client3.sendInput(attach3.channel, "echo AFTER_RUNTIME_RESTART_XYZ\n");
    await client3.waitOutput("AFTER_RUNTIME_RESTART_XYZ");
    client3.sendInput(attach3.channel, `cd ${stateDir} && echo CWD_UNAVAILABLE_XYZ\n`);
    await client3.waitOutput("CWD_UNAVAILABLE_XYZ");
    await assert.rejects(
      client3.rpc("session.create", {
        workspaceId: updatedWorkspace.id,
        inheritCwdFrom: session.id,
        command: "/bin/sh",
        cols: 80,
        rows: 24,
      }),
      /source terminal working directory is unavailable/,
    );
    client3.sendInput(attach3.channel, "cd /private/tmp && echo CWD_RESTORED_XYZ\n");
    await client3.waitOutput("CWD_RESTORED_XYZ");
    const inheritedAfterRestart = await client3.rpc<Session>("session.create", {
      workspaceId: updatedWorkspace.id,
      inheritCwdFrom: session.id,
      command: "/bin/sh",
      cols: 80,
      rows: 24,
    });
    assert.equal(
      inheritedAfterRestart.cwd,
      "/private/tmp",
      "cwd inheritance must survive a runtime restart with the same daemon",
    );
    await client3.rpc("session.kill", { sessionId: inheritedAfterRestart.id });
    log("runtime restart survival ok");

    // 真实 CLI attach:断线(runtime 重启)后必须自动重挂载,而不是退出
    const cliEntry = fileURLToPath(new URL("../../cli/src/cli.ts", import.meta.url));
    const cliConfig = path.join(stateDir, "cli-client.json");
    fs.writeFileSync(
      cliConfig,
      JSON.stringify({
        v: 2,
        servers: [
          {
            localId: "e2e-local",
            name: "e2e",
            deviceId: "",
            token: offer.token,
            pub: offer.pub,
            endpoints: offer.endpoints,
          },
        ],
        active: "e2e-local",
      }),
    );
    const cli = spawn(process.execPath, [...process.execArgv, cliEntry, "attach", session.id], {
      env: { ...env, ACRO_CLIENT_CONFIG: cliConfig },
      stdio: ["pipe", "pipe", "pipe"],
    });
    let cliOut = "";
    let cliErr = "";
    cli.stdout!.on("data", (d: Buffer) => {
      cliOut += d.toString("utf8");
    });
    cli.stderr!.on("data", (d: Buffer) => {
      cliErr += d.toString("utf8");
    });
    const waitCliOut = async (needle: string, timeoutMs = 20000): Promise<void> => {
      const deadline = Date.now() + timeoutMs;
      while (!cliOut.includes(needle)) {
        if (Date.now() > deadline) throw new Error(`cli output missing: ${needle}`);
        await sleep(200);
      }
    };
    await waitCliOut("AFTER_RUNTIME_RESTART_XYZ"); // 快照回放
    cli.stdin!.write("echo CLI_ATTACH_LIVE_XYZ\n");
    await waitCliOut("CLI_ATTACH_LIVE_XYZ");

    // 拔掉 runtime 再拉起:CLI 必须自己重连并恢复输入输出
    client3.close();
    runtime.kill("SIGTERM");
    await sleep(800);
    runtime = startRuntime();
    await waitHealthy();
    const reconnectedDeadline = Date.now() + 30000;
    for (;;) {
      cli.stdin!.write("echo CLI_AFTER_RECONNECT_XYZ\n");
      await sleep(1000);
      if (cliOut.includes("CLI_AFTER_RECONNECT_XYZ")) break;
      if (Date.now() > reconnectedDeadline) {
        throw new Error(`cli did not reattach; stderr: ${cliErr}`);
      }
    }
    assert.ok(cliErr.includes("重连"), "cli should report the reconnect on stderr");
    log("cli attach auto-reattach ok");

    const client4 = new Client();
    await client4.connect(offer);
    const cliExit = new Promise<number | null>((resolve) => cli.on("exit", resolve));

    // kill 会话 → exit 事件 → 列表标记死亡;附着中的 CLI 应随之干净退出
    await client4.rpc("session.kill", { sessionId: session.id });
    assert.equal(await cliExit, 0, "cli attach should exit cleanly on session exit");
    await sleep(800);
    assert.ok(
      client4.events.some((e) => e.event === "session.exit" && e.payload.sessionId === session.id),
      "must receive session.exit event",
    );
    const after = await client4.rpc<Session[]>("session.list");
    assert.equal(after.find((s) => s.id === session.id)?.alive, false);
    log("kill + exit event ok");

    const cleanupSession = await client4.rpc<Session>("session.create", {
      workspaceId: updatedWorkspace.id,
      command: "trap '' HUP; while true; do sleep 1; done",
      cols: 80,
      rows: 24,
    });
    await client4.rpc("workspace.remove", { workspaceId: updatedWorkspace.id, force: true });
    assert.equal((await client4.rpc<Workspace[]>("workspace.list")).length, 0);
    const afterRemoval = await client4.rpc<Session[]>("session.list");
    assert.equal(afterRemoval.some((item) => item.id === session.id), false);
    assert.equal(afterRemoval.some((item) => item.id === inherited.id), false);
    assert.equal(afterRemoval.some((item) => item.id === inheritedAfterRestart.id), false);
    assert.equal(afterRemoval.some((item) => item.id === cleanupSession.id), false);
    for (const sessionId of [
      session.id,
      inherited.id,
      inheritedAfterRestart.id,
      cleanupSession.id,
    ]) {
      assert.equal(fs.existsSync(path.join(stateDir, "sessions", sessionId)), false);
    }
    assert.ok(
      client4.events.some(
        (event) =>
          event.event === "workspace.removed" &&
          event.payload.workspaceId === updatedWorkspace.id,
      ),
      "must receive workspace.removed after cleanup",
    );
    await client4.rpc("workspaceGroup.remove", { workspaceGroupId: workspaceGroup.id });
    assert.equal((await client4.rpc<WorkspaceGroup[]>("workspaceGroup.list")).length, 0);
    client4.close();
    log("workspace removed");

    console.log("\nE2E PASS ✅  配对/Workspace/项目/会话/断线重连/Runtime重启存活 全部通过");
  } finally {
    runtime.kill("SIGTERM");
    // 杀掉测试 daemon
    try {
      const meta = JSON.parse(fs.readFileSync(path.join(stateDir, "daemon.meta.json"), "utf8"));
      process.kill(meta.pid, "SIGTERM");
    } catch {
      // daemon 没起来或已退出
    }
    fs.rmSync(stateDir, { recursive: true, force: true });
    fs.rmSync(projectsRoot, { recursive: true, force: true });
  }
}

main().catch((err) => {
  console.error("E2E FAIL ❌", err);
  process.exit(1);
});
