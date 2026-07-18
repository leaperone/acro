import crypto from "node:crypto";
import {
  Workspace as WorkspaceSchema,
  WorkspaceGroup as WorkspaceGroupSchema,
  type Workspace,
  type WorkspaceGroup,
} from "@acro/protocol";
import { paths } from "./paths.ts";
import { readJson, writeJsonAtomic } from "./store.ts";

interface WorkspaceStorage {
  workspaces: string;
  workspaceGroups: string;
}

export class WorkspaceRegistry {
  private storage: WorkspaceStorage;
  private workspaces: Workspace[];
  private workspaceGroups: WorkspaceGroup[];

  constructor(storage: WorkspaceStorage = paths) {
    this.storage = storage;
    const stored = readJson<unknown[]>(storage.workspaces, []);
    this.workspaces = stored.flatMap((value) => {
      const parsed = WorkspaceSchema.safeParse(value);
      return parsed.success ? [parsed.data] : [];
    });
    const storedGroups = readJson<unknown[]>(storage.workspaceGroups, []);
    this.workspaceGroups = storedGroups.flatMap((value) => {
      const parsed = WorkspaceGroupSchema.safeParse(value);
      return parsed.success ? [parsed.data] : [];
    });
    this.normalizeGroups();
  }

  list(): Workspace[] {
    return this.workspaces.map(cloneWorkspace);
  }

  listGroups(): WorkspaceGroup[] {
    return this.workspaceGroups.map(cloneWorkspaceGroup);
  }

  get(workspaceId: string): Workspace | null {
    const workspace = this.workspaces.find((item) => item.id === workspaceId);
    return workspace ? cloneWorkspace(workspace) : null;
  }

  getGroup(workspaceGroupId: string): WorkspaceGroup | null {
    const group = this.workspaceGroups.find((item) => item.id === workspaceGroupId);
    return group ? cloneWorkspaceGroup(group) : null;
  }

  create(name?: string, workspaceGroupId?: string): Workspace {
    const group = workspaceGroupId ? this.getGroupMutable(workspaceGroupId) : null;
    const workspace: Workspace = {
      id: crypto.randomUUID(),
      name: name?.trim() || this.nextWorkspaceName(),
      projectIds: [],
      sessionIds: [],
      createdAt: new Date().toISOString(),
      layout: null,
      layoutRev: 0,
    };
    this.workspaces.push(workspace);
    group?.workspaceIds.push(workspace.id);
    this.saveAll();
    return cloneWorkspace(workspace);
  }

  private nextWorkspaceName(): string {
    const names = new Set(this.workspaces.map((workspace) => workspace.name));
    let index = 1;
    while (names.has(`工作区 ${index}`)) index += 1;
    return `工作区 ${index}`;
  }

  update(
    workspaceId: string,
    patch: {
      name?: string | undefined;
      projectIds?: string[] | undefined;
      workspaceGroupId?: string | null | undefined;
    },
  ): Workspace {
    const workspace = this.getMutable(workspaceId);
    if (patch.name !== undefined) workspace.name = patch.name.trim();
    if (patch.projectIds !== undefined) workspace.projectIds = [...new Set(patch.projectIds)];
    if (patch.workspaceGroupId !== undefined) {
      const target = patch.workspaceGroupId
        ? this.getGroupMutable(patch.workspaceGroupId)
        : null;
      for (const group of this.workspaceGroups) {
        group.workspaceIds = group.workspaceIds.filter((id) => id !== workspaceId);
      }
      target?.workspaceIds.push(workspaceId);
    }
    this.saveAll();
    return cloneWorkspace(workspace);
  }

  // 拖拽重排:先从所有分组摘除,再插入目标分组或未分组序列的 index 位
  reorder(workspaceId: string, workspaceGroupId: string | null, index: number): void {
    this.getMutable(workspaceId);
    const target = workspaceGroupId ? this.getGroupMutable(workspaceGroupId) : null;
    for (const group of this.workspaceGroups) {
      group.workspaceIds = group.workspaceIds.filter((id) => id !== workspaceId);
    }
    if (target) {
      target.workspaceIds.splice(Math.min(index, target.workspaceIds.length), 0, workspaceId);
    } else {
      // 未分组顺序即 workspaces 数组顺序:把自己插到第 index 个未分组项之前
      const grouped = new Set(this.workspaceGroups.flatMap((group) => group.workspaceIds));
      const self = this.workspaces.findIndex((item) => item.id === workspaceId);
      const [workspace] = this.workspaces.splice(self, 1);
      let seen = 0;
      let insertAt = this.workspaces.length;
      for (let i = 0; i < this.workspaces.length; i += 1) {
        if (grouped.has(this.workspaces[i]!.id)) continue;
        if (seen === index) {
          insertAt = i;
          break;
        }
        seen += 1;
      }
      this.workspaces.splice(insertAt, 0, workspace!);
    }
    this.saveAll();
  }

