#!/usr/bin/env node
// acro CLI:MacBook 上的最小客户端,也是未来 libghostty surface command 的桥。
// 用法:
//   acro pair <host:port> [--code XXXX] [--name mac]
//   acro projects
//   acro sessions
//   acro run [--project <name|id>] [--] [command...]
//   acro attach <sessionId>

import readline from "node:readline";
import { encodeInFrame, FRAME_OUT, type Project, type Session } from "@acro/protocol";
import { AcroClient, loadClientConfig, saveClientConfig } from "./client.ts";

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

async function cmdPair(args: string[]): Promise<void> {
  const host = args[0] ?? fail("usage: acro pair <host:port> [--code XXXX] [--name mac]");
  let code = flagValue(args, "--code");
  const name = flagValue(args, "--name") ?? `${process.env.USER ?? "user"}-cli`;
  if (!code) {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    code = await new Promise<string>((resolve) => rl.question("pair code: ", resolve));
    rl.close();
  }
  const res = await fetch(`http://${host}/pair`, {
    method: "POST",
    body: JSON.stringify({ code: code.trim(), deviceName: name }),
  });
  if (!res.ok) fail(`pair failed: ${res.status}`);
  const { deviceId, token } = (await res.json()) as { deviceId: string; token: string };
  saveClientConfig({ host, token, deviceId });
  console.log(`paired as ${name} (${deviceId})`);
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
  const [cmd, ...args] = process.argv.slice(2);
  if (!cmd || cmd === "help" || cmd === "--help") {
    console.log(
      [
        "acro pair <host:port> [--code XXXX] [--name mac]",
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
  const client = await AcroClient.connect(loadClientConfig());
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
