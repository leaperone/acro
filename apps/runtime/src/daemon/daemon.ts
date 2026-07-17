// Terminal daemon:独立进程持有全部 PTY 会话。
// Runtime 升级或崩溃不影响这里;daemon 自身保持极简、极少改动。
//
// - node-pty 驱动 PTY
// - @xterm/headless + serialize addon 维护屏幕状态,attach 时产出精确快照
// - 输出帧带单调 seq,快照与 seq 对齐,客户端按 seq 过滤实现无缝续传
// - checkpoint 落盘,daemon 重启后死会话仍可列出

import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { createRequire } from "node:module";
import pty from "node-pty";
// @xterm 双包是 CJS,原生 node ESM 下必须走 default import 再解构
import xtermHeadless from "@xterm/headless";
import xtermSerialize from "@xterm/addon-serialize";

const { Terminal } = xtermHeadless;
const { SerializeAddon } = xtermSerialize;
type Terminal = InstanceType<typeof Terminal>;
type SerializeAddon = InstanceType<typeof SerializeAddon>;
import type { Session } from "@acro/protocol";
import { encodeOutFrame, decodeFrame, FRAME_IN } from "@acro/protocol";
import { paths, ensureStateDirs } from "../paths.ts";
import { readJson, writeJsonAtomic } from "../store.ts";
import { FrameReader, KIND_BIN, KIND_JSON, packBin, packJson } from "./wire.ts";

const SCROLLBACK = 5000;
const CHECKPOINT_INTERVAL_MS = 20_000;

// pnpm 解包会丢 spawn-helper 的可执行位,node-pty 自己不修,这里自愈
function ensureSpawnHelperExecutable(): void {
  const require = createRequire(import.meta.url);
  const ptyDir = path.dirname(require.resolve("node-pty/package.json"));
  for (const arch of ["darwin-arm64", "darwin-x64"]) {
    const helper = path.join(ptyDir, "prebuilds", arch, "spawn-helper");
    if (fs.existsSync(helper)) fs.chmodSync(helper, 0o755);
  }
}

const boot = crypto.randomUUID();
let eventSeq = 0;
let nextHandle = 1;

interface QueueItem {
  kind: "chunk" | "snapshot";
  data?: string;
  seq?: number;
  resolve?: (r: { seq: number; snapshot: string }) => void;
}

class DaemonSession {
  readonly handle = nextHandle++;
  readonly meta: Session;
  private ptyProc: pty.IPty;
  private term: Terminal;
  private serializer: SerializeAddon;
  private seq = 0;
  private parsedSeq = 0;
  private queue: QueueItem[] = [];
  private pumping = false;
  private dirty = false;

  private onOutput: (handle: number, seq: number, data: Buffer) => void;
  private onExit: (session: DaemonSession) => void;

  constructor(
    opts: {
      projectId?: string | undefined;
      cwd?: string | undefined;
      command?: string | undefined;
      cols: number;
      rows: number;
    },
    onOutput: (handle: number, seq: number, data: Buffer) => void,
    onExit: (session: DaemonSession) => void,
  ) {
    this.onOutput = onOutput;
    this.onExit = onExit;
    const shell = process.env.SHELL ?? "/bin/zsh";
    const cwd = opts.cwd ?? os.homedir();
    const args = opts.command ? ["-lc", opts.command] : ["-l"];
    this.meta = {
      id: crypto.randomUUID(),
      projectId: opts.projectId ?? null,
      cwd,
      command: opts.command ?? shell,
      cols: opts.cols,
      rows: opts.rows,
      createdAt: new Date().toISOString(),
      alive: true,
      exitCode: null,
    };
    this.term = new Terminal({
      cols: opts.cols,
      rows: opts.rows,
      scrollback: SCROLLBACK,
      allowProposedApi: true,
    });
    this.serializer = new SerializeAddon();
    this.term.loadAddon(this.serializer);
    this.ptyProc = pty.spawn(shell, args, {
      name: "xterm-256color",
      cols: opts.cols,
      rows: opts.rows,
      cwd,
      env: { ...process.env, TERM: "xterm-256color", COLORTERM: "truecolor" } as Record<
        string,
        string
      >,
    });
    this.ptyProc.onData((data) => {
      this.seq += 1;
      this.dirty = true;
      this.onOutput(this.handle, this.seq, Buffer.from(data, "utf8"));
      this.queue.push({ kind: "chunk", data, seq: this.seq });
      void this.pump();
    });
    this.ptyProc.onExit(({ exitCode }) => {
      this.meta.alive = false;
      this.meta.exitCode = exitCode;
      this.checkpoint();
      this.onExit(this);
    });
  }

