import type { Session } from "@acro/protocol";
import { paths } from "../paths.ts";
import { readJson } from "../store.ts";

const SESSION_REMOVAL_BATCH_SIZE = 16;

export interface DaemonRequester {
  request(method: string, params?: unknown): Promise<unknown>;
}

export function untrackedDeadSessionIds(
  sessions: readonly Pick<Session, "id" | "alive">[],
  trackedSessionIds: ReadonlySet<string>,
): string[] {
  return sessions
    .filter((session) => !session.alive && !trackedSessionIds.has(session.id))
    .map((session) => session.id);
}

export async function removeDaemonSession(
  daemon: DaemonRequester,
  sessionId: string,
): Promise<boolean> {
  try {
    const result = (await daemon.request("session.remove", { sessionId })) as
      | { removed?: boolean }
      | undefined;
    return result?.removed ?? true;
  } catch (error) {
    if (error instanceof Error && error.message === "unknown method session.remove") {
      await daemon.request("session.kill", { sessionId });
      return true;
    }
    throw error;
  }
}

export async function removeDaemonSessions(
  daemon: DaemonRequester,
  sessionIds: readonly string[],
): Promise<void> {
  for (let offset = 0; offset < sessionIds.length; offset += SESSION_REMOVAL_BATCH_SIZE) {
    await Promise.all(
      sessionIds
        .slice(offset, offset + SESSION_REMOVAL_BATCH_SIZE)
        .map((sessionId) => removeDaemonSession(daemon, sessionId)),
    );
  }
}

export async function restartTerminalDaemon(
  daemon: DaemonRequester,
  signal: (pid: number, signal: NodeJS.Signals) => unknown = process.kill,
  readIdentity: () => unknown = () => readJson<unknown>(paths.daemonMeta, null),
): Promise<void> {
  try {
    await daemon.request("daemon.restart");
    return;
  } catch (error) {
    if (!(error instanceof Error) || error.message !== "unknown method daemon.restart") {
      throw error;
    }
  }

  const info = (await daemon.request("daemon.info")) as { pid?: unknown; boot?: unknown };
  const persisted = readIdentity() as { pid?: unknown; boot?: unknown } | null;
  if (
    typeof info.pid !== "number" ||
    !Number.isSafeInteger(info.pid) ||
    info.pid <= 1 ||
    info.pid === process.pid ||
    typeof info.boot !== "string" ||
    info.boot.length === 0 ||
    persisted?.pid !== info.pid ||
    persisted?.boot !== info.boot
  ) {
    throw new Error("invalid terminal daemon identity");
  }
  signal(info.pid, "SIGTERM");
}
