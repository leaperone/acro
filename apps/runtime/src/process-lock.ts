import { spawnSync } from "node:child_process";
import fs from "node:fs";
import { PRIVATE_FILE_MODE } from "./paths.ts";

export function acquireProcessLock(file: string, label: string): () => void {
  const fd = fs.openSync(file, "a+", PRIVATE_FILE_MODE);
  try {
    fs.fchmodSync(fd, PRIVATE_FILE_MODE);
  } catch (error) {
    fs.closeSync(fd);
    throw error;
  }
  const command = process.platform === "darwin" ? "/usr/bin/lockf" : "/usr/bin/flock";
  const args = process.platform === "darwin" ? ["-s", "-t", "0", "3"] : ["-n", "3"];
  const result = spawnSync(command, args, {
    encoding: "utf8",
    stdio: ["ignore", "ignore", "pipe", fd],
  });
  const busy =
    (process.platform === "darwin" && result.status === 75) ||
    (process.platform === "linux" && result.status === 1);
  if (result.error || result.status !== 0) {
    fs.closeSync(fd);
    if (busy) throw new Error(`${label} already running`);
    throw new Error(
      `failed to acquire ${label} lock: ${result.error?.message ?? result.stderr.trim()}`,
    );
  }

  let released = false;
  return () => {
    if (released) return;
    released = true;
    fs.closeSync(fd);
  };
}
