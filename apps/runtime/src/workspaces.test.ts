import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { WorkspaceRegistry } from "./workspaces.ts";

function workspaceStorage(directory: string) {
  return {
    workspaceState: path.join(directory, "workspace-state.json"),
    workspaceStateMarker: path.join(directory, "workspace-state.ready.json"),
    workspaces: path.join(directory, "workspaces.json"),
    workspaceGroups: path.join(directory, "workspace-groups.json"),
  };
}

test("workspace names are generated when clients omit them", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-workspace-names-"));
  const storage = workspaceStorage(directory);

  try {
    const registry = new WorkspaceRegistry(storage);
    assert.equal(registry.create().name, "工作区 1");
    assert.equal(registry.create().name, "工作区 2");
    registry.update(registry.list()[0]!.id, { name: "已重命名" });
    assert.equal(registry.create().name, "工作区 1");
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("workspace reorder moves within groups and the ungrouped list", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-workspace-reorder-"));
  const storage = workspaceStorage(directory);

  try {
    const registry = new WorkspaceRegistry(storage);
    const group = registry.createGroup("Group");
    const a = registry.create("A");
    const b = registry.create("B");
    const c = registry.create("C");

    // 未分组内重排:C 提到最前
    registry.reorder(c.id, null, 0);
    assert.deepEqual(registry.list().map((w) => w.name), ["C", "A", "B"]);

    // 拖进分组的中间
    registry.reorder(a.id, group.id, 0);
    registry.reorder(b.id, group.id, 0);
    registry.reorder(c.id, group.id, 1);
    assert.deepEqual(registry.getGroup(group.id)?.workspaceIds, [b.id, c.id, a.id]);

    // 拖回未分组区尾部(index 越界按末尾处理)
    registry.reorder(b.id, null, 99);
    assert.deepEqual(registry.getGroup(group.id)?.workspaceIds, [c.id, a.id]);
    const grouped = new Set(registry.listGroups().flatMap((g) => g.workspaceIds));
    assert.deepEqual(
      registry.list().filter((w) => !grouped.has(w.id)).map((w) => w.name),
      ["B"],
    );
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("workspace groups persist membership and preserve workspaces when removed", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-workspaces-"));
  const storage = workspaceStorage(directory);

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

test("workspace layout persists opaquely with a monotonic revision", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-workspace-layout-"));
  const storage = workspaceStorage(directory);

  try {
    const registry = new WorkspaceRegistry(storage);
    const workspace = registry.create("Acro");
    assert.equal(workspace.layout, null);
    assert.equal(workspace.layoutRev, 0);

    assert.equal(registry.setLayout(workspace.id, '{"root":1}'), 1);
    assert.equal(registry.setLayout(workspace.id, '{"root":2}'), 2);
    assert.throws(() => registry.setLayout("missing", "{}"));

    // 重启后布局与修订号原样恢复;旧数据缺字段时走 schema 默认值
    const restored = new WorkspaceRegistry(storage);
    const loaded = restored.get(workspace.id);
    assert.equal(loaded?.layout, '{"root":2}');
    assert.equal(loaded?.layoutRev, 2);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("failed session persistence leaves workspace memory unchanged", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-workspace-session-failure-"));
  const storage = workspaceStorage(directory);

  try {
    const registry = new WorkspaceRegistry(storage);
    const workspace = registry.create("Acro");
    const before = fs.readFileSync(storage.workspaceState, "utf8");
    const tmp = path.join(directory, ".workspace-state.json.tmp");
    fs.mkdirSync(tmp);

    assert.throws(() => registry.addSession(workspace.id, "session-id"));
    assert.deepEqual(registry.get(workspace.id)?.sessionIds, []);
    assert.equal(fs.readFileSync(storage.workspaceState, "utf8"), before);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("workspace session references reconcile against daemon truth", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-workspace-session-reconcile-"));
  const storage = workspaceStorage(directory);

  try {
    const registry = new WorkspaceRegistry(storage);
    const workspace = registry.create("Acro");
    registry.addSession(workspace.id, "live-session");
    registry.addSession(workspace.id, "missing-session");

    registry.addSession(workspace.id, "concurrent-session");
    registry.removeSessions(new Set(["missing-session"]));

    assert.deepEqual(registry.get(workspace.id)?.sessionIds, [
      "live-session",
      "concurrent-session",
    ]);
    assert.deepEqual(new WorkspaceRegistry(storage).get(workspace.id)?.sessionIds, [
      "live-session",
      "concurrent-session",
    ]);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("legacy workspace files migrate once into the aggregate state", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-workspace-migration-"));
  const storage = workspaceStorage(directory);
  const workspace = {
    id: "workspace",
    name: "Legacy",
    sessionIds: [],
    createdAt: new Date().toISOString(),
    layout: null,
    layoutRev: 0,
  };
  const group = {
    id: "group",
    name: "Legacy group",
    workspaceIds: [workspace.id],
    createdAt: new Date().toISOString(),
  };

  try {
    fs.writeFileSync(storage.workspaces, JSON.stringify([workspace]));
    fs.writeFileSync(storage.workspaceGroups, JSON.stringify([group]));
    const migrated = new WorkspaceRegistry(storage);
    assert.deepEqual(migrated.getGroup(group.id)?.workspaceIds, [workspace.id]);
    assert.equal(fs.existsSync(storage.workspaceState), true);
    assert.equal(fs.existsSync(storage.workspaceStateMarker), true);

    fs.writeFileSync(storage.workspaces, "{");
    assert.equal(new WorkspaceRegistry(storage).get(workspace.id)?.name, "Legacy");
    fs.rmSync(storage.workspaceState);
    assert.throws(() => new WorkspaceRegistry(storage), /missing after migration/);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("failed aggregate commit leaves memory and disk on the previous state", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-workspace-atomic-failure-"));
  const storage = workspaceStorage(directory);

  try {
    const registry = new WorkspaceRegistry(storage);
    const group = registry.createGroup("Group");
    const workspace = registry.create("Acro", group.id);
    const before = fs.readFileSync(storage.workspaceState, "utf8");
    const tmp = path.join(directory, ".workspace-state.json.tmp");
    fs.mkdirSync(tmp);

    assert.throws(() => registry.remove(workspace.id));
    assert.equal(registry.get(workspace.id)?.name, "Acro");
    assert.deepEqual(registry.getGroup(group.id)?.workspaceIds, [workspace.id]);
    assert.equal(fs.readFileSync(storage.workspaceState, "utf8"), before);

    fs.rmSync(tmp, { recursive: true, force: true });
    const restored = new WorkspaceRegistry(storage);
    assert.equal(restored.get(workspace.id)?.name, "Acro");
    assert.deepEqual(restored.getGroup(group.id)?.workspaceIds, [workspace.id]);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("workspace state rejects corruption without normalizing or rewriting it", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-workspace-invalid-"));
  const storage = workspaceStorage(directory);
  const contents = JSON.stringify([{ id: "workspace" }]);
  try {
    fs.writeFileSync(storage.workspaces, contents);
    assert.throws(() => new WorkspaceRegistry(storage));
    assert.equal(fs.readFileSync(storage.workspaces, "utf8"), contents);
    assert.equal(fs.existsSync(storage.workspaceGroups), false);
    assert.equal(fs.existsSync(storage.workspaceState), false);
    assert.equal(fs.existsSync(storage.workspaceStateMarker), false);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("aggregate null is corruption, not a legacy migration signal", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-workspace-null-state-"));
  const storage = workspaceStorage(directory);

  try {
    new WorkspaceRegistry(storage);
    fs.writeFileSync(storage.workspaceState, "null");
    assert.throws(() => new WorkspaceRegistry(storage));
    assert.equal(fs.readFileSync(storage.workspaceState, "utf8"), "null");
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
