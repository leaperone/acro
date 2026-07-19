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

// 终端占用:某设备 focus 一个会话即认领,其他设备须显式接管(orca presence lock 的显式变体)
export const SessionFocus = z.object({
  sessionId: z.string(),
  deviceId: z.string(),
  deviceName: z.string(),
});
export type SessionFocus = z.infer<typeof SessionFocus>;

// 浏览器控制权:多人可查看同一画面,同一时刻只有一个设备可导航、输入或关闭
export const BrowserControl = z.object({
  browserId: z.string(),
  deviceId: z.string(),
  deviceName: z.string(),
});
export type BrowserControl = z.infer<typeof BrowserControl>;

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
  // 终端 OSC 0/2 标题;daemon 从 @xterm/headless 屏幕状态采集,无则 null 由客户端回退到 cwd 尾段。
  // nullable + default(null) 让旧 checkpoint / 旧 runtime 的 session 记录仍能通过 safeParse(版本偏斜兼容)。
  title: z.string().nullable().default(null),
});
export type Session = z.infer<typeof Session>;
