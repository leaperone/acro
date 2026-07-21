#!/usr/bin/env node
// acro CLI:MacBook 上的最小客户端,也是未来 libghostty surface command 的桥。
// 用法:
//   pbpaste | acro pair [--name <label>]  远程配对;空 stdin 时读本机 bootstrap
//   acro endpoints [add|rm <host:port>]
//   acro sessions
//   acro run [--cwd <dir>] [--] [command...]
//   acro attach <sessionId>

import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
// 只引二进制帧模块:attach 冷启动不加载 zod(节省 ~150ms 空白期)
import { encodeInFrame, FRAME_OUT } from "@acro/protocol/frames";
import type { Session } from "@acro/protocol";
import {
  AcroClient,
  type ClientConfig,
  loadClientConfig,
  pickServer,
  resolveSessionRef,
  saveClientConfig,
  type ServerEntry,
} from "./client.ts";
import {
  parseCommandLine,
  parsePairArgs,
  parseRunArgs,
  parseSshArgs,
  selectPairEndpoints,
  shellQuote,
  type ParsedRunArgs,
} from "./args.ts";

const DETACH_KEY = 0x1d; // Ctrl-]
const INPUT_HIGH_WATER_BYTES = 1024 * 1024;
const INPUT_LOW_WATER_BYTES = 256 * 1024;
const MAX_PAIRING_OFFER_BYTES = 64 * 1024;

function fail(msg: string): never {
  console.error(msg);
  process.exit(1);
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
  const parsed = parsePairArgs(args);
  let raw = "";
  if (process.stdin.isTTY !== true) {
    const chunks: Buffer[] = [];
    let size = 0;
    for await (const chunk of process.stdin) {
      const data = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      size += data.length;
      if (size > MAX_PAIRING_OFFER_BYTES) fail("配对码超过 64 KiB");
      chunks.push(data);
    }
    raw = Buffer.concat(chunks).toString("utf8").trim();
  }
  if (!raw) {
    // 本机引导:runtime 首启把配对码写在 state 目录
    const bootstrapFile = path.join(
      process.env.ACRO_STATE_DIR ?? path.join(os.homedir(), ".acro"),
      "bootstrap-offer.txt",
    );
    try {
      raw = fs.readFileSync(bootstrapFile, "utf8").trim();
    } catch {
      fail("未找到配对码;远程运行: pbpaste | acro pair;Runtime 本机可直接运行 acro pair");
    }
  }
  const offer = decodePairingOffer(raw);
  const name = parsed.name ?? offer.endpoints[0]!;
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

// 装阶段:ssh -t 分配 PTY(需要密码的 sudo 能提示),全程 inherit 让进度 / 提示直达用户终端。
function runSshInstall(target: string, installCmd: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn("ssh", ["-t", target, installCmd], { stdio: "inherit" });
    child.on("error", (err) => reject(new Error(`无法启动 ssh: ${err.message}`)));
    child.on("close", (code) =>
      code === 0
        ? resolve()
        : reject(new Error(`ssh ${target} 安装失败(退出码 ${code ?? "?"});见上方日志`)),
    );
  });
}

// 取配对码:单独一段干净 ssh,只抓 stdout 的 acro:// 行。首次启动有配对码;
// 已配对主机的 bootstrap 配对码首次认证后即删除,此处返回空串(更新语义)。
function fetchRemoteOffer(target: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(
      "ssh",
      [target, 'cat "$HOME/.acro/bootstrap-offer.txt" 2>/dev/null || true'],
      { stdio: ["inherit", "pipe", "inherit"] },
    );
    let out = "";
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      out += chunk;
    });
    child.on("error", (err) => reject(new Error(`无法启动 ssh: ${err.message}`)));
    child.on("close", () => {
      const offer = out
        .split("\n")
        .map((line) => line.trim())
        .filter((line) => line.startsWith("acro://"))
        .pop();
      resolve(offer ?? "");
    });
  });
}

