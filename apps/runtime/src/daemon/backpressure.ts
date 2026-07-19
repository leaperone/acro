export const PARSE_BACKLOG_HIGH_CHARS = 4 * 1024 * 1024;
export const PARSE_BACKLOG_LOW_CHARS = 1024 * 1024;
export const MAX_DAEMON_CLIENT_BUFFER_BYTES = 8 * 1024 * 1024;
// daemon 跨 runtime 重启持有 PTY；在 spawn 前限流，避免已配对设备耗尽主机进程和内存。
export const MAX_LIVE_SESSIONS = 128;
// 包含等待快照串行队列的请求；客户端超时后也不能继续把 daemon 工作队列撑大。
export const MAX_DAEMON_REQUESTS = 64;

export function shouldPausePty(paused: boolean, backlogChars: number): boolean {
  return paused
    ? backlogChars > PARSE_BACKLOG_LOW_CHARS
    : backlogChars >= PARSE_BACKLOG_HIGH_CHARS;
}

export function daemonClientBufferExceeded(bufferedBytes: number, nextBytes: number): boolean {
  return bufferedBytes + nextBytes > MAX_DAEMON_CLIENT_BUFFER_BYTES;
}

export function daemonSessionCapacityExceeded(liveSessions: number): boolean {
  return liveSessions >= MAX_LIVE_SESSIONS;
}

export function daemonRequestCapacityExceeded(inFlightRequests: number): boolean {
  return inFlightRequests >= MAX_DAEMON_REQUESTS;
}

export function daemonRequestExpired(deadline: unknown, now = Date.now()): boolean {
  return (
    deadline !== undefined &&
    (typeof deadline !== "number" || !Number.isFinite(deadline) || now >= deadline)
  );
}
