// 文件浏览器数据层(只读)。文件在 Mac mini 上,runtime 进程直接读盘;
// 客户端经 fs.list / fs.read RPC 获取。策略参考 orca:双级上限、前 8KB 探二进制、
// 图片走 base64、文本超限截断。只读——不提供写/删/改(那属于终端 Agent 的边界)。

import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import type { FileContent, FileEntry, SearchHit } from "@acro/protocol";

// 文本预览上限;超过则截断并置 truncated(截断的内容禁止在客户端当可编辑)
const TEXT_PREVIEW_MAX_BYTES = 512 * 1024;
// 图片预览硬上限;超过直接当二进制降级(不整块 base64 传超大图)
const IMAGE_PREVIEW_MAX_BYTES = 10 * 1024 * 1024;
// 二进制探测:只读前 8KB 看有无 NUL 字节
const BINARY_PROBE_BYTES = 8192;

// 扩展名 → 图片 MIME。SVG 故意排除:当作文本(XML)预览更有用。
const IMAGE_MIME: Record<string, string> = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".bmp": "image/bmp",
  ".ico": "image/x-icon",
  ".heic": "image/heic",
  ".tiff": "image/tiff",
};

// 把用户传入的 path 规范化成绝对路径。空串 = home。~ 展开。
// 单租户自有机器 + 设备鉴权,不做根沙箱;但规范化 .. 与展开,避免歧义路径。
function resolvePath(input: string): string {
  const raw = input.trim();
  if (raw === "") return os.homedir();
  const expanded = raw === "~" || raw.startsWith("~/")
    ? path.join(os.homedir(), raw.slice(1))
    : raw;
  return path.resolve(expanded);
}

function entryKind(dirent: {
  isDirectory(): boolean;
  isSymbolicLink(): boolean;
  isFile(): boolean;
}): FileEntry["kind"] {
  if (dirent.isSymbolicLink()) return "symlink";
  if (dirent.isDirectory()) return "dir";
  if (dirent.isFile()) return "file";
  return "other";
}

// 列目录。目录优先、再按名不区分大小写排序(与 cmux/Finder 一致)。
// 软链按其目标解析成 dir/file(方便树展开),解析失败降级 symlink。
export async function list(input: string): Promise<FileEntry[]> {
  const dir = resolvePath(input);
  const dirents = await fs.readdir(dir, { withFileTypes: true });
  const entries = await Promise.all(
    dirents.map(async (dirent): Promise<FileEntry> => {
      const full = path.join(dir, dirent.name);
      let kind = entryKind(dirent);
      let size = 0;
      let mtimeMs = 0;
      try {
        // stat 跟随软链:让指向目录的软链能被当目录展开
        const st = await fs.stat(full);
        if (kind === "symlink") kind = st.isDirectory() ? "dir" : st.isFile() ? "file" : "other";
        size = st.isFile() ? st.size : 0;
        mtimeMs = st.mtimeMs;
      } catch {
        // 悬空软链等:保留 dirent 判定,size/mtime 置 0
        try {
          const lst = await fs.lstat(full);
          mtimeMs = lst.mtimeMs;
        } catch {
          /* 无法 stat:跳过时间戳 */
        }
      }
      return { name: dirent.name, path: full, kind, size, mtimeMs };
    }),
  );
  entries.sort((a, b) => {
    const aDir = a.kind === "dir";
    const bDir = b.kind === "dir";
    if (aDir !== bDir) return aDir ? -1 : 1;
    return a.name.localeCompare(b.name, undefined, { sensitivity: "base" });
  });
  return entries;
}

function isBinaryBuffer(buf: Buffer): boolean {
  const n = Math.min(buf.length, BINARY_PROBE_BYTES);
  for (let i = 0; i < n; i++) {
    if (buf[i] === 0) return true;
  }
  return false;
}

