// 端到端验证:配对 → Workspace → 项目 → 会话 → 断线重连 → Runtime 重启会话存活。
// 全部走真实进程和真实 WS,不 mock。失败即 assert 抛错。

import assert from "node:assert/strict";
import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";
import {
  decodeFrame,
  type DirectoryListing,
  encodeInFrame,
  FRAME_OUT,
  type Project,
  type Session,
  type Workspace,
  type WorkspaceGroup,
} from "@acro/protocol";

const PORT = 18790;
const PAIR_CODE = "E2ETESTCODE";
const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), "acro-e2e-state-"));
const projectsRoot = fs.mkdtempSync(path.join(os.tmpdir(), "acro-e2e-projects-"));
const runtimeEntry = fileURLToPath(new URL("../src/index.ts", import.meta.url));

const env = {
  ...process.env,
  ACRO_STATE_DIR: stateDir,
  ACRO_PORT: String(PORT),
  ACRO_PAIR_CODE: PAIR_CODE,
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

class Client {
  private ws!: WebSocket;
  private nextId = 1;
  private pending = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
  output = ""; // 附着后收到的所有终端输出
  events: Array<{ event: string; payload: any }> = [];

  async connect(token: string): Promise<void> {
    this.ws = new WebSocket(`ws://127.0.0.1:${PORT}/ws?token=${token}`);
    await new Promise<void>((resolve, reject) => {
      this.ws.on("open", () => resolve());
      this.ws.on("error", reject);
    });
    this.ws.on("message", (raw: Buffer, isBinary: boolean) => {
      if (isBinary) {
        const frame = decodeFrame(raw);
        if (frame.type === FRAME_OUT) this.output += Buffer.from(frame.data).toString("utf8");
        return;
      }
      const msg = JSON.parse(raw.toString("utf8"));
      if (msg.t === "res") {
        const p = this.pending.get(msg.id);
        if (!p) return;
        this.pending.delete(msg.id);
        if (msg.ok) p.resolve(msg.result);
        else p.reject(new Error(`${msg.error.code}: ${msg.error.message}`));
      } else if (msg.t === "evt") {
        this.events.push({ event: msg.event, payload: msg.payload });
      }
    });
  }

  rpc<T = any>(method: string, params: unknown = {}): Promise<T> {
    const id = this.nextId++;
    this.ws.send(JSON.stringify({ t: "req", id, method, params }));
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      setTimeout(() => {
        if (this.pending.delete(id)) reject(new Error(`rpc timeout: ${method}`));
      }, 10000);
    });
  }

  sendInput(channel: number, text: string): void {
    this.ws.send(encodeInFrame(channel, Buffer.from(text, "utf8")), { binary: true });
  }

  async waitOutput(needle: string, timeoutMs = 8000): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (this.output.includes(needle)) return;
      await sleep(100);
    }
    throw new Error(`output did not contain ${JSON.stringify(needle)}; got: ${JSON.stringify(this.output.slice(-500))}`);
  }

  close(): void {
    this.ws.close();
  }
}

