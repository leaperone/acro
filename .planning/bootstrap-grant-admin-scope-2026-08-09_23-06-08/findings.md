# 调研与结论：bootstrap-grant-admin-scope

- 任务 ID：`bootstrap-grant-admin-scope-2026-08-09_23-06-08`
- 创建时间：`2026-08-09_23-06-08`

## 需求事实

- PR #151 merge 后，main 的 CI `desktop-macos / runtime e2e` 失败：
  `E2E FAIL ❌ Error: forbidden: method requires the admin scope`。

## 真实调用链

`share.ts` 有三个 grant 创建入口，全部经 `createShareOffer` → `DeviceRegistry.createGrant`：

| 入口 | 用途 | #151 后的 scope | 应有 scope |
|---|---|---|---|
| `createShareOffer`（`device.share`） | 用户分享给其他设备 | `read` + `control`（或用户勾选） | 同左 ✓ |
| `ensureLocalOffer` | 本机桌面端自用 | 全 scope（`local=true` 分支） | 全 scope ✓ |
| `writeBootstrapOffer` | **首次启动的引导配对码** | `read` + `control` ❌ | 全 scope |

`writeBootstrapOffer` 调用 `createShareOffer` 时 `local` 取默认 `false` 且不传 `scopes`，
于是落到 `DEFAULT_GRANT_SCOPES`。

后果不止于 e2e：真实用户首次配对的设备缺 `admin`，无法调 `device.share`，
再也配不出第二台设备。

## 调研结论

- #151 的 Exploring 阶段只核对了 `device.share` 这一个 grant 路径，漏掉另外两个入口。
  教训：改动授权语义时，必须枚举**全部**凭据签发点，而不只是 UI 触发的那个。
- e2e 是唯一抓到它的检查——单测都在 registry 层，没有覆盖「引导设备能否管理其他设备」这条链。

## 技术决策

| 决策 | 证据 |
|---|---|
| 引导设备授予全 scope | 与 `ensureLocalOffer` 同性质（都是这台 Runtime 的管理入口）；缺 admin 会让 Runtime 锁死在单设备状态 |
| 回归测试同时锁三个入口 | 单独测 bootstrap 只能防住这一次；三个入口一起断言才能防住下一次漏改 |

## 风险与边界

- 引导配对码是全权限凭据，落盘 0600 并在首台设备认证成功后删除（`clearBootstrapOffer`），
  与改动前的信任模型一致——改动前它本来就是全权限（当时不存在 scope 概念）。

## 参考指针

- 失败 CI：`gh run view` on main @ `0d4f791`，job `desktop-macos`，step `runtime e2e`
- 上游任务 planning：`.planning/rpc-scope-and-daemon-handshake-2026-08-09_22-33-56/`
