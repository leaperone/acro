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

// Computer Use 控制权:画面和窗口信息可共享,输入与应用激活只允许一个设备
export const ComputerControl = z.object({
  deviceId: z.string(),
  deviceName: z.string(),
});
export type ComputerControl = z.infer<typeof ComputerControl>;

// 文件浏览器条目(只读)。Acro 的文件在 Mac mini 上,由 runtime 经 fs.list 返回。
// path 是绝对路径;kind 由 codegen 落成 String;size 目录为 0。
export const FileEntry = z.object({
  name: z.string(),
  path: z.string(),
  kind: z.enum(["dir", "file", "symlink", "other"]),
  size: z.number().int(),
  mtimeMs: z.number(),
});
export type FileEntry = z.infer<typeof FileEntry>;

// 文件预览内容(只读)。kind=text 用 text(UTF-8);kind=image 用 base64;
// kind=binary 两者皆空,客户端降级显示大小/类型。size 是真实字节数,truncated 表示被截断。
export const FileContent = z.object({
  path: z.string(),
  kind: z.enum(["text", "image", "binary"]),
  text: z.string().nullable(),
  base64: z.string().nullable(),
  mime: z.string().nullable(),
  size: z.number().int(),
  truncated: z.boolean(),
});
export type FileContent = z.infer<typeof FileContent>;

// Git 改动文件(只读)。runtime 在 Mac mini 上跑 git status 返回;status 由 codegen 落成 String。
export const GitFileStatus = z.object({
  path: z.string(),
  status: z.enum(["modified", "added", "deleted", "renamed", "untracked", "conflicted"]),
  staged: z.boolean(),
});
export type GitFileStatus = z.infer<typeof GitFileStatus>;

// 仓库状态(只读)。非 git 仓库时 isRepo=false、其余为空。
export const GitStatus = z.object({
  isRepo: z.boolean(),
  root: z.string().nullable(),
  branch: z.string().nullable(),
  files: z.array(GitFileStatus),
});
export type GitStatus = z.infer<typeof GitStatus>;

// 内容搜索命中(只读)。runtime 在 Mac mini 上跑 ripgrep/grep 返回。
export const SearchHit = z.object({
  path: z.string(),
  line: z.number().int(),
  column: z.number().int(),
  preview: z.string(),
});
export type SearchHit = z.infer<typeof SearchHit>;

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
