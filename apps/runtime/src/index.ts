import crypto from "node:crypto";
import http from "node:http";
import os from "node:os";
import type { Session } from "@acro/protocol";
import { loadConfig } from "./config.ts";
import { DeviceRegistry } from "./devices.ts";
import { DaemonClient } from "./daemon/client.ts";
import { BrowserManager } from "./browser.ts";
import { SimulatorManager } from "./simulator.ts";
import { HelperClient } from "./computer.ts";
import { WorkspaceRegistry } from "./workspaces.ts";
import { createHttpHandler } from "./http.ts";
import {
  clearBootstrapOffer,
  createShareOffer,
  ServerIdentity,
  writeBootstrapOffer,
} from "./share.ts";
import { Gateway, type Handlers } from "./ws.ts";
import { ensureStateDirs, paths } from "./paths.ts";

interface SnapshotResult {
  handle: number;
  seq: number;
  snapshot: string;
  cols: number;
  rows: number;
}

async function main(): Promise<void> {
  ensureStateDirs();
  const config = loadConfig();
  const registry = new DeviceRegistry();
  const identity = new ServerIdentity();
  const daemon = await DaemonClient.connect();
  const browsers = new BrowserManager();
  const simulators = new SimulatorManager();
  const helper = new HelperClient();
  const workspaces = new WorkspaceRegistry();
  // 终端占用:sessionId -> 占用设备。内存态即可,runtime 重启后由客户端重新认领
  const focusOwners = new Map<string, { deviceId: string; deviceName: string }>();

  const handlers: Handlers = {
    "device.list": () => registry.list(),
    "device.share": (_conn, { name, extraEndpoints }) =>
      createShareOffer(registry, identity, config.port, name, extraEndpoints),
    "device.revoke": (_conn, { deviceId }) => {
      const removed = registry.remove(deviceId);
      if (!removed) throw new Error("device not found");
      gateway.terminateDevice(deviceId);
      return { revoked: true };
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
    "workspace.remove": async (_conn, { workspaceId }) => {
      const workspace = workspaces.get(workspaceId);
      if (!workspace) throw new Error("workspace not found");
      const sessions = await daemon.request<Session[]>("session.list");
      if (sessions.some((session) => session.alive && workspace.sessionIds.includes(session.id))) {
        throw new Error("workspace has active sessions");
      }
      workspaces.remove(workspaceId);
      return { removed: true };
    },
    "session.create": async (_conn, params) => {
      const workspace = params.workspaceId ? workspaces.get(params.workspaceId) : null;
      if (params.workspaceId && !workspace) throw new Error("workspace not found");
      // 路径遵循既定事实:显式 cwd > 继承源会话的实时目录 > 家目录
      let cwd = params.cwd;
      if (!cwd && params.inheritCwdFrom) {
        cwd = await daemon
          .request<{ cwd: string | null }>("session.cwd", { sessionId: params.inheritCwdFrom })
          .then((result) => result.cwd ?? undefined)
          .catch(() => undefined);
      }
      const { workspaceId, inheritCwdFrom, ...daemonParams } = params;
      const { session } = await daemon.request<{ session: Session; handle: number }>(
        "session.create",
        { ...daemonParams, cwd: cwd ?? os.homedir() },
      );
      if (workspaceId) workspaces.addSession(workspaceId, session.id);
      return session;
    },
    "session.list": () => daemon.request<Session[]>("session.list"),
    "session.claimFocus": async (conn, { sessionId, force }) => {
      if (!conn.device) throw new Error("unauthenticated");
      const owner = focusOwners.get(sessionId);
      // 静默认领拿不到别人手里的会话:防客户端缓存过期时绕过显式接管语义
      if (owner && owner.deviceId !== conn.device.id && !force) {
        return { claimed: false };
      }
      const sessions = await daemon.request<Session[]>("session.list");
      if (!sessions.some((s) => s.id === sessionId && s.alive)) {
        throw new Error("session not alive");
      }
      focusOwners.set(sessionId, { deviceId: conn.device.id, deviceName: conn.device.name });
      emitRuntimeEvent("session.focusChanged", {
        sessionId,
        deviceId: conn.device.id,
        deviceName: conn.device.name,
      });
      return { claimed: true };
    },
    "session.focusList": () =>
      [...focusOwners].map(([sessionId, owner]) => ({ sessionId, ...owner })),
    "session.attach": async (conn, { sessionId }) => {
      const snap = await daemon.request<SnapshotResult>("session.snapshot", { sessionId });
      conn.attached.set(snap.handle, { sessionId, attachSeq: snap.seq });
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
      return { detached: true };
    },
    "session.resize": async (_conn, params) => {
      await daemon.request("session.resize", params);
      return { resized: true };
    },
    "session.kill": async (_conn, { sessionId }) => {
      await daemon.request("session.kill", { sessionId });
      return { killed: true };
    },
    "browser.open": async (_conn, params) => ({ browserId: await browsers.open(params) }),
    "browser.list": () => browsers.list(),
    "browser.navigate": async (_conn, { browserId, url }) => ({
      url: await browsers.navigate(browserId, url),
    }),
    "browser.attach": async (conn, { browserId }) => {
      const result = await browsers.attach(browserId);
      conn.browserChannels.add(result.channel);
      return result;
    },
    "browser.detach": async (conn, { browserId }) => {
      await browsers.detach(browserId);
      for (const ch of conn.browserChannels) conn.browserChannels.delete(ch);
      return { detached: true };
    },
    "browser.input": async (_conn, { browserId, event }) => {
      await browsers.input(browserId, event);
      return { done: true };
    },
    "browser.close": async (_conn, { browserId }) => {
      await browsers.close(browserId);
      return { closed: true };
    },
    "simulator.list": () => simulators.list(),
    "simulator.boot": async (_conn, { udid }) => ({ state: await simulators.boot(udid) }),
    "simulator.shutdown": async (_conn, { udid }) => ({
      state: await simulators.shutdown(udid),
    }),
    "simulator.attach": (conn, { udid }) => {
      const result = simulators.attach(udid);
      conn.simChannels.add(result.channel);
      return result;
    },
    "simulator.detach": (conn, { udid }) => {
      simulators.detach(udid);
      conn.simChannels.clear();
      return { detached: true };
    },
    // ponytail: computer.* 目前全量转发,项目级安全策略(哪些 app/区域可操作)接入时再收紧
    "computer.permissions": () =>
      helper.request<{ accessibility: boolean; screenRecording: boolean }>("permissions.check"),
    "computer.capture": () =>
      helper.request<{ png: string; width: number; height: number }>("screen.capture"),
    "computer.windows": () => helper.request<{ windows: unknown[] }>("window.list"),
    "computer.click": async (_conn, params) => helper.request("input.click", params),
    "computer.type": async (_conn, params) => helper.request("input.type", params),
    "computer.key": async (_conn, params) => helper.request("input.key", params),
    "computer.activate": (_conn, params) =>
      helper.request<{ activated: boolean }>("app.activate", params),
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
  gateway.onAuthenticated = () => clearBootstrapOffer();
  daemon.on("frame", (frame) => gateway.forwardFrame(frame));
  daemon.on("event", (evt) => {
    // 会话结束即清占用,不留脏条目
    if (evt.event === "session.exit") {
      const sessionId = (evt.payload as { sessionId?: string }).sessionId;
      if (sessionId) focusOwners.delete(sessionId);
    }
    gateway.broadcastEvent(evt);
  });
  gateway.inputGate = (conn, sessionId) => {
    const owner = focusOwners.get(sessionId);
    return !owner || owner.deviceId === conn.device?.id;
  };
  // 占用设备的连接全部断开后自动释放,其他设备无需手动接管
  gateway.onConnClosed = (conn) => {
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
  };
  browsers.on("frame", (handle: number, seq: number, data: Buffer) =>
    gateway.forwardBrowserFrame(handle, seq, data),
  );
  simulators.on("frame", (handle: number, seq: number, data: Buffer) =>
    gateway.forwardSimFrame(handle, seq, data),
  );

  // 本机再配对 offer 显式带回环入口:客户端以"含回环"识别本机条目
  const server = http.createServer(
    createHttpHandler(
      () =>
        createShareOffer(registry, identity, config.port, "本机", [`127.0.0.1:${config.port}`])
          .offer,
    ),
  );
  server.on("upgrade", (req, socket, head) => gateway.handleUpgrade(req, socket, head));
  server.listen(config.port, () => {
    console.log(`[runtime] listening on http://127.0.0.1:${config.port}`);
    if (!registry.hasDevices()) {
      const { offer } = writeBootstrapOffer(registry, identity, config.port);
      console.log(`[runtime] 首次启动,配对码(也写入 ${paths.bootstrapOffer}):\n${offer}`);
    }
  });

  for (const signal of ["SIGTERM", "SIGINT"] as const) {
    process.on(signal, () => {
      gateway.close();
      server.close();
      daemon.close(); // 只断开连接,daemon 和会话继续活着
      simulators.shutdownManager();
      void browsers.shutdown().finally(() => process.exit(0));
    });
  }
}

main().catch((err) => {
  console.error("[runtime] fatal:", err);
  process.exit(1);
});
