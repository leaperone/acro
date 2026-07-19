import { z } from "zod";
import {
  BrowserControl,
  ComputerControl,
  Device,
  Session,
  SessionFocus,
  Workspace,
  WorkspaceGroup,
} from "./models.ts";

// 控制消息信封。一条 WS 上,JSON 文本帧走这里,二进制帧走 frames.ts。

export const RpcRequest = z.object({
  t: z.literal("req"),
  id: z.number().int(),
  method: z.string(),
  params: z.unknown().optional(),
});
export type RpcRequest = z.infer<typeof RpcRequest>;

export const RpcError = z.object({
  code: z.string(),
  message: z.string(),
});
export type RpcError = z.infer<typeof RpcError>;

export const RpcResponse = z.discriminatedUnion("ok", [
  z.object({ t: z.literal("res"), id: z.number().int(), ok: z.literal(true), result: z.unknown() }),
  z.object({ t: z.literal("res"), id: z.number().int(), ok: z.literal(false), error: RpcError }),
]);
export type RpcResponse = z.infer<typeof RpcResponse>;

// 事件带 seq + boot:boot 变了说明服务端重启过,客户端必须全量重新同步;
// seq 用于同一 boot 内的断点续传。
export const RpcEvent = z.object({
  t: z.literal("evt"),
  seq: z.number().int(),
  boot: z.string(),
  event: z.string(),
  payload: z.unknown().optional(),
});
export type RpcEvent = z.infer<typeof RpcEvent>;

export const RpcMessage = z.union([RpcRequest, RpcResponse, RpcEvent]);
export type RpcMessage = z.infer<typeof RpcMessage>;

const SimulatorUdid = z.string().regex(/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i);
export const SessionId = z.string().uuid();

