// 监听端口数据层(只读)。列出正在 LISTEN 的 TCP 端口 + 占用进程。
// macOS 走 lsof;Linux/WSL 走 iproute2 的 ss(Ubuntu/Debian 默认自带,不依赖可选的 lsof)。
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

// 解析 `ss -tlnpH` 每行:State Recv-Q Send-Q Local:Port Peer:Port [users:(("cmd",pid=N,fd=M),…)]。
// 无 -p 权限(非本用户 socket)时进程段缺失,pid/process 记 0/空,端口仍列出。
export function parseSs(stdout: string): PortListener[] {
  const seen = new Set<string>();
  const out: PortListener[] = [];
  for (const line of stdout.split("\n")) {
    const cols = line.trim().split(/\s+/);
    if (cols.length < 4) continue;
    const local = cols[3]!; // 0.0.0.0:80 / [::]:80 / 127.0.0.1:5432 / *:5173
    const idx = local.lastIndexOf(":");
    if (idx < 0) continue;
    const address = local.slice(0, idx).replace(/^\[|\]$/g, ""); // 去掉 IPv6 方括号
    const port = Number(local.slice(idx + 1));
    if (!Number.isInteger(port) || port <= 0) continue;
    // 进程信息在末段 users:(("cmd",pid=123,fd=4),…);取第一个即可
    const m = /\("([^"]+)",pid=(\d+)/.exec(cols.slice(4).join(" "));
    const command = m ? m[1]! : "";
    const pid = m ? Number(m[2]) : 0;
    const key = `${address}:${port}:${pid}`;
    if (seen.has(key)) continue; // v4/v6 通配可能重复
    seen.add(key);
    out.push({ port, address, pid, process: command });
  }
  out.sort((a, b) => a.port - b.port);
  return out;
}

async function listWith(
  cmd: string,
  args: string[],
  parse: (stdout: string) => PortListener[],
): Promise<PortListener[]> {
  try {
    const { stdout } = await exec(cmd, args, { encoding: "utf8", maxBuffer: 4 * 1024 * 1024 });
    return parse(stdout);
  } catch (err) {
    // 命令未安装:返回空。lsof/ss 无匹配时退出码非 0,stdout 仍带已列出记录(execFile 塞进 error)。
    if ((err as NodeJS.ErrnoException).code === "ENOENT") return [];
    return parse((err as { stdout?: string }).stdout ?? "");
  }
}

export async function list(): Promise<PortListener[]> {
  return process.platform === "darwin"
    ? listWith("lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-FpcnP"], parseLsof)
    : listWith("ss", ["-tlnpH"], parseSs);
}
