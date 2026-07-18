#!/usr/bin/env node
// acro CLI:MacBook 上的最小客户端,也是未来 libghostty surface command 的桥。
// 用法:
//   acro pair [配对码] [--name <label>]   无参数时读本机 bootstrap 配对码
//   acro endpoints [add|rm <host:port>]
//   acro projects
//   acro sessions
//   acro run [--project <name|id>] [--] [command...]
//   acro attach <sessionId>

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
// 只引二进制帧模块:attach 冷启动不加载 zod(节省 ~150ms 空白期)
import { encodeInFrame, FRAME_OUT } from "@acro/protocol/frames";
import type { Project, Session } from "@acro/protocol";
import {
  AcroClient,
  activeServer,
  type ClientConfig,
  loadClientConfig,
  pickServer,
  saveClientConfig,
} from "./client.ts";

const DETACH_KEY = 0x1d; // Ctrl-]

function fail(msg: string): never {
  console.error(msg);
  process.exit(1);
}

async function resolveProject(client: AcroClient, ref: string): Promise<Project> {
  const projects = await client.rpc("project.list", {});
  const found = projects.find((p) => p.id === ref || p.name === ref);
  if (!found) fail(`project not found: ${ref}`);
  return found;
}

function loadOrEmptyConfig(): ClientConfig {
  try {
    const raw = JSON.parse(
      fs.readFileSync(
        process.env.ACRO_CLIENT_CONFIG ?? path.join(os.homedir(), ".acro", "client.json"),
        "utf8",
      ),
    ) as ClientConfig;
    if (raw.v === 2 && Array.isArray(raw.servers)) return raw;
  } catch {
    // 首次配对
  }
  return { v: 2, servers: [], active: null };
}

async function cmdPair(args: string[]): Promise<void> {
  // zod 只在 pair 路径加载
  const { decodePairingOffer } = await import("@acro/protocol");
  let raw = args.find((a) => !a.startsWith("--"));
  if (!raw) {
    // 本机引导:runtime 首启把配对码写在 state 目录
    const bootstrapFile = path.join(
      process.env.ACRO_STATE_DIR ?? path.join(os.homedir(), ".acro"),
      "bootstrap-offer.txt",
    );
    try {
      raw = fs.readFileSync(bootstrapFile, "utf8").trim();
    } catch {
      fail("usage: acro pair <配对码>(或在 runtime 本机直接运行 acro pair)");
    }
  }
  const offer = decodePairingOffer(raw);
  const name = flagValue(args, "--name") ?? offer.endpoints[0]!;
  const config = loadOrEmptyConfig();
  // 同名服务器覆盖(重新配对场景)
  const entry = {
    localId: crypto.randomUUID(),
    name,
    deviceId: "",
    token: offer.token,
    pub: offer.pub,
    endpoints: offer.endpoints,
  };
  // 先连一次确认配对码有效,deviceId 由服务端 authed 消息带回
  const client = await AcroClient.connect(entry);
  entry.deviceId = client.deviceId;
  client.close();
  config.servers = config.servers.filter((s) => s.name !== name);
  config.servers.push(entry);
  config.active = entry.localId; // active 存稳定 id
  saveClientConfig(config);
  console.log(`已配对 ${name},入口: ${offer.endpoints.join(", ")}`);
}

function cmdEndpoints(args: string[]): void {
  const config = loadClientConfig();
  const server = activeServer(config);
  const [op, value] = args;
  if (op === "add" && value) {
    if (!server.endpoints.includes(value)) server.endpoints.push(value);
    saveClientConfig(config);
  } else if (op === "rm" && value) {
    if (server.endpoints.length <= 1) fail("至少保留一个入口");
    server.endpoints = server.endpoints.filter((e) => e !== value);
    saveClientConfig(config);
  } else if (op) {
    fail("usage: acro endpoints [add|rm <host:port>]");
  }
  for (const e of server.endpoints) console.log(e);
}

async function cmdProjects(client: AcroClient): Promise<void> {
  for (const p of await client.rpc("project.list", {})) {
    console.log(`${p.id}  ${p.name}  ${p.path}`);
  }
}

async function cmdSessions(client: AcroClient): Promise<void> {
  for (const s of await client.rpc("session.list", {})) {
    const state = s.alive ? "alive" : `exit=${s.exitCode ?? "?"}`;
    console.log(`${s.id}  ${state}  ${s.command}  ${s.cwd}`);
  }
}

function termSize(): { cols: number; rows: number } {
  return { cols: process.stdout.columns || 80, rows: process.stdout.rows || 24 };
}

