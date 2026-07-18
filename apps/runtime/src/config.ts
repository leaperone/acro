import fs from "node:fs";
import { paths } from "./paths.ts";
import { readJson, writeJsonAtomic } from "./store.ts";

export interface RuntimeConfig {
  port: number;
}

const defaults: RuntimeConfig = {
  port: 8790,
};

export function loadConfig(): RuntimeConfig {
  if (!fs.existsSync(paths.config)) writeJsonAtomic(paths.config, defaults);
  const cfg = { ...defaults, ...readJson<Partial<RuntimeConfig>>(paths.config, {}) };
  if (process.env.ACRO_PORT) cfg.port = Number(process.env.ACRO_PORT);
  return cfg;
}