  // 快照进同一条解析队列,保证 snapshot 恰好覆盖 seq<=snapshotSeq 的输出:
  // 之后的帧 seq 更大,runtime 按 attachSeq 过滤,不重不漏。
  snapshot(): Promise<{ seq: number; snapshot: string }> {
    return new Promise((resolve) => {
      this.queue.push({ kind: "snapshot", resolve });
      void this.pump();
    });
  }

  private async pump(): Promise<void> {
    if (this.pumping) return;
    this.pumping = true;
    while (this.queue.length > 0) {
      const item = this.queue.shift()!;
      if (item.kind === "chunk") {
        await new Promise<void>((r) => this.term.write(item.data!, r));
        this.parsedSeq = item.seq!;
      } else {
        item.resolve!({
          seq: this.parsedSeq,
          snapshot: this.serializer.serialize({ scrollback: SCROLLBACK }),
        });
      }
    }
    this.pumping = false;
  }

  write(data: Buffer): void {
    if (this.meta.alive) this.ptyProc.write(data.toString("utf8"));
  }

  resize(cols: number, rows: number): void {
    if (!this.meta.alive) return;
    this.meta.cols = cols;
    this.meta.rows = rows;
    this.ptyProc.resize(cols, rows);
    this.term.resize(cols, rows);
    this.dirty = true;
  }

  kill(): void {
    if (this.meta.alive) this.ptyProc.kill();
  }

  checkpoint(): void {
    const dir = path.join(paths.sessions, this.meta.id);
    fs.mkdirSync(dir, { recursive: true });
    writeJsonAtomic(path.join(dir, "meta.json"), this.meta);
    void this.snapshot().then(({ snapshot }) => {
      fs.writeFileSync(path.join(dir, "snapshot.txt"), snapshot);
    });
    this.dirty = false;
  }

  checkpointIfDirty(): void {
    if (this.dirty) this.checkpoint();
  }
}

// ---- 会话表:活会话 + 上一个 boot 留下的死会话记录 ----

const live = new Map<string, DaemonSession>();
const dead = new Map<string, Session>();

function loadDeadSessions(): void {
  if (!fs.existsSync(paths.sessions)) return;
  for (const id of fs.readdirSync(paths.sessions)) {
    const meta = readJson<Session | null>(path.join(paths.sessions, id, "meta.json"), null);
    if (!meta) continue;
    // 上一个 daemon 进程死掉时还活着的会话,现在必然已死
    if (meta.alive) {
      meta.alive = false;
      meta.exitCode = null;
      writeJsonAtomic(path.join(paths.sessions, id, "meta.json"), meta);
    }
    dead.set(meta.id, meta);
  }
}

// ---- socket 服务 ----

const clients = new Set<net.Socket>();

function broadcast(buf: Buffer): void {
  for (const c of clients) c.write(buf);
}

function emitEvent(event: string, payload: unknown): void {
  eventSeq += 1;
  broadcast(packJson({ t: "evt", seq: eventSeq, boot, event, payload }));
}

function handleOutput(handle: number, seq: number, data: Buffer): void {
  broadcast(packBin(encodeOutFrame(handle, seq, data)));
}

function handleExit(session: DaemonSession): void {
  live.delete(session.meta.id);
  dead.set(session.meta.id, session.meta);
  emitEvent("session.exit", { sessionId: session.meta.id, exitCode: session.meta.exitCode });
}

