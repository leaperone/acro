import { z } from "zod";

export const Device = z.object({
  id: z.string(),
  name: z.string(),
  createdAt: z.string(),
  lastSeenAt: z.string().nullable(),
});
export type Device = z.infer<typeof Device>;

// Workspace 是纯分组与界面容器(cmux 语义):不持路径、不持项目。
// 终端路径遵循"既定事实"继承(见 session.create 的 inheritCwdFrom)。
export const Workspace = z.object({
  id: z.string(),
  name: z.string(),
  sessionIds: z.array(z.string()),
  createdAt: z.string(),
  // 分屏/标签布局:客户端自定义的 opaque JSON,服务端只存储转发不解释。
  // layoutRev 由服务端单调递增,客户端用它做"只应用比本地新的布局"的同步门。
  // 两个字段都 nullable:旧 runtime 的 workspace.list 没有它们,
  // Swift 端生成可选类型才能兼容版本偏斜(新客户端连旧服务端)
  layout: z.string().nullable().default(null),
  layoutRev: z.number().int().nullable().default(0),
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
  // cwd 是创建时目录;daemon 查询实时目录成功后会回写此字段
  cwd: z.string(),
  command: z.string(),
  cols: z.number().int(),
  rows: z.number().int(),
  createdAt: z.string(),
  alive: z.boolean(),
  exitCode: z.number().int().nullable(),
});
export type Session = z.infer<typeof Session>;
