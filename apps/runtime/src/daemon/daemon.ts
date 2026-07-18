// Terminal daemon:独立进程持有全部 PTY 会话。
// Runtime 升级或崩溃不影响这里;daemon 自身保持极简、极少改动。
//
// - node-pty 驱动 PTY
// - @xterm/headless + serialize addon 维护屏幕状态,attach 时产出精确快照
// - 输出帧带单调 seq,快照与 seq 对齐,客户端按 seq 过滤实现无缝续传
// - checkpoint 落盘,daemon 重启后死会话仍可列出

import { execFile } from "node:child_process";
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
import { Session as SessionSchema, type Session } from "@acro/protocol";
import { encodeOutFrame, decodeFrame, FRAME_IN } from "@acro/protocol";
import { paths, ensureStateDirs } from "../paths.ts";
import { readJson, writeJsonAtomic } from "../store.ts";
import {
  DAEMON_PROTOCOL_VERSION,
  FrameReader,
  KIND_BIN,
  KIND_JSON,
  packBin,
  packJson,
} from "./wire.ts";
import { utf8SafeCut } from "./utf8.ts";

const SCROLLBACK = 5000;
const CHECKPOINT_INTERVAL_MS = 20_000;
// 输出微批(orca daemon-stream-data-batcher 思路):
// pty 以 ~1KB 粒度吐块,逐块广播会用 5 万条消息发 50MB,吞吐被消息开销钉死。
// setImmediate 聚合不到东西(每个 pty 读事件独占一个循环轮次),必须用时间窗:
// 洪峰时 256KB 上限主导(立即发),涓流时 4ms 窗口封顶交互延迟。
const OUT_BATCH_MAX_BYTES = 256 * 1024;
const OUT_BATCH_WINDOW_MS = 4;
// 静默超过该值后的第一块走立即路径:打字回显不吃 4ms 窗口
const OUT_BATCH_IDLE_MS = 30;
// 解析队列合并写入:xterm 大串解析远快于 5 万次 1KB await;
// 上限压在 256KB,单次解析不超过 ~10ms,输入帧不会被长时间卡住
const PARSE_MERGE_MAX_CHARS = 256 * 1024;

// esbuild cjs 打包形态下用自带的 require;ESM 源码运行时走 createRequire
declare const require: NodeRequire | undefined;