async function cmdRun(client: AcroClient, args: string[]): Promise<void> {
  const projectRef = flagValue(args, "--project");
  const rest = args.filter((a, i) => {
    if (a.startsWith("--")) return false;
    const prev = args[i - 1];
    return prev !== "--project";
  });
  const command = rest.length > 0 ? rest.join(" ") : undefined;
  const projectId = projectRef ? (await resolveProject(client, projectRef)).id : undefined;
  const session = await client.rpc("session.create", {
    ...(projectId ? { projectId } : {}),
    ...(command ? { command } : {}),
    ...termSize(),
  });
  await attachLoop(client, session);
}

async function cmdAttach(client: AcroClient, args: string[]): Promise<void> {
  const sessionId = args[0] ?? fail("usage: acro attach <sessionId>");
  const sessions = await client.rpc("session.list", {});
  const session = sessions.find((s) => s.id === sessionId || s.id.startsWith(sessionId));
  if (!session) fail(`session not found: ${sessionId}`);
  if (!session.alive) fail("session is dead");
  await attachLoop(client, session);
}

async function attachLoop(client: AcroClient, session: Session): Promise<void> {
  client.onDisconnect = () => {
    console.error("\r\n[acro] 连接断开");
    process.exit(1);
  };
  const { channel, snapshot } = await client.rpc("session.attach", { sessionId: session.id });
  const isTTY = process.stdin.isTTY === true;

  process.stdout.write(Buffer.from(snapshot, "base64"));

  client.onFrame = (frame) => {
    if (frame.type === FRAME_OUT && frame.channel === channel) {
      process.stdout.write(frame.data);
    }
  };

  let done: (code: number) => void;
  const finished = new Promise<number>((resolve) => {
    done = resolve;
  });
  client.onEvent = (event, payload) => {
    if (event === "session.exit" && (payload as { sessionId: string }).sessionId === session.id) {
      done((payload as { exitCode: number | null }).exitCode ?? 0);
    }
  };

  if (isTTY) {
    process.stdin.setRawMode(true);
    // 尺寸跟随本端
    const { cols, rows } = termSize();
    if (cols !== session.cols || rows !== session.rows) {
      await client.rpc("session.resize", { sessionId: session.id, cols, rows });
    }
    process.on("SIGWINCH", () => {
      void client.rpc("session.resize", { sessionId: session.id, ...termSize() });
    });
  }
  process.stdin.resume();
  process.stdin.on("data", (data: Buffer) => {
    if (isTTY && data.length === 1 && data[0] === DETACH_KEY) {
      done(-1);
      return;
    }
    client.sendBinary(encodeInFrame(channel, data));
  });
  process.stdin.on("end", () => {
    // 管道输入结束不代表会话结束;保持附着直到会话退出
  });

  const code = await finished;
  if (isTTY) process.stdin.setRawMode(false);
  process.stdin.pause();
  await client.rpc("session.detach", { sessionId: session.id }).catch(() => {});
  if (code === -1) console.error("\r\n[acro] detached");
  process.exit(code === -1 ? 0 : code);
}

function flagValue(args: string[], flag: string): string | undefined {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : undefined;
}

async function main(): Promise<void> {
  // 全局 --server <localId|deviceId|名称>:先于命令解析,前置后置都支持
  const argv = process.argv.slice(2);
  const serverRef = flagValue(argv, "--server");
  const [cmd, ...args] = argv.filter((a, i) => a !== "--server" && argv[i - 1] !== "--server");
  if (!cmd || cmd === "help" || cmd === "--help") {
    console.log(
      [
        "acro pair [配对码] [--name <label>]",
        "acro --server <名称|deviceId> <命令>  指定目标服务器",
        "acro endpoints [add|rm <host:port>]",
        "acro projects",
        "acro sessions",
        "acro run [--project <p>] [command...]",
        "acro attach <sessionId>",
      ].join("\n"),
    );
    return;
  }
  if (cmd === "pair") {
    await cmdPair(args);
    return;
  }
  if (cmd === "endpoints") {
    cmdEndpoints(args);
    return;
  }
  const client = await AcroClient.connect(pickServer(loadClientConfig(), serverRef));
  switch (cmd) {
    case "projects":
      await cmdProjects(client);
      break;
    case "sessions":
      await cmdSessions(client);
      break;
    case "run":
      await cmdRun(client, args);
      return; // attachLoop 自己 exit
    case "attach":
      await cmdAttach(client, args);
      return;
    default:
      fail(`unknown command: ${cmd}`);
  }
  client.close();
}

main().catch((err) => {
  console.error(err.message ?? err);
  process.exit(1);
});
