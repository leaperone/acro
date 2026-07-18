import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { listDirectories, ProjectRegistry } from "./projects.ts";

test("projects are explicitly registered and persisted by canonical path", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-projects-"));
  const home = path.join(directory, "home");
  const projectPath = path.join(home, "src", "demo");
  const storagePath = path.join(directory, "projects.json");
  fs.mkdirSync(projectPath, { recursive: true });

  try {
    const registry = new ProjectRegistry(storagePath, home);
    assert.deepEqual(registry.list(), []);
    const project = registry.register("~/src/demo");
    assert.equal(project.path, fs.realpathSync(projectPath));
    assert.equal(project.name, "demo");
    assert.equal(registry.register(projectPath).id, project.id);
    assert.deepEqual(new ProjectRegistry(storagePath, home).list(), [project]);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("directory listing starts from runtime home and supports root navigation", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-directories-"));
  const home = path.join(directory, "home");
  fs.mkdirSync(path.join(home, "alpha"), { recursive: true });
  fs.mkdirSync(path.join(home, ".hidden"));
  fs.writeFileSync(path.join(home, "file.txt"), "x");

  try {
    const listing = listDirectories("~", home);
    assert.equal(listing.path, fs.realpathSync(home));
    assert.equal(listing.home, fs.realpathSync(home));
    assert.deepEqual(listing.entries.map((entry) => entry.name), ["alpha"]);
    assert.equal(listing.parent, fs.realpathSync(directory));
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
