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

export const Worktree = z.object({
  id: z.string(),
  projectId: z.string(),
  path: z.string(),
  branch: z.string().nullable(),
  head: z.string().nullable(),
  isMain: z.boolean(),
});
export type Worktree = z.infer<typeof Worktree>;

export const Session = z.object({
  id: z.string(),
  projectId: z.string().nullable(),
  worktreeId: z.string().nullable(),
  cwd: z.string(),
  command: z.string(),
  cols: z.number().int(),
  rows: z.number().int(),
  createdAt: z.string(),
  alive: z.boolean(),
  exitCode: z.number().int().nullable(),
});
export type Session = z.infer<typeof Session>;
