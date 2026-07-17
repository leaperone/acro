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

export const Workspace = z.object({
  id: z.string(),
  name: z.string(),
  projectIds: z.array(z.string()),
  sessionIds: z.array(z.string()),
  createdAt: z.string(),
});
export type Workspace = z.infer<typeof Workspace>;

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