async function main(): Promise<void> {
  const fixtureRepo = makeFixtureRepo();
  let runtime = startRuntime();

  try {
    await waitHealthy();
    log("runtime healthy");

    // 配对
    const pairRes = await fetch(`http://127.0.0.1:${PORT}/pair`, {
      method: "POST",
      body: JSON.stringify({ code: PAIR_CODE, deviceName: "e2e-device" }),
    });
    assert.equal(pairRes.status, 200, "pair should succeed");
    const { token } = (await pairRes.json()) as { token: string };
    assert.ok(token.length >= 32);
    log("paired");

    // 错误配对码要拒绝
    const badPair = await fetch(`http://127.0.0.1:${PORT}/pair`, {
      method: "POST",
      body: JSON.stringify({ code: "WRONGCODE1", deviceName: "bad" }),
    });
    assert.equal(badPair.status, 403);

    // 无 token WS 要拒绝
    await assert.rejects(
      new Promise((resolve, reject) => {
        const bad = new WebSocket(`ws://127.0.0.1:${PORT}/ws`);
        bad.on("open", resolve);
        bad.on("error", reject);
      }),
      "unauthenticated ws must fail",
    );

    const client = new Client();
    await client.connect(token);
    log("ws connected");

    // 项目由用户显式注册；目录浏览发生在 Runtime 文件系统。
    assert.deepEqual(await client.rpc<Project[]>("project.list"), []);
    const listing = await client.rpc<DirectoryListing>("filesystem.listDirectories", {
      path: projectsRoot,
    });
    assert.equal(listing.entries[0]?.name, "demo");
    const project = await client.rpc<Project>("project.register", { path: fixtureRepo });
    assert.equal(project.name, "demo");
    assert.deepEqual(await client.rpc<Project[]>("project.list"), [project]);

    const workspaceGroup = await client.rpc<WorkspaceGroup>("workspaceGroup.create", {
      name: "E2E Group",
    });
    const workspace = await client.rpc<Workspace>("workspace.create", {
      name: "E2E",
      workspaceGroupId: workspaceGroup.id,
    });
    assert.deepEqual(workspace.projectIds, []);
    assert.deepEqual(
      (await client.rpc<WorkspaceGroup[]>("workspaceGroup.list"))[0]?.workspaceIds,
      [workspace.id],
    );
    const configuredWorkspace = await client.rpc<Workspace>("workspace.update", {
      workspaceId: workspace.id,
      projectIds: [project.id],
    });
    assert.deepEqual(configuredWorkspace.projectIds, [project.id]);
    log("workspace created");

    // 会话:在项目目录里跑 /bin/sh(避免用户 shell 配置噪音)
    const session = await client.rpc<Session>("session.create", {
      workspaceId: workspace.id,
      projectId: project.id,
      command: "/bin/sh",
      cols: 80,
      rows: 24,
    });
    assert.equal(session.alive, true);
    assert.equal(session.cwd, project.path);
    const workspaceWithSession = (await client.rpc<Workspace[]>("workspace.list")).find(
      (item) => item.id === workspace.id,
    );
    assert.ok(workspaceWithSession?.sessionIds.includes(session.id));
    await assert.rejects(
      client.rpc("workspace.remove", { workspaceId: workspace.id }),
      /workspace has active sessions/,
    );

    const attach1 = await client.rpc<{ channel: number; snapshot: string; seq: number }>(
      "session.attach",
      { sessionId: session.id },
    );
    client.sendInput(attach1.channel, "echo MARK_${RANDOM}_ONE; pwd\n");
    client.sendInput(attach1.channel, "echo BEFORE_DISCONNECT_XYZ\n");
    await client.waitOutput("BEFORE_DISCONNECT_XYZ");
    await client.waitOutput(project.path); // pwd 确认跑在项目目录里
    log("session io ok");

    // 断开重连:会话必须还在,快照必须包含断开前的输出,且不重发旧帧
    client.close();
    await sleep(500);
    const client2 = new Client();
    await client2.connect(token);
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
    await client3.connect(token);
    const sessions = await client3.rpc<Session[]>("session.list");
    const survived = sessions.find((s) => s.id === session.id);
    assert.ok(survived?.alive, "session must survive runtime restart");
    const restoredWorkspace = (await client3.rpc<Workspace[]>("workspace.list")).find(
      (item) => item.id === workspace.id,
    );
    assert.ok(restoredWorkspace?.sessionIds.includes(session.id));
    const attach3 = await client3.rpc<{ channel: number; snapshot: string }>("session.attach", {
      sessionId: session.id,
    });
    const snapshot3 = Buffer.from(attach3.snapshot, "base64").toString("utf8");
    assert.ok(snapshot3.includes("AFTER_RECONNECT_XYZ"));
    client3.sendInput(attach3.channel, "echo AFTER_RUNTIME_RESTART_XYZ\n");
    await client3.waitOutput("AFTER_RUNTIME_RESTART_XYZ");
    log("runtime restart survival ok");

    // kill 会话 → exit 事件 → 列表标记死亡
    await client3.rpc("session.kill", { sessionId: session.id });
    await sleep(800);
    assert.ok(
      client3.events.some((e) => e.event === "session.exit" && e.payload.sessionId === session.id),
      "must receive session.exit event",
    );
    const after = await client3.rpc<Session[]>("session.list");
    assert.equal(after.find((s) => s.id === session.id)?.alive, false);
    log("kill + exit event ok");

    await client3.rpc("workspace.remove", { workspaceId: workspace.id });
    assert.equal((await client3.rpc<Workspace[]>("workspace.list")).length, 0);
    await client3.rpc("workspaceGroup.remove", { workspaceGroupId: workspaceGroup.id });
    assert.equal((await client3.rpc<WorkspaceGroup[]>("workspaceGroup.list")).length, 0);
    client3.close();
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