// 开发环境的 pnpm 解包可能丢执行位;发布包在签名前已修好,不要触碰已签名文件
function ensureSpawnHelperExecutable(): void {
  const requireFn = typeof require === "function" ? require : createRequire(import.meta.url);
  const ptyDir = path.dirname(requireFn.resolve("node-pty/package.json"));
  for (const arch of ["darwin-arm64", "darwin-x64"]) {
    const helper = path.join(ptyDir, "prebuilds", arch, "spawn-helper");
    if (!fs.existsSync(helper)) continue;
    try {
      fs.accessSync(helper, fs.constants.X_OK);
    } catch {
      fs.chmodSync(helper, 0o755);
    }
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
  private hasCommand = false;
  private term: Terminal;
  private serializer: SerializeAddon;
  private seq = 0;
  private parsedSeq = 0;
  private queue: QueueItem[] = [];
  private pumping = false;
  private dirty = false;
  private outChunks: Buffer[] = [];
  private outBytes = 0;
  private outFlushScheduled = false;
  private lastFlushAt = 0;
  private lastOutputAt = 0;
  // 输入帧可能切在多字节 UTF-8 字符中间;残留的尾字节缓冲到下一帧再拼
  private inputTail = Buffer.alloc(0);
  private removeOnExit = false;
  private exited: Promise<void>;
  private resolveExit!: () => void;

  private onOutput: (handle: number, seq: number, data: Buffer) => void;
  private onExit: (session: DaemonSession, removed: boolean) => void;

  constructor(
    opts: {
      cwd?: string | undefined;
      command?: string | undefined;
      cols: number;
      rows: number;
    },
    onOutput: (handle: number, seq: number, data: Buffer) => void,
    onExit: (session: DaemonSession, removed: boolean) => void,
  ) {
    this.onOutput = onOutput;
    this.onExit = onExit;
    this.exited = new Promise((resolve) => {
      this.resolveExit = resolve;
    });
    this.hasCommand = opts.command !== undefined;
    const shell = process.env.SHELL ?? "/bin/zsh";
    const cwd = opts.cwd ?? os.homedir();
    const args = opts.command ? ["-lc", opts.command] : ["-l"];
    this.meta = {
      id: crypto.randomUUID(),
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
      this.lastOutputAt = Date.now();
      const buf = Buffer.from(data, "utf8");
      this.outChunks.push(buf);
      this.outBytes += buf.byteLength;
      if (this.outBytes >= OUT_BATCH_MAX_BYTES) {
        this.flushOutput();
      } else if (!this.outFlushScheduled) {
        this.outFlushScheduled = true;
        const flush = () => {
          this.outFlushScheduled = false;
          this.flushOutput();
        };
        // 交互快路径 vs 洪峰时间窗
        if (Date.now() - this.lastFlushAt > OUT_BATCH_IDLE_MS) {
          setImmediate(flush);
        } else {
          setTimeout(flush, OUT_BATCH_WINDOW_MS);
        }
      }
      this.queue.push({ kind: "chunk", data, seq: this.seq });
      void this.pump();
    });
    this.ptyProc.onExit(({ exitCode }) => {
      // 尾批先于 exit 事件送出,客户端不会丢最后一段输出
      this.flushOutput();
      this.meta.alive = false;
      this.meta.exitCode = exitCode;
      if (!this.removeOnExit) this.checkpoint();
      this.onExit(this, this.removeOnExit);
      this.resolveExit();
    });
  }

  // 把积压的输出块并成一帧广播;帧 seq = 批内最后一块的 seq
  private flushOutput(): void {
    if (this.outChunks.length === 0) return;
    const data = this.outChunks.length === 1 ? this.outChunks[0]! : Buffer.concat(this.outChunks);
    this.outChunks = [];
    this.outBytes = 0;
    this.lastFlushAt = Date.now();
    this.onOutput(this.handle, this.seq, data);
  }

  // 快照进同一条解析队列,保证 snapshot 恰好覆盖 seq<=snapshotSeq 的输出:
  // 之后的帧 seq 更大,runtime 按 attachSeq 过滤,不重不漏。
  // 入队前先 flush,保证没有一帧同时携带快照前后的字节。
  snapshot(): Promise<{ seq: number; snapshot: string }> {
    this.flushOutput();
    return new Promise((resolve) => {
      this.queue.push({ kind: "snapshot", resolve });
      void this.pump();
    });
  }

  private async pump(): Promise<void> {
    if (this.pumping) return;
    this.pumping = true;
    while (this.queue.length > 0) {
      if (this.queue[0]!.kind === "snapshot") {
        const item = this.queue.shift()!;
        item.resolve!({
          seq: this.parsedSeq,
          snapshot: this.serializer.serialize({ scrollback: SCROLLBACK }),
        });
        continue;
      }
      // 合并连续输出块一次性解析
      let merged = "";
      let lastSeq = this.parsedSeq;
      while (
        this.queue.length > 0 &&
        this.queue[0]!.kind === "chunk" &&
        merged.length < PARSE_MERGE_MAX_CHARS
      ) {
        const item = this.queue.shift()!;
        merged += item.data!;
        lastSeq = item.seq!;
      }
      await new Promise<void>((r) => this.term.write(merged, r));
      this.parsedSeq = lastSeq;
    }
    this.pumping = false;
  }

  // 命令型会话(zsh -lc cmd)的 cd 发生在 zsh 的子进程里,向下解析一层;
  // 交互型会话 pty 进程就是用户 shell,直接用它
  private resolveCwdPid(): Promise<number> {
    if (!this.hasCommand) return Promise.resolve(this.ptyProc.pid);
    return new Promise((resolve) => {
      execFile("pgrep", ["-P", String(this.ptyProc.pid)], { timeout: 1000 }, (err, out) => {
        const first = err ? NaN : Number(out.trim().split("\n")[0]);
        resolve(Number.isFinite(first) && first > 0 ? first : this.ptyProc.pid);
      });
    });
  }

  // 实时工作目录:查 PTY shell 进程的 cwd(macOS 没有 pwdx,走 lsof)。
  // 只在"新终端继承路径"时按需调用,不轮询。
  async currentCwd(): Promise<string | null> {
    if (!this.meta.alive) return null;
    const lsof = process.platform === "darwin" ? "/usr/sbin/lsof" : "lsof";
    const pid = await this.resolveCwdPid();
    return new Promise((resolve) => {
      execFile(lsof, ["-a", "-p", String(pid), "-d", "cwd", "-Fn"], { timeout: 2000 },
        (err, stdout) => {
          if (err) return resolve(null);
          const line = stdout.split("\n").find((l) => l.startsWith("n"));
          const cwd = line && line.length > 1 ? line.slice(1) : null;
          // spawn-helper chdir 前的瞬间窗口里,子进程 cwd 还是 daemon 自己的;
          // 这种读数不可信,回退用会话档案里的目录
          resolve(cwd === process.cwd() ? null : cwd);
        },
      );
    });
  }

  write(data: Buffer): void {
    if (!this.meta.alive) return;
    const buf = this.inputTail.byteLength ? Buffer.concat([this.inputTail, data]) : data;
    const cut = utf8SafeCut(buf);
    // 末尾不完整序列留到下一帧;Buffer.from 拷出,不悬引 concat 的底层内存
    this.inputTail = cut < buf.byteLength ? Buffer.from(buf.subarray(cut)) : Buffer.alloc(0);
    if (cut > 0) this.ptyProc.write(buf.subarray(0, cut).toString("utf8"));
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

  async remove(): Promise<void> {
    if (this.removeOnExit) return this.exited;
    this.removeOnExit = true;
    const forceKill = setTimeout(() => {
      if (!this.meta.alive) return;
      try {
        this.ptyProc.kill("SIGKILL");
      } catch {}
    }, 2000);
    forceKill.unref();
    try {
      this.kill();
      await this.exited;
    } finally {
      clearTimeout(forceKill);
    }
  }

  checkpoint(): void {
    const dir = path.join(paths.sessions, this.meta.id);
    fs.mkdirSync(dir, { recursive: true });
    writeJsonAtomic(path.join(dir, "meta.json"), this.meta);
    void this.snapshot().then(({ snapshot }) => {
      if (!this.removeOnExit) fs.writeFileSync(path.join(dir, "snapshot.txt"), snapshot);
    });
    this.dirty = false;
  }

  // checkpoint 的 scrollback 序列化是同步重活;只在输出静默后做,
  // 洪峰期间不制造周期性输入卡顿(崩溃窗口略拉长,可接受)
  checkpointIfDirty(): void {
    if (this.dirty && Date.now() - this.lastOutputAt > 2000) this.checkpoint();
  }
}

// ---- 会话表:活会话 + 上一个 boot 留下的死会话记录 ----

const live = new Map<string, DaemonSession>();
const dead = new Map<string, Session>();

function loadDeadSessions(): void {
  if (!fs.existsSync(paths.sessions)) return;
  for (const id of fs.readdirSync(paths.sessions)) {
    const metaPath = path.join(paths.sessions, id, "meta.json");
    const stored = readJson<unknown>(metaPath, null);
    const parsed = SessionSchema.safeParse(stored);
    if (!parsed.success) continue;
    const meta = parsed.data;
    // 上一个 daemon 进程死掉时还活着的会话,现在必然已死
    if (meta.alive) {
      meta.alive = false;
      meta.exitCode = null;
    }
    // 旧版本可能留下已废弃字段；按协议真源重写，避免内部状态继续携带。
    writeJsonAtomic(metaPath, meta);
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

function handleExit(session: DaemonSession, removed: boolean): void {
  live.delete(session.meta.id);
  if (!removed) dead.set(session.meta.id, session.meta);
  emitEvent("session.exit", { sessionId: session.meta.id, exitCode: session.meta.exitCode });
}

type Handler = (params: any) => Promise<unknown> | unknown;

const handlers: Record<string, Handler> = {
  "daemon.info": () => ({ boot, pid: process.pid, protocolVersion: DAEMON_PROTOCOL_VERSION }),
  "session.create": (params: {
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
  "session.cwd": async (params: { sessionId: string }) => {
    const session = live.get(params.sessionId);
    if (!session) throw new Error("session not alive");
    const cwd = await session.currentCwd();
    if (cwd && cwd !== session.meta.cwd) {
      // 会话档案跟随事实:session.list 逐步反映真实目录
      session.meta.cwd = cwd;
      session.checkpoint();
    }
    return { cwd: cwd ?? session.meta.cwd };
  },
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
  "session.remove": async (params: { sessionId: string }) => {
    await live.get(params.sessionId)?.remove();
    dead.delete(params.sessionId);
    fs.rmSync(path.join(paths.sessions, params.sessionId), { recursive: true, force: true });
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
  // currentCwd() 把"读数 == daemon 自身 cwd"当作 spawn 未就绪的噪音丢弃;
  // daemon 挪到 state 目录,避免与用户会话目录(常见是家目录)撞车导致误判
  try {
    process.chdir(paths.state);
  } catch {
    // state 目录不可进入时保持原样,只是误判窗口回归
  }

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