// 方法表:唯一真源。服务端按它校验入参,客户端按它推导类型,Swift 端按它 codegen。
export const methods = {
  "device.list": {
    params: z.object({}),
    result: z.array(Device),
  },
  // 生成新的访问授权:mint 一个设备 token,打包成配对码字符串。
  // endpoints 自动带上 Runtime 的 LAN 地址,extraEndpoints 追加公网入口(如 FRP)。
  "device.share": {
    params: z.object({
      name: z.string().trim().min(1).max(64).optional(),
      extraEndpoints: z.array(z.string().trim().min(1)).max(8).optional(),
    }),
    result: z.object({ offer: z.string(), deviceId: z.string() }),
  },
  // 撤销授权并立即断开该设备的活动连接
  "device.revoke": {
    params: z.object({ deviceId: z.string() }),
    result: z.object({ revoked: z.boolean() }),
  },
  "daemon.restart": {
    params: z.object({ force: z.literal(true) }),
    result: z.object({ restarting: z.boolean() }),
  },
  "workspace.list": {
    params: z.object({}),
    result: z.array(Workspace),
  },
  "workspace.create": {
    params: z.object({
      name: z.string().trim().min(1).max(80).optional(),
      workspaceGroupId: z.string().optional(),
    }),
    result: Workspace,
  },
  "workspace.update": {
    params: z
      .object({
        workspaceId: z.string(),
        name: z.string().trim().min(1).max(80).optional(),
        workspaceGroupId: z.string().nullable().optional(),
      })
      .refine((value) => value.name !== undefined || value.workspaceGroupId !== undefined, {
        message: "name or workspaceGroupId is required",
      }),
    result: Workspace,
  },
  // 拖拽重排:移入分组(或 null 表示未分组区)并落在 index 位置
  "workspace.reorder": {
    params: z.object({
      workspaceId: z.string(),
      workspaceGroupId: z.string().nullable(),
      index: z.number().int().min(0),
    }),
    result: z.object({ reordered: z.boolean() }),
  },
  "workspaceGroup.list": {
    params: z.object({}),
    result: z.array(WorkspaceGroup),
  },
  "workspaceGroup.create": {
    params: z.object({ name: z.string().trim().min(1).max(80) }),
    result: WorkspaceGroup,
  },
  "workspaceGroup.update": {
    params: z.object({
      workspaceGroupId: z.string(),
      name: z.string().trim().min(1).max(80),
    }),
    result: WorkspaceGroup,
  },
  "workspaceGroup.remove": {
    params: z.object({ workspaceGroupId: z.string() }),
    result: z.object({ removed: z.boolean() }),
  },
  "workspace.remove": {
    params: z.object({ workspaceId: z.string(), force: z.boolean().optional() }),
    result: z.object({ removed: z.boolean() }),
  },
  // 布局同步:整棵布局作为 opaque JSON 上传,服务端存储并广播 layoutChanged。
  // last-writer-wins;返回的 rev 让写入方把自己的修改标记为已同步,避免回环。
  "workspace.setLayout": {
    params: z.object({
      workspaceId: z.string(),
      layout: z.string().max(262144),
    }),
    result: z.object({ rev: z.number().int() }),
  },
  // 路径遵循既定事实:不传 cwd 时,inheritCwdFrom 指向一个存活会话,
  // 服务端解析它的实时工作目录作为新终端的 cwd;都没有则用家目录。
  "session.create": {
    params: z.object({
      workspaceId: z.string().optional(),
      cwd: z.string().optional(),
      inheritCwdFrom: z.string().optional(),
      command: z.string().optional(),
      cols: z.number().int().min(2).max(1000),
      rows: z.number().int().min(2).max(1000),
    }),
    result: Session,
  },
  "session.list": {
    params: z.object({}),
    result: z.array(Session),
  },
  // 终端占用锁:claim 即夺取占用权(focus 上报与显式接管共用);
  // 非占用设备的终端输入会被网关丢弃,设备全部断开时占用自动释放
  // force=false 时会话已被其他设备占用则拒绝(claimed:false)——
  // 静默认领只能拿无主会话,夺取必须显式 force(蒙版上的接管按钮)
  "session.claimFocus": {
    params: z.object({ sessionId: z.string(), force: z.boolean().optional() }),
    result: z.object({ claimed: z.boolean() }),
  },
  "session.focusList": {
    params: z.object({}),
    result: z.array(SessionFocus),
  },
  // attach 返回:连接内 channel、快照(含 scrollback 的 ANSI 序列,base64)、
  // 快照覆盖到的输出 seq。之后的 OUT 帧从 seq+1 开始。
  "session.attach": {
    params: z.object({ sessionId: z.string() }),
    result: z.object({
      channel: z.number().int(),
      snapshot: z.string(),
      seq: z.number().int(),
      cols: z.number().int(),
      rows: z.number().int(),
    }),
  },
  "session.detach": {
    params: z.object({ sessionId: z.string() }),
    result: z.object({ detached: z.boolean() }),
  },
  "session.resize": {
    params: z.object({
      sessionId: z.string(),
      cols: z.number().int().min(2).max(1000),
      rows: z.number().int().min(2).max(1000),
    }),
    result: z.object({ resized: z.boolean() }),
  },
  "session.kill": {
    params: z.object({ sessionId: z.string() }),
    result: z.object({ killed: z.boolean() }),
  },
  "session.remove": {
    params: z.object({ sessionId: SessionId }),
    result: z.object({ removed: z.boolean() }),
  },
  "browser.open": {
    params: z.object({
      url: z.string(),
      width: z.number().int().min(320).max(3840).optional(),
      height: z.number().int().min(240).max(2160).optional(),
    }),
    result: z.object({ browserId: z.string() }),
  },
  "browser.list": {
    params: z.object({}),
    result: z.array(
      z.object({
        browserId: z.string(),
        url: z.string(),
        title: z.string(),
      }),
    ),
  },
  // 打开页面的设备自动获得控制权。其他设备可查看,但只有显式 force 才能接管。
  "browser.claimControl": {
    params: z.object({ browserId: z.string(), force: z.boolean().optional() }),
    result: z.object({ claimed: z.boolean() }),
  },
  "browser.controlList": {
    params: z.object({}),
    result: z.array(BrowserControl),
  },
  "browser.navigate": {
    params: z.object({ browserId: z.string(), url: z.string() }),
    result: z.object({ url: z.string() }),
  },
  // screencast 帧走 FRAME_BROWSER 二进制帧,attach 后开始接收
  "browser.attach": {
    params: z.object({ browserId: z.string() }),
    result: z.object({ channel: z.number().int(), width: z.number(), height: z.number() }),
  },
  "browser.detach": {
    params: z.object({ browserId: z.string() }),
    result: z.object({ detached: z.boolean() }),
  },
  // 输入频率低,走 JSON 而不是二进制帧
  "browser.input": {
    params: z.object({
      browserId: z.string(),
      event: z.discriminatedUnion("kind", [
        z.object({ kind: z.literal("click"), x: z.number(), y: z.number() }),
        z.object({ kind: z.literal("move"), x: z.number(), y: z.number() }),
        z.object({
          kind: z.literal("wheel"),
          x: z.number(),
          y: z.number(),
          deltaY: z.number(),
        }),
        z.object({ kind: z.literal("key"), key: z.string().max(64) }),
        z.object({ kind: z.literal("type"), text: z.string().max(2048) }),
      ]),
    }),
    result: z.object({ done: z.boolean() }),
  },
  "browser.close": {
    params: z.object({ browserId: z.string() }),
    result: z.object({ closed: z.boolean() }),
  },
  "simulator.list": {
    params: z.object({}),
    result: z.array(
      z.object({
        udid: SimulatorUdid,
        name: z.string(),
        state: z.string(),
        runtime: z.string(),
      }),
    ),
  },
  "simulator.boot": {
    params: z.object({ udid: SimulatorUdid }),
    result: z.object({ state: z.string() }),
  },
  "simulator.shutdown": {
    params: z.object({ udid: SimulatorUdid }),
    result: z.object({ state: z.string() }),
  },
  // 画面走 FRAME_SIM 帧(PNG,低帧率轮询;ScreenCaptureKit helper 接管后提频)
  "simulator.attach": {
    params: z.object({ udid: SimulatorUdid }),
    result: z.object({ channel: z.number().int() }),
  },
  "simulator.detach": {
    params: z.object({ udid: SimulatorUdid }),
    result: z.object({ detached: z.boolean() }),
  },
  // Computer Use:由 acro-helper(Swift)执行,runtime 只做转发与校验
  // 写操作必须先认领;force 只用于用户明确接管其他设备当前持有的控制权。
  "computer.claimControl": {
    params: z.object({ force: z.boolean().optional() }),
    result: z.object({ claimed: z.boolean() }),
  },
  "computer.controlOwner": {
    params: z.object({}),
    result: ComputerControl.nullable(),
  },
  "computer.permissions": {
    params: z.object({}),
    result: z.object({ accessibility: z.boolean(), screenRecording: z.boolean() }),
  },
  "computer.capture": {
    params: z.object({}),
    result: z.object({ png: z.string(), width: z.number(), height: z.number() }),
  },
  "computer.windows": {
    params: z.object({}),
    result: z.object({ windows: z.array(z.unknown()) }),
  },
  "computer.click": {
    params: z.object({ x: z.number(), y: z.number() }),
    result: z.object({}),
  },
  "computer.type": {
    params: z.object({ text: z.string().max(2048) }),
    result: z.object({}),
  },
  "computer.key": {
    params: z.object({
      keyCode: z.number().int().min(0).max(65535),
      command: z.boolean().optional(),
      option: z.boolean().optional(),
      control: z.boolean().optional(),
      shift: z.boolean().optional(),
    }),
    result: z.object({}),
  },
  "computer.activate": {
    params: z.object({ bundleId: z.string() }),
    result: z.object({ activated: z.boolean() }),
  },
} as const;

