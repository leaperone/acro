import http from "node:http";
import os from "node:os";
import type { Session, Worktree } from "@acro/protocol";
import { loadConfig } from "./config.ts";
import { DeviceRegistry } from "./devices.ts";
import { DaemonClient } from "./daemon/client.ts";
import { BrowserManager } from "./browser.ts";
import { SimulatorManager } from "./simulator.ts";
import { HelperClient } from "./computer.ts";
import { discoverProjects, findProject } from "./projects.ts";
import { listWorktrees, createWorktree, removeWorktree } from "./worktrees.ts";
import { createHttpHandler } from "./http.ts";
import { Gateway, type Handlers } from "./ws.ts";
import { ensureStateDirs } from "./paths.ts";

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
  const daemon = await DaemonClient.connect();
  const browsers = new BrowserManager();
  const simulators = new SimulatorManager();
  const helper = new HelperClient();

  async function findWorktree(worktreeId: string): Promise<Worktree | null> {
    for (const project of discoverProjects(config.projectRoots)) {
      const found = (await listWorktrees(project)).find((w) => w.id === worktreeId);
      if (found) return found;
    }
    return null;
  }

  const handlers: Handlers = {
    "device.list": () => registry.list(),
    "project.list": () => discoverProjects(config.projectRoots),
    "worktree.list": async (_conn, { projectId }) => {
      const project = findProject(config.projectRoots, projectId);
      if (!project) throw new Error("project not found");
      return listWorktrees(project);
    },
    "worktree.create": async (_conn, { projectId, branch, base }) => {
      const project = findProject(config.projectRoots, projectId);
      if (!project) throw new Error("project not found");
      return createWorktree(project, branch, base);
    },
    "worktree.remove": async (_conn, { projectId, worktreeId, force }) => {
      const project = findProject(config.projectRoots, projectId);
      if (!project) throw new Error("project not found");
      await removeWorktree(project, worktreeId, force ?? false);
      return { removed: true };
    },
    "session.create": async (_conn, params) => {
      let cwd = params.cwd;
      let projectId = params.projectId;
      if (params.worktreeId) {
        const worktree = await findWorktree(params.worktreeId);
        if (!worktree) throw new Error("worktree not found");
        cwd = worktree.path;
        projectId = worktree.projectId;
      } else if (params.projectId) {
        const project = findProject(config.projectRoots, params.projectId);
        if (!project) throw new Error("project not found");
        cwd = project.path;
      }
      const { session } = await daemon.request<{ session: Session; handle: number }>(
        "session.create",
        { ...params, cwd: cwd ?? os.homedir(), projectId },
      );
      return session;
    },
    "session.list": () => daemon.request<Session[]>("session.list"),
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

  const gateway = new Gateway(registry, handlers, (handle, data) =>
    daemon.sendInput(handle, data),
  );
  daemon.on("frame", (frame) => gateway.forwardFrame(frame));
  daemon.on("event", (evt) => gateway.broadcastEvent(evt));
  browsers.on("frame", (handle: number, seq: number, data: Buffer) =>
    gateway.forwardBrowserFrame(handle, seq, data),
  );
  simulators.on("frame", (handle: number, seq: number, data: Buffer) =>
    gateway.forwardSimFrame(handle, seq, data),
  );

  const server = http.createServer(createHttpHandler(registry));
  server.on("upgrade", (req, socket, head) => gateway.handleUpgrade(req, socket, head));
  server.listen(config.port, () => {
    console.log(`[runtime] listening on http://127.0.0.1:${config.port}`);
    if (!registry.hasDevices() || process.env.ACRO_PRINT_PAIR === "1") {
      console.log(`[runtime] pair code: ${registry.newPairCode()}`);
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
