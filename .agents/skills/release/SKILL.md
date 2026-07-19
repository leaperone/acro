---
name: release
description: 发布 Acro 桌面版。用户说「发版」「发布 desktop」「Release Desktop patch / beta / minor / major」「发个测试版」时使用。涵盖版本号规则、稳定/测试通道、受信任 CI 全自动管线和发布后验证。
---

# Acro 发布

发布只有一个入口:在当前 main HEAD 上打 `desktop-v*` tag 并 push,再发送 `desktop-release` repository dispatch。workflow 只从默认分支加载,并重新验证 tag、main HEAD 和历史版本。其余(构建、签名、公证、GitHub Release、appcast)全部由 CI 完成,禁止手工补做。

## 版本号规则

格式 `desktop-v<semver>`,全小写。移动端未来用 `mobile-v*`,互不干扰。

| 请求 | 规则 | 例(当前 0.0.4) |
|------|------|------|
| Release Desktop patch | 修 bug,不加功能:patch +1 | `desktop-v0.0.5` |
| Release Desktop minor | 新功能,向后兼容:minor +1,patch 归零 | `desktop-v0.1.0` |
| Release Desktop major | 破坏性变更 / 里程碑:major +1,其余归零 | `desktop-v1.0.0` |
| Release Desktop beta | 目标版本号 + `-beta.N`,N 从 1 递增 | `desktop-v0.0.5-beta.1` |

- 预发布后缀只用小写 `-beta.N`(需要更早期可用 `-alpha.N`,转正候选用 `-rc.N`)。`N` 是无前导零的整数。排序:`alpha < beta < rc < 正式`。
- **版本号含 `-` 即测试通道**:CI 据此标记 GitHub Pre-release,appcast 条目加 `<sparkle:channel>beta</sparkle:channel>`,只有客户端选了「测试」通道的用户收到。正式版(无 `-`)在默认通道,所有用户收到。
- 版本号不要求连续,跳号无所谓。同一 tag 禁止重打重发;发错就发下一个号修正。

## 发布步骤

```bash
git checkout main && git pull
gh run list --branch main --limit 1        # 确认 main 最新 commit CI 绿
TAG=desktop-v<version>
git tag "$TAG"
git push origin "$TAG"
gh api --method POST "repos/{owner}/{repo}/dispatches" \
  -f event_type=desktop-release \
  -f "client_payload[tag]=$TAG"
```

前置检查:

1. 待发布的改动已全部合并进 main;`git log <上一个tag>..main --oneline` 过一眼发布内容。
2. main 最新 commit 的 CI 是绿的。红的不发。
3. 用 `gh release list --limit 100` 检查历史 desktop 版本;本次版本必须严格大于所有历史 Release,同一 tag 禁止重发。

## CI 管线(release.yml,repository_dispatch 触发)

自动执行三段管线。`verify` 在默认分支、无密钥、只读 token 下确认 tag 只使用稳定版或小写 `alpha.N`/`beta.N`/`rc.N`,tag commit 等于当前 main HEAD,版本高于全部历史 desktop Release。`package` 进入只允许 main 的 `desktop-release` environment,等待发布审批后用只读 token 完成 swift build、Developer ID 签名、notarytool 公证、staple、EdDSA 签名、delta 验证和本地 appcast,然后上传完整 Actions artifact。`publish` 才获得 `contents: write`,创建 GitHub Release 并提交 appcast。publish 可重跑:已有 Release 时必须核对 tag 状态、通道和全部资产 SHA-256;完全一致才继续 appcast,draft 只补缺失资产,任何不一致都失败且绝不覆盖。Actions 固定完整 commit SHA,Ghostty 与 Sparkle 下载先校验 SHA-256。旧包先复制并清除代码签名扩展属性用于生成 delta,再用未经修改的原包执行 apply + codesign 验证。delta 失败时保留完整 zip 回退,不阻断发布。

依赖 `desktop-release` environment 中的 7 个 GitHub Secrets(Apple 证书/公证 6 个 + SPARKLE_PRIVATE_KEY)。缺任一则发布立即失败,禁止产出 ad-hoc 或缺 appcast 的不完整 Release。

## 发布后验证

```bash
gh run watch $(gh run list --workflow release.yml --event repository_dispatch --limit 1 --json databaseId -q '.[0].databaseId')
gh release view desktop-v<version>          # dmg + zip 齐全;有可用基线时还应有 delta
curl -s https://raw.githubusercontent.com/leaperone/acro/main/apps/desktop-macos/appcast.xml | head -20
```

- appcast 最新条目应为本次版本,带 edSignature;beta 版须带 channel 标记。
- appcast 最新条目应有 `<sparkle:deltas>`,Release 应包含最近稳定版和测试版对应的 `.delta` 资产;某个通道没有历史 Release 时跳过。
- Release 已创建但 appcast push 失败时,在 30 天 artifact 保留期内只对原 run 执行 `gh run rerun <run-id> --failed`;publish 会核对现有资产后继续,不要重新 dispatch 或手工覆盖资产。
- raw.githubusercontent.com 有约 5 分钟 CDN 缓存,客户端刚发完查不到是正常的。
- 客户端验证:设置 → 通用 → 检查更新,应弹出新版本;更新重启后终端会话由 runtime daemon 保持,自动重连,不会丢。

## 通道模型

单一 appcast 多通道(Sparkle 官方推荐),不维护多个 feed:

- 客户端 `UpdaterController.allowedChannels`:用户选「测试」→ 接受 `beta` 通道;选「稳定」→ 只见默认通道。
- 测试用户同时收到 beta 和正式版,哪个新装哪个;beta 转正后测试用户自动升到正式版。
- 典型周期:`0.0.5-beta.1` → `0.0.5-beta.2`(修反馈)→ `0.0.5`(转正,全员推送)。

## 边界

- 不改 `release.yml`、打包脚本或 appcast 的历史条目;那些属于工程变更,走正常 PR。
- 不用 `gh release create` 手工发版,绕过 CI 会缺公证和 appcast。
- 0.0.1 及更早版本不含 Sparkle,无法自动升级,需手动重装一次。
