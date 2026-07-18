import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { WorkspaceRegistry } from "./workspaces.ts";

test("workspace groups persist membership and preserve workspaces when removed", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-workspaces-"));
  const storage = {
    workspaces: path.join(directory, "workspaces.json"),
    workspaceGroups: path.join(directory, "workspace-groups.json"),
  };

  try {
    const registry = new WorkspaceRegistry(storage);
    const primary = registry.createGroup("Primary");
    const archive = registry.createGroup("Archive");
    const workspace = registry.create("Acro", primary.id);

    assert.deepEqual(registry.listGroups()[0]?.workspaceIds, [workspace.id]);

    registry.update(workspace.id, { workspaceGroupId: archive.id });
    assert.deepEqual(registry.listGroups()[0]?.workspaceIds, []);
    assert.deepEqual(registry.listGroups()[1]?.workspaceIds, [workspace.id]);

    const restored = new WorkspaceRegistry(storage);
    assert.deepEqual(restored.listGroups()[1]?.workspaceIds, [workspace.id]);

    restored.removeGroup(archive.id);
    assert.equal(restored.list().some((item) => item.id === workspace.id), true);
    assert.equal(restored.listGroups().some((group) => group.id === archive.id), false);

    restored.update(workspace.id, { workspaceGroupId: primary.id });
    restored.remove(workspace.id);
    assert.deepEqual(restored.listGroups()[0]?.workspaceIds, []);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
