import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import type { Project } from "@acro/protocol";

export function idForPath(p: string): string {
  return crypto.createHash("sha1").update(p).digest("hex").slice(0, 12);
}

// 扫描 projectRoots 下一层目录找 git 仓库。根目录本身是仓库也算。
export function discoverProjects(projectRoots: string[]): Project[] {
  const projects: Project[] = [];
  for (const root of projectRoots) {
    if (!fs.existsSync(root)) continue;
    if (fs.existsSync(path.join(root, ".git"))) {
      projects.push({ id: idForPath(root), name: path.basename(root), path: root });
      continue;
    }
    for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
      if (!entry.isDirectory() || entry.name.startsWith(".")) continue;
      const p = path.join(root, entry.name);
      if (fs.existsSync(path.join(p, ".git"))) {
        projects.push({ id: idForPath(p), name: entry.name, path: p });
      }
    }
  }
  return projects.sort((a, b) => a.name.localeCompare(b.name));
}

export function findProject(projectRoots: string[], projectId: string): Project | null {
  return discoverProjects(projectRoots).find((p) => p.id === projectId) ?? null;
}