// 读文件预览。判定顺序(参考 orca):
// stat 大小 → 图片扩展名?(≤10MB 走 base64,否则二进制降级)
// → 前 8KB 探 NUL(二进制降级)→ 按上限截断的 UTF-8 文本。
export async function read(input: string, maxBytes?: number): Promise<FileContent> {
  const file = resolvePath(input);
  const st = await fs.stat(file);
  if (st.isDirectory()) {
    throw new Error("path is a directory");
  }
  const size = st.size;
  const ext = path.extname(file).toLowerCase();
  const imageMime = IMAGE_MIME[ext];

  if (imageMime) {
    if (size > IMAGE_PREVIEW_MAX_BYTES) {
      return { path: file, kind: "binary", text: null, base64: null, mime: imageMime, size, truncated: false };
    }
    const buf = await fs.readFile(file);
    return { path: file, kind: "image", text: null, base64: buf.toString("base64"), mime: imageMime, size, truncated: false };
  }

  const limit = Math.max(1, Math.min(maxBytes ?? TEXT_PREVIEW_MAX_BYTES, TEXT_PREVIEW_MAX_BYTES));
  const handle = await fs.open(file, "r");
  try {
    const readLen = Math.min(size, limit);
    const buf = Buffer.alloc(readLen);
    await handle.read(buf, 0, readLen, 0);
    if (isBinaryBuffer(buf)) {
      return { path: file, kind: "binary", text: null, base64: null, mime: null, size, truncated: false };
    }
    const truncated = size > readLen;
    return { path: file, kind: "text", text: buf.toString("utf8"), base64: null, mime: null, size, truncated };
  } finally {
    await handle.close();
  }
}

const SEARCH_DEFAULT_MAX_RESULTS = 500;
const SEARCH_TIMEOUT_MS = 15_000;

// 内容搜索。优先 ripgrep(尊重 .gitignore、跳过 .git、快);缺则退回系统 grep。
// 结果达上限即杀进程返回;超时也杀。
export async function search(
  input: string,
  query: string,
  maxResults?: number,
): Promise<SearchHit[]> {
  const root = resolvePath(input);
  const cap = Math.max(1, Math.min(maxResults ?? SEARCH_DEFAULT_MAX_RESULTS, 2000));
  try {
    return await runSearch(
      "rg",
      ["--vimgrep", "--smart-case", "--no-heading", "--color", "never", "--max-columns", "300",
       "-e", query, "--", root],
      cap,
      true,
    );
  } catch (err) {
    // rg 未安装:退回 grep(始终存在)。其余错误(如无匹配)已在 runSearch 里当空结果处理。
    if ((err as NodeJS.ErrnoException)?.code === "ENOENT") {
      return runSearch(
        "grep",
        ["-rIn", "--exclude-dir=.git", "--exclude-dir=node_modules", "-e", query, root],
        cap,
        false,
      );
    }
    throw err;
  }
}

// hasColumn: rg --vimgrep 是 path:line:col:text;grep -n 是 path:line:text(无列)。
function runSearch(
  cmd: string,
  args: string[],
  cap: number,
  hasColumn: boolean,
): Promise<SearchHit[]> {
  return new Promise((resolve, reject) => {
    const hits: SearchHit[] = [];
    let buffer = "";
    let settled = false;
    const child = spawn(cmd, args, { stdio: ["ignore", "pipe", "ignore"] });
    const timer = setTimeout(() => finish(), SEARCH_TIMEOUT_MS);

    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      child.kill();
      resolve(hits);
    };

    child.on("error", (err) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(err);
    });

    child.stdout.on("data", (chunk: Buffer) => {
      buffer += chunk.toString("utf8");
      let nl: number;
      while ((nl = buffer.indexOf("\n")) !== -1) {
        const line = buffer.slice(0, nl);
        buffer = buffer.slice(nl + 1);
        const hit = parseLine(line, hasColumn);
        if (hit) hits.push(hit);
        if (hits.length >= cap) return finish();
      }
    });

    // rg/grep 无匹配时退出码为 1,不是错误;正常返回已收集的(空)结果。
    child.on("close", () => finish());
  });
}

function parseLine(line: string, hasColumn: boolean): SearchHit | null {
  const re = hasColumn ? /^(.+?):(\d+):(\d+):(.*)$/ : /^(.+?):(\d+):(.*)$/;
  const m = line.match(re);
  if (!m) return null;
  if (hasColumn) {
    return { path: m[1]!, line: Number(m[2]), column: Number(m[3]), preview: m[4]!.slice(0, 300) };
  }
  return { path: m[1]!, line: Number(m[2]), column: 0, preview: m[3]!.slice(0, 300) };
}