  createGroup(name: string): WorkspaceGroup {
    const group: WorkspaceGroup = {
      id: crypto.randomUUID(),
      name: name.trim(),
      workspaceIds: [],
      createdAt: new Date().toISOString(),
    };
    this.workspaceGroups.push(group);
    this.saveGroups();
    return cloneWorkspaceGroup(group);
  }

  updateGroup(workspaceGroupId: string, name: string): WorkspaceGroup {
    const group = this.getGroupMutable(workspaceGroupId);
    group.name = name.trim();
    this.saveGroups();
    return cloneWorkspaceGroup(group);
  }

  removeGroup(workspaceGroupId: string): void {
    const index = this.workspaceGroups.findIndex((group) => group.id === workspaceGroupId);
    if (index === -1) throw new Error("workspace group not found");
    this.workspaceGroups.splice(index, 1);
    this.saveGroups();
  }

  // 布局是客户端自定义的 opaque JSON:只存储并递增修订号,不解释内容
  setLayout(workspaceId: string, layout: string): number {
    const workspace = this.getMutable(workspaceId);
    workspace.layout = layout;
    workspace.layoutRev = (workspace.layoutRev ?? 0) + 1;
    this.saveWorkspaces();
    return workspace.layoutRev;
  }

  addSession(workspaceId: string, sessionId: string): void {
    const workspace = this.getMutable(workspaceId);
    if (!workspace.sessionIds.includes(sessionId)) {
      workspace.sessionIds.push(sessionId);
      this.saveWorkspaces();
    }
  }

  remove(workspaceId: string): void {
    const index = this.workspaces.findIndex((workspace) => workspace.id === workspaceId);
    if (index === -1) throw new Error("workspace not found");
    this.workspaces.splice(index, 1);
    for (const group of this.workspaceGroups) {
      group.workspaceIds = group.workspaceIds.filter((id) => id !== workspaceId);
    }
    this.saveAll();
  }

  private getMutable(workspaceId: string): Workspace {
    const workspace = this.workspaces.find((item) => item.id === workspaceId);
    if (!workspace) throw new Error("workspace not found");
    return workspace;
  }

  private getGroupMutable(workspaceGroupId: string): WorkspaceGroup {
    const group = this.workspaceGroups.find((item) => item.id === workspaceGroupId);
    if (!group) throw new Error("workspace group not found");
    return group;
  }

  private normalizeGroups(): void {
    const validWorkspaceIds = new Set(this.workspaces.map((workspace) => workspace.id));
    const claimed = new Set<string>();
    let changed = false;
    for (const group of this.workspaceGroups) {
      const next = group.workspaceIds.filter((id) => {
        if (!validWorkspaceIds.has(id) || claimed.has(id)) return false;
        claimed.add(id);
        return true;
      });
      if (next.length !== group.workspaceIds.length) changed = true;
      group.workspaceIds = next;
    }
    if (changed) this.saveGroups();
  }

  private saveWorkspaces(): void {
    writeJsonAtomic(this.storage.workspaces, this.workspaces);
  }

  private saveGroups(): void {
    writeJsonAtomic(this.storage.workspaceGroups, this.workspaceGroups);
  }

  private saveAll(): void {
    this.saveWorkspaces();
    this.saveGroups();
  }
}

function cloneWorkspace(workspace: Workspace): Workspace {
  return {
    ...workspace,
    projectIds: [...workspace.projectIds],
    sessionIds: [...workspace.sessionIds],
  };
}

function cloneWorkspaceGroup(group: WorkspaceGroup): WorkspaceGroup {
  return { ...group, workspaceIds: [...group.workspaceIds] };
}
