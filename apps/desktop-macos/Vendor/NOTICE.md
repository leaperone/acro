# Vendor 目录

整包搬运的第三方 SPM 包。Acro 以 GPL-3.0-or-later 发布,与以下来源兼容。

| 包 | 来源 | License | Acro 改动 |
|---|---|---|---|
| CmuxPanes | cmux `Packages/macOS/CmuxPanes`(Copyright (c) 2024-present Manaflow, Inc.) | GPL-3.0-or-later | Package.swift 的 bonsplit 依赖路径改为 `../bonsplit` |
| CmuxCommandPalette | cmux `Packages/macOS/CmuxCommandPalette`(同上) | GPL-3.0-or-later | 去掉 CmuxFoundation 依赖;`FocusStealingResponder.swift` 从 CmuxFoundation 复制进包;移除测试 target |
| bonsplit | acro 自写 shim | GPL-3.0-or-later | 按 CmuxPanes 的使用面重建 Bonsplit 快照类型(上游 Bonsplit 是 manaflow 私有 vendored 库,未随 cmux 发布);CmuxPanes 上游测试 28/28 通过验证语义等价 |

同步上游:cmux 更新后用 `cp -R .tmp/cmux/Packages/macOS/<pkg> Vendor/` 重搬,再重放上表中的 Acro 改动。
