import os from "node:os";
import path from "node:path";
import fs from "node:fs";

export const PRIVATE_DIR_MODE = 0o700;
export const PRIVATE_FILE_MODE = 0o600;

// ACRO_STATE_DIR 用于测试隔离,生产默认 ~/.acro
export const stateDir = process.env.ACRO_STATE_DIR ?? path.join(os.homedir(), ".acro");

export const paths = {
  state: stateDir,
  config: path.join(stateDir, "config.json"),
  devices: path.join(stateDir, "devices.json"),
  serverKey: path.join(stateDir, "server-key.json"),
  bootstrapOffer: path.join(stateDir, "bootstrap-offer.txt"),
  localOffer: path.join(stateDir, "local-offer.txt"),
  projects: path.join(stateDir, "projects.json"),
  workspaces: path.join(stateDir, "workspaces.json"),
  workspaceGroups: path.join(stateDir, "workspace-groups.json"),
  runtimeLock: path.join(stateDir, "runtime.lock"),
  daemonLock: path.join(stateDir, "daemon.lock"),
  daemonSocket: path.join(stateDir, "daemon.sock"),
  daemonMeta: path.join(stateDir, "daemon.meta.json"),
  daemonLog: path.join(stateDir, "daemon.log"),
  sessions: path.join(stateDir, "sessions"),
};

export function ensurePrivateDirectory(directory: string): void {
  fs.mkdirSync(directory, { recursive: true, mode: PRIVATE_DIR_MODE });
  fs.chmodSync(directory, PRIVATE_DIR_MODE);
}

export function ensureStateDirs(): void {
  ensurePrivateDirectory(paths.state);
  ensurePrivateDirectory(paths.sessions);
}
