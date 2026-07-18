// 快捷键提示 pill。取自 cmux 的 ShortcutHintPill
// (GPL-3.0-or-later, Copyright (c) 2024-present Manaflow, Inc.),去掉 CmuxFoundation 依赖。

import SwiftUI

struct ShortcutHintPillBackground: View {
    var emphasis: Double = 1.0

    var body: some View {
        Capsule(style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.30 * emphasis), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.22 * emphasis), radius: 2, x: 0, y: 1)
    }
}

struct ShortcutHintPill: View {
    let text: String
    var fontSize: CGFloat = 9
    var emphasis: Double = 1.0

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundColor(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(ShortcutHintPillBackground(emphasis: emphasis))
    }
}
