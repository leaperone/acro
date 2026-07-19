const SESSION_REMOVAL_BATCH_SIZE = 16;

export interface DaemonRequester {
  request(method: string, params?: unknown): Promise<unknown>;
}

async function removeDaemonSession(daemon: DaemonRequester, sessionId: string): Promise<void> {
  try {
    await daemon.request("session.remove", { sessionId });
  } catch (error) {
    if (error instanceof Error && error.message.includes("unknown method")) {
      await daemon.request("session.kill", { sessionId });
      return;
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
