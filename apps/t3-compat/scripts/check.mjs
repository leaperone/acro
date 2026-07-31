import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const [major, minor] = process.versions.node.split(".").map(Number);
const supported =
  (major === 22 && minor >= 16) ||
  (major === 23 && minor >= 11) ||
  (major === 24 && minor >= 10) ||
  major > 24;

if (!supported) {
  throw new Error(`T3 Code requires Node 22.16+, 23.11+, or 24.10+; found ${process.version}`);
}

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../node_modules/t3");
for (const relative of ["LICENSE", "dist/bin.mjs", "dist/client/index.html"]) {
  if (!fs.existsSync(path.join(root, relative))) {
    throw new Error(`Missing T3 Code runtime file: ${relative}`);
  }
}

const metadata = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
if (metadata.version !== "0.0.31") {
  throw new Error(`Expected T3 Code 0.0.31, found ${metadata.version}`);
}
