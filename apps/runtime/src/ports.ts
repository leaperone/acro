// 监听端口数据层(只读)。进程在 Mac mini 上,runtime 跑 lsof 列出正在 LISTEN 的 TCP 端口。
// 只读展示——不 kill 进程、不改端口。用 execFile + 数组参数,无 shell 注入面。

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { PortListener } from "@acro/protocol";

const exec = promisify(execFile);

// 解析 lsof -F 字段输出。记录按进程分组:p<pid> / c<command>,随后每个文件一条 n<name>。
export function parseLsof(stdout: string): PortListener[] {
  const seen = new Set<string>();
  const out: PortListener[] = [];
  let pid = 0;
  let command = "";
  for (const line of stdout.split("\n")) {
    if (!line) continue;
    const tag = line[0];
    const value = line.slice(1);
    if (tag === "p") pid = Number(value) || 0;
    else if (tag === "c") command = value;
    else if (tag === "n") {
      // value 形如 127.0.0.1:3000 / *:5173 / [::1]:8080 / *:* 。取最后一个冒号后为端口。
      const idx = value.lastIndexOf(":");
      if (idx < 0) continue;
      const address = value.slice(0, idx);
      const port = Number(value.slice(idx + 1));
      if (!Number.isInteger(port) || port <= 0) continue;
      const key = `${address}:${port}:${pid}`;
      if (seen.has(key)) continue; // lsof 会把 IPv4/IPv6 各列一次,去重
      seen.add(key);
      out.push({ port, address, pid, process: command });
    }
  }
  out.sort((a, b) => a.port - b.port);
  return out;
}

export async function list(): Promise<PortListener[]> {
  try {
    const { stdout } = await exec(
      "lsof",
      ["-nP", "-iTCP", "-sTCP:LISTEN", "-FpcnP"],
      { encoding: "utf8", maxBuffer: 4 * 1024 * 1024 },
    );
    return parseLsof(stdout);
  } catch (err) {
    // lsof 未安装:返回空。lsof 无匹配时退出码为 1,stdout 仍带已列出的记录(execFile 塞进 error)。
    if ((err as NodeJS.ErrnoException).code === "ENOENT") return [];
    const stdout = (err as { stdout?: string }).stdout ?? "";
    return parseLsof(stdout);
  }
}
