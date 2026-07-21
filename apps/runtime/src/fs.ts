// 文件浏览器数据层(只读)。文件在 Mac mini 上,runtime 进程直接读盘;
// 客户端经 fs.list / fs.read RPC 获取。策略参考 orca:双级上限、前 8KB 探二进制、
// 图片走 base64、文本超限截断。只读——不提供写/删/改(那属于终端 Agent 的边界)。

import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import type { FileContent, FileEntry } from "@acro/protocol";

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
