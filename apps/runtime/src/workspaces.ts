import crypto from "node:crypto";
import {
  Workspace as WorkspaceSchema,
  WorkspaceGroup as WorkspaceGroupSchema,
  type Workspace,
  type WorkspaceGroup,
} from "@acro/protocol";
import { z } from "zod";
import { paths } from "./paths.ts";
import { readJson, writeJsonAtomic } from "./store.ts";

const WorkspaceStateSchema = z.object({
  v: z.literal(1),
  workspaces: z.array(WorkspaceSchema),
  workspaceGroups: z.array(WorkspaceGroupSchema),
  deletingWorkspaceIds: z
    .array(z.string())
    .refine((ids) => new Set(ids).size === ids.length, "duplicate deleting workspace id")
    .default([]),
});
const WorkspaceStateMarkerSchema = z.object({ v: z.literal(1) });
const MISSING = Symbol("missing workspace state");

interface WorkspaceStorage {
  workspaceState: string;
  workspaceStateMarker: string;
  workspaces: string;
  workspaceGroups: string;
}

export class WorkspaceRegistry {
  private storage: WorkspaceStorage;
  private workspaces: Workspace[];
  private workspaceGroups: WorkspaceGroup[];
  private deletingWorkspaceIds = new Set<string>();

  constructor(storage: WorkspaceStorage = paths) {
    this.storage = storage;
    try {
      const stored = readJson<unknown | typeof MISSING>(storage.workspaceState, MISSING);
      if (stored !== MISSING) {
        const state = WorkspaceStateSchema.parse(stored);
        this.workspaces = state.workspaces;
        this.workspaceGroups = state.workspaceGroups;
        this.deletingWorkspaceIds = new Set(state.deletingWorkspaceIds);
        this.ensureStateMarker();
      } else {
        const marker = readJson<unknown | typeof MISSING>(storage.workspaceStateMarker, MISSING);
        if (marker !== MISSING) {
          WorkspaceStateMarkerSchema.parse(marker);
          throw new Error("workspace state is missing after migration");
        }
        this.workspaces = z.array(WorkspaceSchema).parse(readJson<unknown>(storage.workspaces, []));
        this.workspaceGroups = z
          .array(WorkspaceGroupSchema)
          .parse(readJson<unknown>(storage.workspaceGroups, []));
        this.validateGroups(this.workspaces, this.workspaceGroups);
        this.persist(this.workspaces, this.workspaceGroups, this.deletingWorkspaceIds);
        this.ensureStateMarker();
      }
    } catch (error) {
      throw new Error(`invalid workspace state: ${(error as Error).message}`, { cause: error });
    }
    this.validateGroups(this.workspaces, this.workspaceGroups);
    this.validateDeletingWorkspaces(this.workspaces, this.deletingWorkspaceIds);
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

  listPendingRemovals(): Workspace[] {
    return this.workspaces
      .filter((workspace) => this.deletingWorkspaceIds.has(workspace.id))
      .map(cloneWorkspace);
  }

  isRemovalPending(workspaceId: string): boolean {
    return this.deletingWorkspaceIds.has(workspaceId);
  }

  beginRemoval(workspaceId: string): Workspace {
    const current = this.get(workspaceId);
    if (!current) throw new Error("workspace not found");
    if (this.deletingWorkspaceIds.has(workspaceId)) return current;
    this.commit((_workspaces, _groups, deletingWorkspaceIds) => {
      deletingWorkspaceIds.add(workspaceId);
    });
    return current;
  }

  create(name?: string, workspaceGroupId?: string): Workspace {
    let created!: Workspace;
    this.commit((workspaces, groups) => {
      const group = workspaceGroupId ? this.getGroupMutable(groups, workspaceGroupId) : null;
      created = {
        id: crypto.randomUUID(),
        name: name?.trim() || this.nextWorkspaceName(workspaces),
        sessionIds: [],
        createdAt: new Date().toISOString(),
        layout: null,
        layoutRev: 0,
      };
      workspaces.push(created);
      group?.workspaceIds.push(created.id);
    });
    return cloneWorkspace(created);
  }

  update(
    workspaceId: string,
    patch: {
      name?: string | undefined;
      workspaceGroupId?: string | null | undefined;
    },
  ): Workspace {
    let updated!: Workspace;
    this.commit((workspaces, groups) => {
      updated = this.getMutable(workspaces, workspaceId);
      if (patch.name !== undefined) updated.name = patch.name.trim();
      if (patch.workspaceGroupId !== undefined) {
        const target = patch.workspaceGroupId
          ? this.getGroupMutable(groups, patch.workspaceGroupId)
          : null;
        for (const group of groups) {
          group.workspaceIds = group.workspaceIds.filter((id) => id !== workspaceId);
        }
        target?.workspaceIds.push(workspaceId);
      }
    });
    return cloneWorkspace(updated);
  }

  // 拖拽重排:先从所有分组摘除,再插入目标分组或未分组序列的 index 位
  reorder(workspaceId: string, workspaceGroupId: string | null, index: number): void {
    this.commit((workspaces, groups) => {
      this.getMutable(workspaces, workspaceId);
      const target = workspaceGroupId ? this.getGroupMutable(groups, workspaceGroupId) : null;
      for (const group of groups) {
        group.workspaceIds = group.workspaceIds.filter((id) => id !== workspaceId);
      }
      if (target) {
        target.workspaceIds.splice(Math.min(index, target.workspaceIds.length), 0, workspaceId);
        return;
      }

      const grouped = new Set(groups.flatMap((group) => group.workspaceIds));
      const self = workspaces.findIndex((item) => item.id === workspaceId);
      const [workspace] = workspaces.splice(self, 1);
      let seen = 0;
      let insertAt = workspaces.length;
      for (let i = 0; i < workspaces.length; i += 1) {
        if (grouped.has(workspaces[i]!.id)) continue;
        if (seen === index) {
          insertAt = i;
          break;
        }
        seen += 1;
      }
      workspaces.splice(insertAt, 0, workspace!);
    });
  }

  createGroup(name: string): WorkspaceGroup {
    let created!: WorkspaceGroup;
    this.commit((_workspaces, groups) => {
      created = {
        id: crypto.randomUUID(),
        name: name.trim(),
        workspaceIds: [],
        createdAt: new Date().toISOString(),
      };
      groups.push(created);
    });
    return cloneWorkspaceGroup(created);
  }

  updateGroup(workspaceGroupId: string, name: string): WorkspaceGroup {
    let updated!: WorkspaceGroup;
    this.commit((_workspaces, groups) => {
      updated = this.getGroupMutable(groups, workspaceGroupId);
      updated.name = name.trim();
    });
    return cloneWorkspaceGroup(updated);
  }

  removeGroup(workspaceGroupId: string): void {
    this.commit((_workspaces, groups) => {
      const index = groups.findIndex((group) => group.id === workspaceGroupId);
      if (index === -1) throw new Error("workspace group not found");
      groups.splice(index, 1);
    });
  }

  // 布局是客户端自定义的 opaque JSON:只存储并递增修订号,不解释内容
  setLayout(workspaceId: string, layout: string): number {
    let revision = 0;
    this.commit((workspaces) => {
      const workspace = this.getMutable(workspaces, workspaceId);
      workspace.layout = layout;
      workspace.layoutRev = (workspace.layoutRev ?? 0) + 1;
      revision = workspace.layoutRev;
    });
    return revision;
  }

  addSession(workspaceId: string, sessionId: string): void {
    const current = this.get(workspaceId);
    if (!current) throw new Error("workspace not found");
    if (this.deletingWorkspaceIds.has(workspaceId)) {
      throw new Error("workspace removal in progress");
    }
    if (current.sessionIds.includes(sessionId)) return;
    this.commit((workspaces) => {
      this.getMutable(workspaces, workspaceId).sessionIds.push(sessionId);
    });
  }

  removeSession(workspaceId: string, sessionId: string): void {
    const current = this.get(workspaceId);
    if (!current) throw new Error("workspace not found");
    if (!current.sessionIds.includes(sessionId)) return;
    this.commit((workspaces) => {
      const workspace = this.getMutable(workspaces, workspaceId);
      workspace.sessionIds = workspace.sessionIds.filter((id) => id !== sessionId);
    });
  }

  removeSessions(sessionIds: ReadonlySet<string>): void {
    if (
      sessionIds.size === 0 ||
      !this.workspaces.some((workspace) => workspace.sessionIds.some((id) => sessionIds.has(id)))
    ) {
      return;
    }
    this.commit((workspaces) => {
      for (const workspace of workspaces) {
        workspace.sessionIds = workspace.sessionIds.filter((id) => !sessionIds.has(id));
      }
    });
  }

  remove(workspaceId: string): void {
    this.commit((workspaces, groups, deletingWorkspaceIds) => {
      const index = workspaces.findIndex((workspace) => workspace.id === workspaceId);
      if (index === -1) throw new Error("workspace not found");
      workspaces.splice(index, 1);
      deletingWorkspaceIds.delete(workspaceId);
      for (const group of groups) {
        group.workspaceIds = group.workspaceIds.filter((id) => id !== workspaceId);
      }
    });
  }

  private commit(
    mutate: (
      workspaces: Workspace[],
      groups: WorkspaceGroup[],
      deletingWorkspaceIds: Set<string>,
    ) => void,
  ): void {
    const workspaces = this.workspaces.map(cloneWorkspace);
    const groups = this.workspaceGroups.map(cloneWorkspaceGroup);
    const deletingWorkspaceIds = new Set(this.deletingWorkspaceIds);
    mutate(workspaces, groups, deletingWorkspaceIds);
    this.validateGroups(workspaces, groups);
    this.validateDeletingWorkspaces(workspaces, deletingWorkspaceIds);
    this.persist(workspaces, groups, deletingWorkspaceIds);
    this.workspaces = workspaces;
    this.workspaceGroups = groups;
    this.deletingWorkspaceIds = deletingWorkspaceIds;
  }

  private persist(
    workspaces: Workspace[],
    workspaceGroups: WorkspaceGroup[],
    deletingWorkspaceIds: ReadonlySet<string>,
  ): void {
    writeJsonAtomic(this.storage.workspaceState, {
      v: 1,
      workspaces,
      workspaceGroups,
      deletingWorkspaceIds: [...deletingWorkspaceIds],
    });
  }

  private ensureStateMarker(): void {
    const stored = readJson<unknown | typeof MISSING>(this.storage.workspaceStateMarker, MISSING);
    if (stored === MISSING) {
      writeJsonAtomic(this.storage.workspaceStateMarker, { v: 1 });
      return;
    }
    WorkspaceStateMarkerSchema.parse(stored);
  }

  private nextWorkspaceName(workspaces: Workspace[]): string {
    const names = new Set(workspaces.map((workspace) => workspace.name));
    let index = 1;
    while (names.has(`工作区 ${index}`)) index += 1;
    return `工作区 ${index}`;
  }

  private getMutable(workspaces: Workspace[], workspaceId: string): Workspace {
    const workspace = workspaces.find((item) => item.id === workspaceId);
    if (!workspace) throw new Error("workspace not found");
    return workspace;
  }

  private getGroupMutable(groups: WorkspaceGroup[], workspaceGroupId: string): WorkspaceGroup {
    const group = groups.find((item) => item.id === workspaceGroupId);
    if (!group) throw new Error("workspace group not found");
    return group;
  }

  private validateGroups(workspaces: Workspace[], groups: WorkspaceGroup[]): void {
    const validWorkspaceIds = new Set(workspaces.map((workspace) => workspace.id));
    const claimed = new Set<string>();
    for (const group of groups) {
      for (const id of group.workspaceIds) {
        if (!validWorkspaceIds.has(id)) {
          throw new Error(`workspace group ${group.id} references missing workspace ${id}`);
        }
        if (claimed.has(id)) {
          throw new Error(`workspace ${id} belongs to more than one workspace group`);
        }
        claimed.add(id);
      }
    }
  }

  private validateDeletingWorkspaces(
    workspaces: Workspace[],
    deletingWorkspaceIds: ReadonlySet<string>,
  ): void {
    const workspaceIds = new Set(workspaces.map((workspace) => workspace.id));
    for (const workspaceId of deletingWorkspaceIds) {
      if (!workspaceIds.has(workspaceId)) {
        throw new Error(`deleting workspace does not exist: ${workspaceId}`);
      }
    }
  }
}

function cloneWorkspace(workspace: Workspace): Workspace {
  return {
    ...workspace,
    sessionIds: [...workspace.sessionIds],
  };
}

function cloneWorkspaceGroup(group: WorkspaceGroup): WorkspaceGroup {
  return { ...group, workspaceIds: [...group.workspaceIds] };
}
