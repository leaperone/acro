import os from "node:os";
import path from "node:path";
import fs from "node:fs";
import { paths } from "./paths.ts";
import { readJson, writeJsonAtomic } from "./store.ts";

export interface RuntimeConfig {
  port: number;
  projectRoots: string[];
}

const defaults: RuntimeConfig = {
  port: 8790,
  projectRoots: [path.join(os.homedir(), "project")],
};

export function loadConfig(): RuntimeConfig {
  if (!fs.existsSync(paths.config)) writeJsonAtomic(paths.config, defaults);
  const cfg = { ...defaults, ...readJson<Partial<RuntimeConfig>>(paths.config, {}) };
  if (process.env.ACRO_PORT) cfg.port = Number(process.env.ACRO_PORT);
  if (process.env.ACRO_PROJECT_ROOTS) cfg.projectRoots = process.env.ACRO_PROJECT_ROOTS.split(":");
  return cfg;
}