type Handler = (params: any) => Promise<unknown> | unknown;

const handlers: Record<string, Handler> = {
  "daemon.info": () => ({ boot, pid: process.pid }),
  "session.create": (params: {
    projectId?: string;
    cwd?: string;
    command?: string;
    cols: number;
    rows: number;
  }) => {
    const session = new DaemonSession(params, handleOutput, handleExit);
    live.set(session.meta.id, session);
    session.checkpoint();
    emitEvent("session.created", session.meta);
    return { session: session.meta, handle: session.handle };
  },
  "session.list": () => [
    ...[...live.values()].map((s) => s.meta),
    ...dead.values(),
  ],
  "session.snapshot": async (params: { sessionId: string }) => {
    const session = live.get(params.sessionId);
    if (!session) throw new Error("session not alive");
    const snap = await session.snapshot();
    return {
      handle: session.handle,
      seq: snap.seq,
      snapshot: Buffer.from(snap.snapshot, "utf8").toString("base64"),
      cols: session.meta.cols,
      rows: session.meta.rows,
    };
  },
  "session.resize": (params: { sessionId: string; cols: number; rows: number }) => {
    live.get(params.sessionId)?.resize(params.cols, params.rows);
    return {};
  },
  "session.kill": (params: { sessionId: string }) => {
    live.get(params.sessionId)?.kill();
    return {};
  },
};

function startServer(): void {
  if (fs.existsSync(paths.daemonSocket)) fs.unlinkSync(paths.daemonSocket);
  const server = net.createServer((socket) => {
    clients.add(socket);
    const reader = new FrameReader();
    socket.on("data", (chunk) => {
      for (const msg of reader.push(chunk)) {
        if (msg.kind === KIND_BIN) {
          const frame = decodeFrame(msg.body);
          if (frame.type === FRAME_IN) {
            for (const s of live.values()) {
              if (s.handle === frame.channel) s.write(Buffer.from(frame.data));
            }
          }
          continue;
        }
        if (msg.kind !== KIND_JSON) continue;
        const req = JSON.parse(msg.body.toString("utf8")) as {
          t: string;
          id: number;
          method: string;
          params?: unknown;
        };
        if (req.t !== "req") continue;
        void (async () => {
          try {
            const handler = handlers[req.method];
            if (!handler) throw new Error(`unknown method ${req.method}`);
            const result = await handler(req.params ?? {});
            socket.write(packJson({ t: "res", id: req.id, ok: true, result }));
          } catch (err) {
            socket.write(
              packJson({
                t: "res",
                id: req.id,
                ok: false,
                error: { code: "daemon_error", message: (err as Error).message },
              }),
            );
          }
        })();
      }
    });
    socket.on("close", () => clients.delete(socket));
    socket.on("error", () => clients.delete(socket));
  });
  server.listen(paths.daemonSocket, () => {
    writeJsonAtomic(paths.daemonMeta, { pid: process.pid, boot, startedAt: new Date().toISOString() });
    console.log(`[daemon] listening on ${paths.daemonSocket} boot=${boot}`);
  });
}

function main(): void {
  ensureStateDirs();
  ensureSpawnHelperExecutable();

  // 已有 daemon 在跑就退出,保证单实例
  const probe = net.connect(paths.daemonSocket);
  probe.on("connect", () => {
    console.log("[daemon] another daemon is already running, exiting");
    process.exit(0);
  });
  probe.on("error", () => {
    loadDeadSessions();
    startServer();
  });

  setInterval(() => {
    for (const s of live.values()) s.checkpointIfDirty();
  }, CHECKPOINT_INTERVAL_MS).unref();
  // 有活会话时保持进程常驻
  setInterval(() => {}, 1 << 30);

  for (const signal of ["SIGTERM", "SIGINT"] as const) {
    process.on(signal, () => {
      for (const s of live.values()) s.checkpoint();
      process.exit(0);
    });
  }
}

main();