// acro ssh <target>:SSH 进目标机 → 幂等装依赖并启动 runtime → 取回配对码。
// 默认只打印配对码由用户自行配对;--pair 顺手完成配对(入口取 --endpoint 或配对码里的非回环地址)。
async function cmdSsh(args: string[]): Promise<void> {
  const parsed = parseSshArgs(args);
  const { decodePairingOffer } = await import("@acro/protocol");
  const { REMOTE_BOOTSTRAP } = await import("./remote-bootstrap.ts");
  const envPrefix = [
    parsed.repo ? `ACRO_REPO=${shellQuote(parsed.repo)}` : "",
    parsed.branch ? `ACRO_BRANCH=${shellQuote(parsed.branch)}` : "",
  ]
    .filter(Boolean)
    .join(" ");
  // base64 经命令参数传入(非 stdin),好让 ssh 的 stdin 留给交互式认证
  const b64 = Buffer.from(REMOTE_BOOTSTRAP, "utf8").toString("base64");
  const decode = `printf %s ${shellQuote(b64)} | base64 -d`;
  const installCmd = envPrefix ? `${decode} | ${envPrefix} bash -s` : `${decode} | bash -s`;

  console.error(`[acro] 连接 ${parsed.target} 并安装 runtime…`);
  await runSshInstall(parsed.target, installCmd);
  const offer = await fetchRemoteOffer(parsed.target);
  console.log(`\n已在 ${parsed.target} 安装并启动 Acro runtime。`);

  if (!offer) {
    // bootstrap 配对码首次认证后即删除;取不到说明主机已配对,本次是更新
    console.log("主机已配对,本次只更新并重启了 runtime(无需新配对码)。");
    return;
  }
  const decoded = decodePairingOffer(offer);

  if (!parsed.pair) {
    console.log(`\n配对码:\n${offer}`);
    console.log(
      "\n完成连接:在客户端运行 `acro pair`(粘贴上面的配对码),或桌面「连接服务器」粘贴。\n" +
        "若客户端不在服务器同网段,pair 后用 `acro endpoints add <可达地址:8790>` 补入口,\n" +
        `或直接 \`acro ssh ${parsed.target} --pair --endpoint <host:port>\` 一步到位。`,
    );
    return;
  }

  const endpoints = selectPairEndpoints(decoded.endpoints, parsed.endpoint);
  if (endpoints.length === 0) {
    fail(
      "配对码里没有可从客户端直连的入口(只有回环地址)。\n" +
        `用 --endpoint <host:port> 指定可达地址重跑,或手动配对:\n${offer}`,
    );
  }
  const name = parsed.name ?? parsed.target;
  const entry = {
    localId: crypto.randomUUID(),
    name,
    deviceId: "",
    token: decoded.token,
    pub: decoded.pub,
    endpoints,
  };
  let client: AcroClient;
  try {
    client = await AcroClient.connect(entry);
  } catch (err) {
    fail(
      `配对码已取回,但从客户端连接失败(${(err as Error).message})。\n` +
        `服务器地址可能对客户端不可达;用 --endpoint <可达地址:port> 重跑,或手动配对:\n${offer}`,
    );
  }
  entry.deviceId = client.deviceId;
  client.close();
  const config = loadOrEmptyConfig();
  config.servers = config.servers.filter((s) => s.name !== name);
  config.servers.push(entry);
  config.active = entry.localId;
  saveClientConfig(config);
  console.log(`已配对 ${name},入口: ${endpoints.join(", ")}`);
}

