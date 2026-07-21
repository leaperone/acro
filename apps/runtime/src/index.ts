import crypto from "node:crypto";
import http from "node:http";
import os from "node:os";
import type { Session, Workspace } from "@acro/protocol";
import { loadConfig } from "./config.ts";
import { DeviceRegistry } from "./devices.ts";
import { DaemonClient } from "./daemon/client.ts";
import {
  removeDaemonSession,
  removeDaemonSessions,
  restartTerminalDaemon,
  untrackedDeadSessionIds,
} from "./daemon/session-cleanup.ts";
import { BrowserManager } from "./browser.ts";
import { SimulatorManager } from "./simulator.ts";
import { HelperClient } from "./computer.ts";
import { WorkspaceRegistry } from "./workspaces.ts";
import * as fsBrowser from "./fs.ts";
import * as gitStatus from "./git.ts";
import { createHttpHandler } from "./http.ts";
import {
  clearBootstrapOffer,
  createShareOffer,
  ensureBootstrapOffer,
  ensureLocalOffer,
  ServerIdentity,
} from "./share.ts";
import { Gateway, removeSurfaceChannels, type Conn, type Handlers } from "./ws.ts";
import { ensureStateDirs, paths } from "./paths.ts";
import { acquireProcessLock } from "./process-lock.ts";
import { ExclusiveRunner } from "./exclusive.ts";

interface SnapshotResult {
  handle: number;
  seq: number;
  snapshot: string;
  cols: number;
  rows: number;
}

const UNTRACKED_SESSION_CLEANUP_GRACE_MS = Number(
  process.env.ACRO_TEST_SESSION_CLEANUP_GRACE_MS ?? 120_000,
);

function daemonMayHaveCreatedSession(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return (
    message.includes("connection lost") ||
    message.includes("EPIPE") ||
    message.includes("ECONNRESET") ||
    message.includes("daemon timeout:")
  );
}

