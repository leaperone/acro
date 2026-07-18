import { z } from "zod";

export const Device = z.object({
  id: z.string(),
  name: z.string(),
  createdAt: z.string(),
  lastSeenAt: z.string().nullable(),
});
export type Device = z.infer<typeof Device>;

export const Project = z.object({
  id: z.string(),
  name: z.string(),
  path: z.string(),
});
export type Project = z.infer<typeof Project>;

export const DirectoryEntry = z.object({
  name: z.string(),
  path: z.string(),
});
export type DirectoryEntry = z.infer<typeof DirectoryEntry>;

export const DirectoryListing = z.object({
  path: z.string(),
  parent: z.string().nullable(),
  home: z.string(),
  entries: z.array(DirectoryEntry),
});
export type DirectoryListing = z.infer<typeof DirectoryListing>;

export const Workspace = z.object({
  id: z.string(),
  name: z.string(),
  projectIds: z.array(z.string()),
  sessionIds: z.array(z.string()),
  createdAt: z.string(),
  // 分屏/标签布局:客户端自定义的 opaque JSON,服务端只存储转发不解释。
  // layoutRev 由服务端单调递增,客户端用它做"只应用比本地新的布局"的同步门。
  layout: z.string().nullable().default(null),
  layoutRev: z.number().int().default(0),
});
export type Workspace = z.infer<typeof Workspace>;

export const WorkspaceGroup = z.object({
  id: z.string(),
  name: z.string(),
  workspaceIds: z.array(z.string()),
  createdAt: z.string(),
});
export type WorkspaceGroup = z.infer<typeof WorkspaceGroup>;

export const Session = z.object({
  id: z.string(),
  projectId: z.string().nullable(),
  cwd: z.string(),
  command: z.string(),
  cols: z.number().int(),
  rows: z.number().int(),
  createdAt: z.string(),
  alive: z.boolean(),
  exitCode: z.number().int().nullable(),
});
export type Session = z.infer<typeof Session>;
