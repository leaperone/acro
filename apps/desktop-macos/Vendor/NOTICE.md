# Vendor 目录

整包搬运的第三方 SPM 包。Acro 以 GPL-3.0-or-later 发布,与以下来源兼容。

| 包 | 来源 | License | Acro 改动 |
|---|---|---|---|
| CmuxPanes | cmux `Packages/macOS/CmuxPanes`(Copyright (c) 2024-present Manaflow, Inc.) | GPL-3.0-or-later | Package.swift 的 bonsplit 依赖路径改为 `../bonsplit` |
| CmuxCommandPalette | cmux `Packages/macOS/CmuxCommandPalette`(同上) | GPL-3.0-or-later | 去掉 CmuxFoundation 依赖;`FocusStealingResponder.swift` 从 CmuxFoundation 复制进包;移除测试 target |
| Bonsplit | [manaflow-ai/bonsplit](https://github.com/manaflow-ai/bonsplit), commit `48643102d6b68400069429bd43c15d7bda2b00a1` (Copyright (c) 2026 Alasdair Monk);cmux `f79e3d86` 使用同一 gitlink | MIT | 原样搬入 Package、Sources、Tests、Resources、LICENSE、README 与 CHANGELOG |

同步上游:cmux 更新后用 `cp -R .tmp/cmux/Packages/macOS/<pkg> Vendor/` 重搬 cmux 包；Bonsplit 按 cmux gitlink 固定 commit 重搬。
