import os from "node:os";
import path from "node:path";
import fs from "node:fs";

// ACRO_STATE_DIR 用于测试隔离,生产默认 ~/.acro
export const stateDir = process.env.ACRO_STATE_DIR ?? path.join(os.homedir(), ".acro");

export const paths = {
  state: stateDir,
  config: path.join(stateDir, "config.json"),
  devices: path.join(stateDir, "devices.json"),
  workspaces: path.join(stateDir, "workspaces.json"),
  daemonSocket: path.join(stateDir, "daemon.sock"),
  daemonMeta: path.join(stateDir, "daemon.meta.json"),
  daemonLog: path.join(stateDir, "daemon.log"),
  sessions: path.join(stateDir, "sessions"),
};

export function ensureStateDirs(): void {
  fs.mkdirSync(paths.sessions, { recursive: true });
}