async function main(): Promise<void> {
  ensureStateDirs();
  const releaseLock = acquireProcessLock(paths.runtimeLock, "runtime");
  process.once("exit", releaseLock);
  const config = loadConfig();
  const registry = new DeviceRegistry();
  registry.migrateLegacyLocalGrants();
  const identity = new ServerIdentity();
  let localOffer = ensureLocalOffer(registry, identity, config.port);
  const needsBootstrap = !registry.list().some((device) => device.lastSeenAt !== null);
  const daemon = await DaemonClient.connect();
  const browsers = new BrowserManager();
  const simulators = new SimulatorManager();
  const helper = new HelperClient();
  const workspaces = new WorkspaceRegistry();
  const exclusive = new ExclusiveRunner();
  const runWorkspaceExclusive = <T>(
    workspaceId: string,
    task: () => T | Promise<T>,
    signal?: AbortSignal,
  ): Promise<T> => exclusive.run(`workspace:${workspaceId}`, task, signal);
  for (const workspace of workspaces.listPendingRemovals()) {
    await removeDaemonSessions(daemon, workspace.sessionIds);
    workspaces.remove(workspace.id);
  }
  const creatingSessionIds = new Set<string>();
  const sessionCleanupTimers = new Map<string, NodeJS.Timeout>();
  const sessionIsTracked = (sessionId: string): boolean =>
    workspaces.list().some((workspace) => workspace.sessionIds.includes(sessionId));
  const cancelScheduledSessionCleanup = (sessionId: string): void => {
    const timer = sessionCleanupTimers.get(sessionId);
    if (timer) clearTimeout(timer);
    sessionCleanupTimers.delete(sessionId);
  };
  const scheduleUntrackedSessionCleanup = (sessionId: string): void => {
    if (sessionCleanupTimers.has(sessionId) || sessionIsTracked(sessionId)) return;
    const timer = setTimeout(() => {
      sessionCleanupTimers.delete(sessionId);
      if (sessionIsTracked(sessionId)) return;
      void removeDaemonSession(daemon, sessionId).catch((error) => {
        console.warn(`[runtime] failed to remove untracked session ${sessionId}: ${error.message}`);
      });
    }, UNTRACKED_SESSION_CLEANUP_GRACE_MS);
    timer.unref();
    sessionCleanupTimers.set(sessionId, timer);
  };
  const reconcileWorkspaceSessions = async (): Promise<Session[]> => {
    const tracked = new Set(workspaces.list().flatMap((workspace) => workspace.sessionIds));
    const sessions = await daemon.request<Session[]>("session.list");
    const known = new Set(sessions.map((session) => session.id));
    const missing = new Set(
      [...tracked].filter((id) => !known.has(id) && !creatingSessionIds.has(id)),
    );
    workspaces.removeSessions(missing);
    for (const sessionId of untrackedDeadSessionIds(sessions, tracked)) {
      scheduleUntrackedSessionCleanup(sessionId);
    }
    return sessions;
  };
  const ensureLiveWorkspaceSession = async (): Promise<void> => {
    const hasTrackedLiveSession = (
      daemonSessions: readonly Session[],
      storedWorkspaces: readonly Workspace[],
    ): boolean => {
      const liveSessionIds = new Set(
        daemonSessions.filter((session) => session.alive).map((session) => session.id),
      );
      return storedWorkspaces.some((workspace) =>
        workspace.sessionIds.some((id) => liveSessionIds.has(id)),
      );
    };
    if (hasTrackedLiveSession(await reconcileWorkspaceSessions(), workspaces.list())) return;

    for (;;) {
      const candidates = workspaces.list().filter(
        (workspace) => !workspaces.isRemovalPending(workspace.id),
      );
      const createdWorkspace = candidates.length === 0;
      const candidate = candidates[0] ?? workspaces.create();
      const restored = await runWorkspaceExclusive(candidate.id, async () => {
        const workspace = workspaces.get(candidate.id);
        if (!workspace || workspaces.isRemovalPending(candidate.id)) return false;
        if (hasTrackedLiveSession(await reconcileWorkspaceSessions(), workspaces.list())) {
          return true;
        }

        const sessionId = crypto.randomUUID();
        workspaces.addSession(workspace.id, sessionId);
        try {
          await daemon.request<{ session: Session; handle: number }>(
            "session.createOwned",
            { id: sessionId, cwd: os.homedir(), cols: 140, rows: 40 },
          );
        } catch (error) {
          if (!daemonMayHaveCreatedSession(error)) {
            workspaces.removeSession(workspace.id, sessionId);
            if (createdWorkspace && workspaces.get(workspace.id)?.sessionIds.length === 0) {
              workspaces.remove(workspace.id);
            }
          }
          if ((error as Error).message === "unknown method session.createOwned") {
            throw new Error(
              "terminal daemon is outdated; close existing terminals, then restart the server Mac",
            );
          }
          throw error;
        }
        return true;
      });
      if (restored) return;
    }
  };
  await ensureLiveWorkspaceSession();
  // 终端占用:sessionId -> 占用设备。内存态即可,runtime 重启后由客户端重新认领
  const focusOwners = new Map<string, { deviceId: string; deviceName: string }>();
  const pendingFocusClaims = new Map<string, symbol>();
  // 浏览器画面可被多个设备查看,控制权按设备互斥;runtime 重启会连同页面一起关闭。
  const browserControlOwners = new Map<string, { deviceId: string; deviceName: string }>();
  let computerControlOwner: { deviceId: string; deviceName: string } | null = null;
  const runBrowserControl = <T>(browserId: string, task: () => T | Promise<T>): Promise<T> =>
    exclusive.run(`browser:${browserId}`, task);
  const runSessionControl = <T>(sessionId: string, task: () => T | Promise<T>): Promise<T> =>
    exclusive.run(`session:${sessionId}`, task);
  const runSessionSize = <T>(sessionId: string, task: () => T | Promise<T>): Promise<T> =>
    exclusive.run(`size:${sessionId}`, task);
  const runWorkspaceMutation = <T>(
    conn: Conn,
    workspaceId: string,
    task: () => T | Promise<T>,
  ): Promise<T> => runWorkspaceExclusive(workspaceId, task, conn.abortController.signal);
  const runComputerControl = <T>(task: () => T | Promise<T>): Promise<T> =>
    exclusive.run("computer", task);
  const requireActiveDevice = (conn: Conn): NonNullable<Conn["device"]> => {
    if (!conn.device || !gateway.hasConnection(conn)) throw new Error("connection closed");
    return conn.device;
  };
  const requireBrowserControl = (conn: Conn, browserId: string): void => {
    const device = requireActiveDevice(conn);
    const owner = browserControlOwners.get(browserId);
    if (!owner) throw new Error("browser control is not claimed");
    if (owner.deviceId !== device.id) {
      throw new Error("browser controlled by another device");
    }
  };
  const releaseBrowserControl = (browserId: string): void => {
    if (!browserControlOwners.delete(browserId)) return;
    emitRuntimeEvent("browser.controlChanged", {
      browserId,
      deviceId: null,
      deviceName: null,
    });
  };
  const setComputerControl = (owner: { deviceId: string; deviceName: string } | null): void => {
    computerControlOwner = owner;
    emitRuntimeEvent("computer.controlChanged", {
      deviceId: owner?.deviceId ?? null,
      deviceName: owner?.deviceName ?? null,
    });
  };
  const requireComputerControl = (conn: Conn): void => {
    const device = requireActiveDevice(conn);
    if (!computerControlOwner) throw new Error("computer control is not claimed");
    if (computerControlOwner.deviceId !== device.id) {
      throw new Error("computer controlled by another device");
    }
  };
  // 终端尺寸仲裁(tmux 模型):PTY 尺寸 = 各在挂客户端报告尺寸的最小值,
  // 谁都能看全;单靠 last-writer-wins 会让多端互相顶掉对方的尺寸。
  // 内存态:客户端重连后重新报告(attach 时同步一次 + SIGWINCH)。
  const sessionSizes = new Map<string, Map<Conn, { cols: number; rows: number }>>();
  const appliedSizes = new Map<string, { cols: number; rows: number }>();
  const applySessionSize = async (sessionId: string): Promise<void> => {
    const votes = [...(sessionSizes.get(sessionId)?.values() ?? [])];
    if (votes.length === 0) return;
    const cols = Math.min(...votes.map((v) => v.cols));
    const rows = Math.min(...votes.map((v) => v.rows));
    const applied = appliedSizes.get(sessionId);
    if (applied && applied.cols === cols && applied.rows === rows) return;
    await daemon.request("session.resize", { sessionId, cols, rows });
    appliedSizes.set(sessionId, { cols, rows });
  };
  const dropSizeVote = (conn: Conn, sessionId: string): Promise<void> =>
    runSessionSize(sessionId, async () => {
      const votes = sessionSizes.get(sessionId);
      if (!votes?.delete(conn)) return;
      if (votes.size === 0) sessionSizes.delete(sessionId);
      try {
        await applySessionSize(sessionId);
      } catch (error) {
        if ((error as Error).message !== "session not alive") throw error;
        sessionSizes.delete(sessionId);
        appliedSizes.delete(sessionId);
      }
    });

  const handlers: Handlers = {
    "device.list": () => registry.list(),
    "device.share": (_conn, { name, extraEndpoints }) =>
      createShareOffer(registry, identity, config.port, name, extraEndpoints),
    "device.revoke": (_conn, { deviceId }) => {
      const removed = registry.remove(deviceId);
      if (!removed) throw new Error("device not found");
      gateway.terminateDevice(deviceId);
      if (removed.id === localOffer.deviceId) {
        localOffer = ensureLocalOffer(registry, identity, config.port);
      }
      return { revoked: true };
    },
    "daemon.restart": async (conn) => {
      requireActiveDevice(conn);
      await restartTerminalDaemon(daemon);
      return { restarting: true };
    },
    "fs.list": (conn, { path }) => {
      requireActiveDevice(conn);
      return fsBrowser.list(path);
    },
    "fs.read": (conn, { path, maxBytes }) => {
      requireActiveDevice(conn);
      return fsBrowser.read(path, maxBytes);
    },
    "fs.search": (conn, { path, query, maxResults }) => {
      requireActiveDevice(conn);
      return fsBrowser.search(path, query, maxResults);
    },
    "git.status": (conn, { path }) => {
      requireActiveDevice(conn);
      return gitStatus.status(path);
    },
    "git.diff": (conn, { path }) => {
      requireActiveDevice(conn);
      return gitStatus.diff(path);
    },
    "workspace.list": () => workspaces.list(),
    "workspace.create": (_conn, { name, workspaceGroupId }) =>
      workspaces.create(name, workspaceGroupId),
    "workspace.update": (_conn, { workspaceId, name, workspaceGroupId }) => {
      if (!workspaces.get(workspaceId)) throw new Error("workspace not found");
      return workspaces.update(workspaceId, { name, workspaceGroupId });
    },
    "workspace.reorder": (_conn, { workspaceId, workspaceGroupId, index }) => {
      workspaces.reorder(workspaceId, workspaceGroupId, index);
      return { reordered: true };
    },
    "workspaceGroup.list": () => workspaces.listGroups(),
    "workspaceGroup.create": (_conn, { name }) => workspaces.createGroup(name),
    "workspaceGroup.update": (_conn, { workspaceGroupId, name }) =>
      workspaces.updateGroup(workspaceGroupId, name),
    "workspaceGroup.remove": (_conn, { workspaceGroupId }) => {
      workspaces.removeGroup(workspaceGroupId);
      return { removed: true };
    },
    "workspace.setLayout": (_conn, { workspaceId, layout }) => {
      const rev = workspaces.setLayout(workspaceId, layout);
      emitRuntimeEvent("workspace.layoutChanged", { workspaceId, rev });
      return { rev };
    },
    "workspace.remove": (conn, { workspaceId, force }) =>
      runWorkspaceMutation(conn, workspaceId, async () => {
        const workspace = workspaces.get(workspaceId);
        if (!workspace) throw new Error("workspace not found");
        const removalPending = workspaces.isRemovalPending(workspaceId);
        const sessions = await daemon.request<Session[]>("session.list");
        const hasActiveSessions = sessions.some(
          (session) => session.alive && workspace.sessionIds.includes(session.id),
        );
        if (hasActiveSessions && !force && !removalPending) {
          throw new Error("workspace has active sessions");
        }
        if (!removalPending) {
          conn.abortController.signal.throwIfAborted();
          workspaces.beginRemoval(workspaceId);
        }
        // 分批清理，历史会话再多也不会超过 daemon pending 预算。
        await removeDaemonSessions(daemon, workspace.sessionIds);
        for (const sessionId of workspace.sessionIds) {
          pendingFocusClaims.delete(sessionId);
          focusOwners.delete(sessionId);
          sessionSizes.delete(sessionId);
          appliedSizes.delete(sessionId);
        }
        workspaces.remove(workspaceId);
        emitRuntimeEvent("workspace.removed", { workspaceId });
        return { removed: true };
      }),
    "session.create": async (conn, params) => {
      const create = async (): Promise<Session> => {
        const workspace = params.workspaceId ? workspaces.get(params.workspaceId) : null;
        if (params.workspaceId && !workspace) throw new Error("workspace not found");
        // 路径遵循既定事实:显式 cwd > 继承源会话的实时目录 > 家目录
        let cwd = params.cwd;
        if (!cwd && params.inheritCwdFrom) {
          try {
            cwd = await daemon
              .request<{ cwd: string | null }>("session.cwd", { sessionId: params.inheritCwdFrom })
              .then((result) => result.cwd ?? undefined);
          } catch (error) {
            if ((error as Error).message === "unknown method session.cwd") {
              throw new Error(
                "terminal daemon is outdated; close existing terminals, then restart the server Mac",
              );
            }
            throw error;
          }
          if (!cwd) throw new Error("source terminal working directory is unavailable");
        }
        const { workspaceId, inheritCwdFrom, ...daemonParams } = params;
        const sessionId = crypto.randomUUID();
        let associated = false;
        creatingSessionIds.add(sessionId);
        try {
          if (workspaceId) {
            workspaces.addSession(workspaceId, sessionId);
            associated = true;
          }
          const daemonCreateParams = {
            ...daemonParams,
            id: sessionId,
            cwd: cwd ?? os.homedir(),
          };
          const { session } = await daemon.request<{ session: Session; handle: number }>(
            "session.createOwned",
            daemonCreateParams,
          );
          return session;
        } catch (error) {
          if (workspaceId && associated && !daemonMayHaveCreatedSession(error)) {
            workspaces.removeSession(workspaceId, sessionId);
          }
          if ((error as Error).message === "unknown method session.createOwned") {
            throw new Error(
              "terminal daemon is outdated; close existing terminals, then restart the server Mac",
            );
          }
          throw error;
        } finally {
          creatingSessionIds.delete(sessionId);
        }
      };
      return params.workspaceId
        ? runWorkspaceMutation(conn, params.workspaceId, create)
        : create();
    },
    "session.list": () => daemon.request<Session[]>("session.list"),
    "session.claimFocus": (conn, { sessionId, force }) =>
      runSessionControl(sessionId, async () => {
        const device = requireActiveDevice(conn);
        const owner = focusOwners.get(sessionId);
        // 静默认领拿不到别人手里的会话:防客户端缓存过期时绕过显式接管语义
        if (owner && owner.deviceId !== device.id && !force) {
          return { claimed: false };
        }
        const intent = Symbol(sessionId);
        pendingFocusClaims.set(sessionId, intent);
        try {
          const sessions = await daemon.request<Session[]>("session.list");
          if (
            pendingFocusClaims.get(sessionId) !== intent ||
            !sessions.some((session) => session.id === sessionId && session.alive)
          ) {
            throw new Error("session not alive");
          }
          const activeDevice = requireActiveDevice(conn);
          focusOwners.set(sessionId, {
            deviceId: activeDevice.id,
            deviceName: activeDevice.name,
          });
          emitRuntimeEvent("session.focusChanged", {
            sessionId,
            deviceId: activeDevice.id,
            deviceName: activeDevice.name,
          });
          return { claimed: true };
        } finally {
          if (pendingFocusClaims.get(sessionId) === intent) {
            pendingFocusClaims.delete(sessionId);
          }
        }
      }),
    "session.focusList": () =>
      [...focusOwners].map(([sessionId, owner]) => ({ sessionId, ...owner })),
    "session.attach": async (conn, { sessionId }) => {
      const snap = await daemon.request<SnapshotResult>(
        "session.snapshot",
        { sessionId },
        (result) => {
          if (!gateway.hasConnection(conn)) throw new Error("connection closed");
          conn.attached.set(result.handle, { sessionId, attachSeq: result.seq });
        },
      );
      return {
        channel: snap.handle,
        snapshot: snap.snapshot,
        seq: snap.seq,
        cols: snap.cols,
        rows: snap.rows,
      };
    },
    "session.detach": (conn, { sessionId }) => {
      for (const [channel, st] of conn.attached) {
        if (st.sessionId === sessionId) conn.attached.delete(channel);
      }
      void dropSizeVote(conn, sessionId).catch(() => {});
      return { detached: true };
    },
    "session.resize": (conn, params) =>
      runSessionSize(params.sessionId, async () => {
        requireActiveDevice(conn);
        if (![...conn.attached.values()].some((state) => state.sessionId === params.sessionId)) {
          throw new Error("session not attached");
        }
        let votes = sessionSizes.get(params.sessionId);
        if (!votes) {
          votes = new Map();
          sessionSizes.set(params.sessionId, votes);
        }
        const previous = votes.get(conn);
        votes.set(conn, { cols: params.cols, rows: params.rows });
        try {
          await applySessionSize(params.sessionId);
          return { resized: true };
        } catch (error) {
          if (previous) votes.set(conn, previous);
          else votes.delete(conn);
          if (votes.size === 0) sessionSizes.delete(params.sessionId);
          throw error;
        }
      }),
    "session.kill": async (_conn, { sessionId }) => {
      await daemon.request("session.kill", { sessionId });
      return { killed: true };
    },
    "session.remove": async (_conn, { sessionId }) => {
      const removed = await removeDaemonSession(daemon, sessionId);
      cancelScheduledSessionCleanup(sessionId);
      workspaces.removeSessions(new Set([sessionId]));
      return { removed };
    },
    "browser.open": async (conn, params) => {
      requireActiveDevice(conn);
      const browserId = await browsers.open(params);
      if (!gateway.hasConnection(conn)) {
        await browsers.close(browserId);
        throw new Error("connection closed");
      }
      const device = requireActiveDevice(conn);
      browserControlOwners.set(browserId, {
        deviceId: device.id,
        deviceName: device.name,
      });
      emitRuntimeEvent("browser.controlChanged", {
        browserId,
        deviceId: device.id,
        deviceName: device.name,
      });
      return { browserId };
    },
    "browser.list": () => browsers.list(),
    "browser.claimControl": (conn, { browserId, force }) =>
      runBrowserControl(browserId, () => {
        const device = requireActiveDevice(conn);
        browsers.attachment(browserId); // 校验页面仍存在
        const owner = browserControlOwners.get(browserId);
        if (owner && owner.deviceId !== device.id && !force) {
          return { claimed: false };
        }
        browserControlOwners.set(browserId, {
          deviceId: device.id,
          deviceName: device.name,
        });
        emitRuntimeEvent("browser.controlChanged", {
          browserId,
          deviceId: device.id,
          deviceName: device.name,
        });
        return { claimed: true };
      }),
    "browser.controlList": () =>
      [...browserControlOwners].map(([browserId, owner]) => ({ browserId, ...owner })),
    "browser.navigate": (conn, { browserId, url }) =>
      runBrowserControl(browserId, async () => {
        requireBrowserControl(conn, browserId);
        return { url: await browsers.navigate(browserId, url) };
      }),
    "browser.attach": async (conn, { browserId }) => {
      const result = browsers.attachment(browserId);
      conn.browserChannels.set(result.channel, browserId);
      try {
        await browsers.attach(browserId);
        if (!gateway.hasConnection(conn)) throw new Error("connection closed");
        return result;
      } catch (error) {
        conn.browserChannels.delete(result.channel);
        await browsers
          .detach(browserId, () => !gateway.hasBrowserChannel(result.channel))
          .catch(() => {});
        throw error;
      }
    },
    "browser.detach": async (conn, { browserId }) => {
      const channels = removeSurfaceChannels(conn.browserChannels, browserId);
      if (channels.length > 0) {
        await browsers.detach(browserId, () =>
          channels.every((channel) => !gateway.hasBrowserChannel(channel)),
        );
      }
      return { detached: true };
    },
    "browser.input": (conn, { browserId, event }) =>
      runBrowserControl(browserId, async () => {
        requireBrowserControl(conn, browserId);
        await browsers.input(browserId, event);
        return { done: true };
      }),
    "browser.close": (conn, { browserId }) =>
      runBrowserControl(browserId, async () => {
        requireBrowserControl(conn, browserId);
        await browsers.close(browserId);
        releaseBrowserControl(browserId);
        return { closed: true };
      }),
    "simulator.list": (conn) => simulators.list(conn.abortController.signal),
    "simulator.boot": async (conn, { udid }) => ({
      state: await simulators.boot(udid, conn.abortController.signal),
    }),
    "simulator.shutdown": async (conn, { udid }) => ({
      state: await simulators.shutdown(udid, conn.abortController.signal),
    }),
    "simulator.attach": async (conn, { udid }) => {
      const intent = Symbol(udid);
      conn.pendingSimAttaches.set(udid, intent);
      try {
        const result = await simulators.attach(udid, conn.abortController.signal);
        if (!gateway.hasConnection(conn) || conn.pendingSimAttaches.get(udid) !== intent) {
          throw new Error("simulator attach cancelled");
        }
        conn.simChannels.set(result.channel, udid);
        conn.pendingSimAttaches.delete(udid);
        return result;
      } catch (error) {
        if (conn.pendingSimAttaches.get(udid) === intent) {
          conn.pendingSimAttaches.delete(udid);
        }
        if (!gateway.hasSimInterest(udid)) simulators.detach(udid);
        throw error;
      }
    },
    "simulator.detach": (conn, { udid }) => {
      conn.pendingSimAttaches.delete(udid);
      removeSurfaceChannels(conn.simChannels, udid);
      if (!gateway.hasSimInterest(udid)) simulators.detach(udid);
      return { detached: true };
    },
    "computer.claimControl": (conn, { force }) =>
      runComputerControl(() => {
        const device = requireActiveDevice(conn);
        if (computerControlOwner && computerControlOwner.deviceId !== device.id && !force) {
          return { claimed: false };
        }
        setComputerControl({ deviceId: device.id, deviceName: device.name });
        return { claimed: true };
      }),
    "computer.controlOwner": () => computerControlOwner,
    // 只读查询允许多个设备共享;输入和应用激活在同一全局控制队列内执行。
    "computer.permissions": (conn) =>
      helper.request<{ accessibility: boolean; screenRecording: boolean }>(
        "permissions.check",
        {},
        conn.abortController.signal,
      ),
    "computer.capture": (conn) =>
      helper.request<{ png: string; width: number; height: number }>(
        "screen.capture",
        {},
        conn.abortController.signal,
      ),
    "computer.windows": (conn) =>
      helper.request<{ windows: unknown[] }>("window.list", {}, conn.abortController.signal),
    "computer.click": (conn, params) =>
      runComputerControl(async () => {
        requireComputerControl(conn);
        return helper.request("input.click", params, conn.abortController.signal);
      }),
    "computer.type": (conn, params) =>
      runComputerControl(async () => {
        requireComputerControl(conn);
        return helper.request("input.type", params, conn.abortController.signal);
      }),
    "computer.key": (conn, params) =>
      runComputerControl(async () => {
        requireComputerControl(conn);
        return helper.request("input.key", params, conn.abortController.signal);
      }),
    "computer.activate": (conn, params) =>
      runComputerControl(async () => {
        requireComputerControl(conn);
        return helper.request<{ activated: boolean }>(
          "app.activate",
          params,
          conn.abortController.signal,
        );
      }),
  };

  const gateway = new Gateway(registry, identity.priv, handlers, (handle, data) =>
    daemon.sendInput(handle, data),
  );
  // runtime 自身的事件流(工作区布局等),与 daemon 的 seq/boot 命名空间独立
  const runtimeBoot = crypto.randomUUID();
  let runtimeSeq = 0;
  const emitRuntimeEvent = (event: string, payload: unknown): void => {
    runtimeSeq += 1;
    gateway.broadcastEvent({ seq: runtimeSeq, boot: runtimeBoot, event, payload });
  };
  gateway.onAuthenticated = () => {
    try {
      clearBootstrapOffer();
    } catch (error) {
      console.warn(`[runtime] failed to clear bootstrap offer: ${(error as Error).message}`);
    }
  };
  daemon.on("frame", (frame) => gateway.forwardFrame(frame));
  daemon.on("up", () => {
    void ensureLiveWorkspaceSession().catch((error) => {
      console.warn(`[runtime] failed to restore terminal session: ${error.message}`);
    });
  });
  daemon.on("lateResponsesDrained", (methods: string[]) => {
    if (!methods.includes("session.createOwned")) return;
    void reconcileWorkspaceSessions().catch((error) => {
      console.warn(`[runtime] failed to reconcile late session creation: ${error.message}`);
    });
  });
  daemon.on("event", (evt) => {
    // 会话结束或删除即清占用,不留脏条目
    if (evt.event === "session.exit" || evt.event === "session.removed") {
      const sessionId = (evt.payload as { sessionId?: string }).sessionId;
      if (sessionId) {
        gateway.dropSession(sessionId);
        pendingFocusClaims.delete(sessionId);
        focusOwners.delete(sessionId);
        void runSessionSize(sessionId, () => {
          sessionSizes.delete(sessionId);
          appliedSizes.delete(sessionId);
        });
      }
    }
    gateway.broadcastEvent(evt);
    if (evt.event === "session.exit") {
      const sessionId = (evt.payload as { sessionId?: string }).sessionId;
      if (sessionId) scheduleUntrackedSessionCleanup(sessionId);
    } else if (evt.event === "session.removed") {
      const sessionId = (evt.payload as { sessionId?: string }).sessionId;
      if (sessionId) cancelScheduledSessionCleanup(sessionId);
    }
  });
  gateway.inputGate = (conn, sessionId) => {
    const owner = focusOwners.get(sessionId);
    return !owner || owner.deviceId === conn.device?.id;
  };
  // 占用设备的连接全部断开后自动释放,其他设备无需手动接管
  gateway.onConnClosed = (conn) => {
    conn.pendingSimAttaches.clear();
    for (const sessionId of [...sessionSizes.keys()]) {
      void dropSizeVote(conn, sessionId).catch(() => {});
    }
    for (const [channel, browserId] of conn.browserChannels) {
      void browsers
        .detach(browserId, () => !gateway.hasBrowserChannel(channel))
        .catch(() => {});
    }
    for (const udid of conn.simChannels.values()) {
      if (!gateway.hasSimInterest(udid)) simulators.detach(udid);
    }
    const deviceId = conn.device?.id;
    if (!deviceId || gateway.hasDeviceConnection(deviceId)) return;
    for (const [sessionId, owner] of focusOwners) {
      if (owner.deviceId !== deviceId) continue;
      focusOwners.delete(sessionId);
      emitRuntimeEvent("session.focusChanged", {
        sessionId,
        deviceId: null,
        deviceName: null,
      });
    }
    for (const [browserId, owner] of browserControlOwners) {
      if (owner.deviceId !== deviceId) continue;
      void runBrowserControl(browserId, () => {
        if (browserControlOwners.get(browserId)?.deviceId === deviceId) {
          releaseBrowserControl(browserId);
        }
      });
    }
    if (computerControlOwner?.deviceId === deviceId) {
      void runComputerControl(() => {
        if (computerControlOwner?.deviceId === deviceId) setComputerControl(null);
      });
    }
  };
  daemon.on("down", () => {
    pendingFocusClaims.clear();
    focusOwners.clear();
    sessionSizes.clear();
    appliedSizes.clear();
    gateway.terminateAll();
  });
  browsers.on("frame", (handle: number, seq: number, data: Buffer) =>
    gateway.forwardBrowserFrame(handle, seq, data),
  );
  browsers.on("closed", (browserId: string, handle: number) => {
    gateway.dropBrowserChannel(handle);
    void runBrowserControl(browserId, () => releaseBrowserControl(browserId));
  });
  simulators.on("frame", (handle: number, seq: number, data: Buffer) =>
    gateway.forwardSimFrame(handle, seq, data),
  );
  simulators.on("detached", (_udid: string, handle: number) => gateway.dropSimChannel(handle));

  // 本机再配对 offer 显式带回环入口:客户端以"含回环"识别本机条目
  const server = http.createServer(createHttpHandler());
  server.on("upgrade", (req, socket, head) => gateway.handleUpgrade(req, socket, head));
  server.listen(config.port, () => {
    console.log(`[runtime] listening on http://127.0.0.1:${config.port}`);
    if (needsBootstrap) {
      const { offer } = ensureBootstrapOffer(registry, identity, config.port);
      console.log(`[runtime] 首次启动,配对码(也写入 ${paths.bootstrapOffer}):\n${offer}`);
    }
  });

  for (const signal of ["SIGTERM", "SIGINT"] as const) {
    process.on(signal, () => {
      gateway.close();
      server.close();
      daemon.close(); // 只断开连接,daemon 和会话继续活着
      void Promise.allSettled([browsers.shutdown(), simulators.shutdownManager()]).finally(() =>
        process.exit(0),
      );
    });
  }
}

main().catch((err) => {
  console.error("[runtime] fatal:", err);
  process.exit(1);
});