export type MethodName = keyof typeof methods;
export type MethodParams<M extends MethodName> = z.infer<(typeof methods)[M]["params"]>;
export type MethodResult<M extends MethodName> = z.infer<(typeof methods)[M]["result"]>;

// 服务端事件。payload 同样走 zod。
export const events = {
  "session.exit": z.object({ sessionId: z.string(), exitCode: z.number().int().nullable() }),
  "session.created": Session,
  "session.removed": z.object({ sessionId: z.string() }),
  "workspace.layoutChanged": z.object({ workspaceId: z.string(), rev: z.number().int() }),
  "session.focusChanged": z.object({
    sessionId: z.string(),
    deviceId: z.string().nullable(),
    deviceName: z.string().nullable(),
  }),
  "browser.controlChanged": z.object({
    browserId: z.string(),
    deviceId: z.string().nullable(),
    deviceName: z.string().nullable(),
  }),
  "computer.controlChanged": z.object({
    deviceId: z.string().nullable(),
    deviceName: z.string().nullable(),
  }),
  // 终端 OSC 标题变化的增量广播(daemon 节流后发);runtime 透传,客户端刷新 session.list 拿新标题。
  "session.title": z.object({ sessionId: z.string(), title: z.string().nullable() }),
} as const;

export type EventName = keyof typeof events;
export type EventPayload<E extends EventName> = z.infer<(typeof events)[E]>;

// E2EE 信道内认证(握手后的第一条加密消息;见 e2ee.ts 头部注释)
export const E2eeAuth = z.object({
  t: z.literal("auth"),
  token: z.string().min(32),
});
export type E2eeAuth = z.infer<typeof E2eeAuth>;

export const E2eeAuthed = z.object({
  t: z.literal("authed"),
  deviceId: z.string(),
});
export type E2eeAuthed = z.infer<typeof E2eeAuthed>;
