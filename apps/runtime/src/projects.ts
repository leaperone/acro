import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  Project as ProjectSchema,
  type DirectoryListing,
  type Project,
} from "@acro/protocol";
import { paths } from "./paths.ts";
import { readJson, writeJsonAtomic } from "./store.ts";

export function idForPath(value: string): string {
  return crypto.createHash("sha1").update(value).digest("hex").slice(0, 12);
}

export function resolveDirectoryPath(input = "~", home = os.homedir()): string {
  const requested = input.trim() || "~";
  const expanded = requested === "~"
    ? home
    : requested.startsWith("~/")
      ? path.join(home, requested.slice(2))
      : requested;
  const absolute = path.isAbsolute(expanded) ? expanded : path.resolve(home, expanded);
  const resolved = fs.realpathSync(absolute);
  if (!fs.statSync(resolved).isDirectory()) throw new Error("path is not a directory");
  return resolved;
}

export function listDirectories(input = "~", home = os.homedir()): DirectoryListing {
  const current = resolveDirectoryPath(input, home);
  const root = path.parse(current).root;
  const entries = fs.readdirSync(current, { withFileTypes: true }).flatMap((entry) => {
    if (entry.name.startsWith(".")) return [];
    const child = path.join(current, entry.name);
    try {
      if (!fs.statSync(child).isDirectory()) return [];
      return [{ name: entry.name, path: fs.realpathSync(child) }];
    } catch {
      return [];
    }
  });
  entries.sort((left, right) => left.name.localeCompare(right.name));
  return {
    path: current,
    parent: current === root ? null : path.dirname(current),
    home: fs.realpathSync(home),
    entries,
  };
}

export class ProjectRegistry {
  private projects: Project[];
  private storagePath: string;
  private home: string;

  constructor(storagePath = paths.projects, home = os.homedir()) {
    this.storagePath = storagePath;
    this.home = home;
    this.projects = readJson<unknown[]>(storagePath, []).flatMap((value) => {
      const parsed = ProjectSchema.safeParse(value);
      return parsed.success ? [parsed.data] : [];
    });
  }

  list(): Project[] {
    return this.projects.map((project) => ({ ...project }));
  }

  get(projectId: string): Project | null {
    const project = this.projects.find((item) => item.id === projectId);
    return project ? { ...project } : null;
  }

  register(input: string): Project {
    const projectPath = resolveDirectoryPath(input, this.home);
    const existing = this.projects.find((project) => project.path === projectPath);
    if (existing) return { ...existing };
    const project: Project = {
      id: idForPath(projectPath),
      name: path.basename(projectPath) || projectPath,
      path: projectPath,
    };
    this.projects.push(project);
    this.projects.sort((left, right) => left.name.localeCompare(right.name));
    writeJsonAtomic(this.storagePath, this.projects);
    return { ...project };
  }
}
