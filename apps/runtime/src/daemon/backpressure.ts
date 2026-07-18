export const PARSE_BACKLOG_HIGH_CHARS = 4 * 1024 * 1024;
export const PARSE_BACKLOG_LOW_CHARS = 1024 * 1024;
export const MAX_DAEMON_CLIENT_BUFFER_BYTES = 8 * 1024 * 1024;

export function shouldPausePty(paused: boolean, backlogChars: number): boolean {
  return paused
    ? backlogChars > PARSE_BACKLOG_LOW_CHARS
    : backlogChars >= PARSE_BACKLOG_HIGH_CHARS;
}

export function daemonClientBufferExceeded(bufferedBytes: number, nextBytes: number): boolean {
  return bufferedBytes + nextBytes > MAX_DAEMON_CLIENT_BUFFER_BYTES;
}
