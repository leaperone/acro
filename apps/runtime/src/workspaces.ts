import crypto from "node:crypto";
import { Workspace as WorkspaceSchema, type Workspace } from "@acro/protocol";
import { paths } from "./paths.ts";
import { readJson, writeJsonAtomic } from "./store.ts";

export class WorkspaceRegistry {
  private workspaces: Workspace[];

  constructor() {
    const stored = readJson<unknown[]>(paths.workspaces, []);
    this.workspaces = stored.flatMap((value) => {
      const parsed = WorkspaceSchema.safeParse(value);
      return parsed.success ? [parsed.data] : [];
    });
  }

  list(): Workspace[] {
    return this.workspaces.map((workspace) => ({ ...workspace }));
  }

  get(workspaceId: string): Workspace | null {
    return this.workspaces.find((workspace) => workspace.id === workspaceId) ?? null;
  }

  create(name: string): Workspace {
    const workspace: Workspace = {
      id: crypto.randomUUID(),
      name: name.trim(),
      projectIds: [],
      sessionIds: [],
      createdAt: new Date().toISOString(),
    };
    this.workspaces.push(workspace);
    this.save();
    return { ...workspace };
  }

  update(
    workspaceId: string,
    patch: { name?: string | undefined; projectIds?: string[] | undefined },
  ): Workspace {
    const workspace = this.getMutable(workspaceId);
    if (patch.name !== undefined) workspace.name = patch.name.trim();
    if (patch.projectIds !== undefined) workspace.projectIds = [...new Set(patch.projectIds)];
    this.save();
    return { ...workspace };
  }

  addSession(workspaceId: string, sessionId: string): void {
    const workspace = this.getMutable(workspaceId);
    if (!workspace.sessionIds.includes(sessionId)) {
      workspace.sessionIds.push(sessionId);
      this.save();
    }
  }

  remove(workspaceId: string): void {
    const index = this.workspaces.findIndex((workspace) => workspace.id === workspaceId);
    if (index === -1) throw new Error("workspace not found");
    this.workspaces.splice(index, 1);
    this.save();
  }

  private getMutable(workspaceId: string): Workspace {
    const workspace = this.workspaces.find((item) => item.id === workspaceId);
    if (!workspace) throw new Error("workspace not found");
    return workspace;
  }

  private save(): void {
    writeJsonAtomic(paths.workspaces, this.workspaces);
  }
}