function cmdEndpoints(config: ClientConfig, server: ServerEntry, args: string[]): void {
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

async function cmdSessions(client: AcroClient): Promise<void> {
  for (const s of await client.rpc("session.list", {})) {
    const state = s.alive ? "alive" : `exit=${s.exitCode ?? "?"}`;
    console.log(`${s.id}  ${state}  ${s.command}  ${s.cwd}`);
  }
}

function termSize(): { cols: number; rows: number } {
  return { cols: process.stdout.columns || 80, rows: process.stdout.rows || 24 };
}

async function cmdRun(client: AcroClient, server: ServerEntry, parsed: ParsedRunArgs): Promise<void> {
  const { cwd, command } = parsed;
  const session = await client.rpc("session.create", {
    ...(cwd ? { cwd } : {}),
    ...(command ? { command } : {}),
    ...termSize(),
  });
  await attachLoop(client, session, server);
}

async function cmdAttach(client: AcroClient, server: ServerEntry, args: string[]): Promise<void> {
  const sessionId = args[0] ?? fail("usage: acro attach <sessionId>");
  const sessions = await client.rpc("session.list", {});
  let session: Session;
  try {
    session = resolveSessionRef(sessions, sessionId);
  } catch (err) {
    fail((err as Error).message);
  }
  if (!session.alive) fail("session is dead");
  await attachLoop(client, session, server);
}

const RETRY_DELAYS_MS = [500, 1000, 2000, 3000, 5000, 8000];
const MAX_RECONNECT_ATTEMPTS = 15;

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

// 连接抖动的退避重试:瞬时失败不该让终端 surface 直接报错退出
async function connectWithRetry(server: ServerEntry, attempts: number): Promise<AcroClient> {
  let lastErr: unknown;
  for (let i = 0; i < attempts; i += 1) {
    if (i > 0) await sleep(RETRY_DELAYS_MS[Math.min(i - 1, RETRY_DELAYS_MS.length - 1)]!);
    try {
      return await AcroClient.connect(server);
    } catch (err) {
      lastErr = err;
    }
  }
  throw lastErr instanceof Error ? lastErr : new Error("connect failed");
}

async function attachLoop(client: AcroClient, session: Session, server: ServerEntry): Promise<void> {
  const isTTY = process.stdin.isTTY === true;
  let current = client;
  let channel = -1;
  let finished = false;
  let reconnecting = false;
  let inputBackpressured = false;
  let pausedOutputClient: AcroClient | null = null;
  let waitingForStdoutDrain = false;
  let done!: (code: number) => void;
  const exitCode = new Promise<number>((resolve) => {
    done = (code) => {
      finished = true;
      resolve(code);
    };
  });

  const syncSize = async (c: AcroClient) => {
    if (!isTTY) return;
    await c.rpc("session.resize", { sessionId: session.id, ...termSize() }).catch(() => {});
  };

  const onStdoutDrain = () => {
    waitingForStdoutDrain = false;
    pausedOutputClient?.resumeIncoming();
    pausedOutputClient = null;
  };

  const writeOutput = (c: AcroClient, data: string | Uint8Array) => {
    if (process.stdout.write(data)) return;
    if (pausedOutputClient !== c) {
      pausedOutputClient?.resumeIncoming();
      pausedOutputClient = c;
      c.pauseIncoming();
    }
    if (!waitingForStdoutDrain) {
      waitingForStdoutDrain = true;
      process.stdout.once("drain", onStdoutDrain);
    }
  };

  const wire = (c: AcroClient) => {
    c.onFrame = (frame) => {
      if (frame.type === FRAME_OUT && frame.channel === channel) {
        writeOutput(c, frame.data);
      }
    };
    c.onEvent = (event, payload) => {
      if (
        (event === "session.exit" || event === "session.removed") &&
        (payload as { sessionId: string }).sessionId === session.id
      ) {
        done((payload as { exitCode?: number | null }).exitCode ?? 0);
      }
    };
    // close 和 error 都会触发;reconnecting 去重,断线自动重挂载而不是退出
    c.onDisconnect = () => {
      if (finished || reconnecting) return;
      reconnecting = true;
      console.error("\r\n[acro] 连接断开,正在重连…");
      void reattach();
    };
  };

  // 断线重挂载:重连 → 确认会话仍活着 → 重新 attach。
  // 快照含完整 scrollback,清屏回放即内容恢复,客户端不做增量补偿(orca 同款)
  const reattach = async (): Promise<void> => {
    for (let attempt = 0; attempt < MAX_RECONNECT_ATTEMPTS && !finished; attempt += 1) {
      await sleep(RETRY_DELAYS_MS[Math.min(attempt, RETRY_DELAYS_MS.length - 1)]!);
      if (finished) return;
      try {
        const next = await AcroClient.connect(server);
        try {
          const sessions = await next.rpc("session.list", {});
          const live = sessions.find((s) => s.id === session.id);
          if (!live) {
            next.close();
            console.error("\r\n[acro] 会话已不存在");
            done(1);
            return;
          }
          if (!live.alive) {
            next.close();
            done(live.exitCode ?? 0);
            return;
          }
          const attached = await next.rpc("session.attach", { sessionId: session.id });
          current = next;
          channel = attached.channel;
          wire(next);
          writeOutput(
            next,
            Buffer.concat([
              Buffer.from("\x1b[2J\x1b[3J\x1b[H"),
              Buffer.from(attached.snapshot, "base64"),
            ]),
          );
          await syncSize(next);
          reconnecting = false;
          if (!inputBackpressured) process.stdin.resume();
          return;
        } catch (err) {
          // 连上了但 list/attach 失败:关掉这条连接再退避,不留半开 socket
          next.close();
          throw err;
        }
      } catch {
        // 下一轮退避重试
      }
    }
    if (!finished) {
      console.error("\r\n[acro] 无法重连,放弃");
      done(1);
    }
  };

  wire(current);
  try {
    const attached = await current.rpc("session.attach", { sessionId: session.id });
    channel = attached.channel;
    writeOutput(current, Buffer.from(attached.snapshot, "base64"));
  } catch (err) {
    // 初次 attach 窗口内断线:onDisconnect 已在跑重挂载,交给它;
    // 连接还活着说明是真错误(如会话刚死),直接失败
    if (!reconnecting) fail(String((err as Error).message ?? err));
  }

  if (isTTY) {
    process.stdin.setRawMode(true);
    // 无条件报告本端尺寸:runtime 会记录每个在挂端的最新值,
    // focus 接管或别端 detach 时才能立即切到正确尺寸
    await syncSize(current);
    process.on("SIGWINCH", () => void syncSize(current));
  }
  process.stdin.resume();
  process.stdin.on("data", (data: Buffer) => {
    if (isTTY && data.length === 1 && data[0] === DETACH_KEY) {
      done(-1);
      return;
    }
    // 重连窗口内的输入丢弃:channel 已失效,重挂载后快照会呈现服务端真实状态
    if (reconnecting) return;
    try {
      const bufferedAmount = current.sendBinary(encodeInFrame(channel, data));
      if (bufferedAmount >= INPUT_HIGH_WATER_BYTES && !inputBackpressured) {
        inputBackpressured = true;
        process.stdin.pause();
        const draining = current;
        void draining
          .waitForWritable(INPUT_LOW_WATER_BYTES)
          .catch(() => {})
          .finally(() => {
            inputBackpressured = false;
            if (!finished && !reconnecting) process.stdin.resume();
          });
      }
    } catch {
      // onDisconnect 负责重连
    }
  });
  process.stdin.on("end", () => {
    // 管道输入结束不代表会话结束;保持附着直到会话退出
  });

  const code = await exitCode;
  if (isTTY) process.stdin.setRawMode(false);
  process.stdin.pause();
  current.onFrame = null;
  if (waitingForStdoutDrain) process.stdout.off("drain", onStdoutDrain);
  onStdoutDrain();
  await current.rpc("session.detach", { sessionId: session.id }).catch(() => {});
  current.close();
  if (code === -1) console.error("\r\n[acro] detached");
  process.exit(code === -1 ? 0 : code);
}

async function main(): Promise<void> {
  // 全局 --server 在首个 -- 前解析；-- 后全部属于目标命令。
  const { command: cmd, args, passthrough, serverRef } = parseCommandLine(
    process.argv.slice(2),
  );
  if (!cmd || cmd === "help" || cmd === "--help") {
    console.log(
      [
        "pbpaste | acro pair [--name <label>]  从 stdin 安全读取远程配对码",
        "acro pair [--name <label>]            Runtime 本机读取 bootstrap 配对码",
        "acro ssh <[user@]host|别名> [--pair] [--endpoint host:port] [--name <label>] [--branch <ref>]",
        "                                      SSH 进目标机装好 runtime 并取回配对码(--pair 顺手配对)",
        "acro --server <名称|deviceId> <命令>  指定目标服务器",
        "acro endpoints [add|rm <host:port>]",
        "acro sessions",
        "acro run [--cwd <dir>] [command...]",
        "acro attach <sessionId>",
      ].join("\n"),
    );
    return;
  }
  if (passthrough && cmd !== "run") fail(`${cmd} does not accept -- passthrough arguments`);
  if (cmd === "pair") {
    await cmdPair(args);
    return;
  }
  if (cmd === "ssh") {
    await cmdSsh(args);
    return;
  }
  if (cmd === "endpoints") {
    const config = loadClientConfig();
    cmdEndpoints(config, pickServer(config, serverRef), args);
    return;
  }
  const runArgs = cmd === "run" ? parseRunArgs(args, passthrough) : null;
  const server = pickServer(loadClientConfig(), serverRef);
  // attach/run 走终端 surface:初连也做退避重试,别把瞬时抖动直接怼到用户脸上
  const client = await connectWithRetry(server, cmd === "attach" || cmd === "run" ? 5 : 1);
  switch (cmd) {
    case "sessions":
      await cmdSessions(client);
      break;
    case "run":
      await cmdRun(client, server, runArgs!);
      return; // attachLoop 自己 exit
    case "attach":
      await cmdAttach(client, server, args);
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
