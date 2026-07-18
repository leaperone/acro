import fs from "node:fs";
import path from "node:path";
import { PRIVATE_FILE_MODE } from "./paths.ts";

export function readJson<T>(file: string, fallback: T): T {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8")) as T;
  } catch {
    return fallback;
  }
}

// 写临时文件再 rename,避免半截文件
export function writeJsonAtomic(file: string, value: unknown): void {
  const tmp = path.join(path.dirname(file), `.${path.basename(file)}.tmp`);
  fs.writeFileSync(tmp, JSON.stringify(value, null, 2), { mode: PRIVATE_FILE_MODE });
  fs.chmodSync(tmp, PRIVATE_FILE_MODE);
  fs.renameSync(tmp, file);
}
