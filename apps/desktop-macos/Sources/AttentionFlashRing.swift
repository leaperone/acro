// 注意力闪环:焦点切换 / 会话事件时在窗格边缘闪一圈发光描边。
// 取自 cmux 的 WorkspaceAttentionFlashRingView + FocusFlashPattern
// (GPL-3.0-or-later, Copyright (c) 2024-present Manaflow, Inc.),按 acro 精简。

import SwiftUI

enum AttentionFlashPattern {
    static let ringCornerRadius: CGFloat = 6
    static let ringInset: CGFloat = 1
    static let lineWidth: CGFloat = 2
    static let glowRadius: CGFloat = 6
    static let glowOpacity: Double = 0.55
    static let fadeDuration: Double = 0.55
}

struct AttentionFlashRingView: View {
    let opacity: Double
    var color: Color = .accentColor

    var body: some View {
        RoundedRectangle(cornerRadius: AttentionFlashPattern.ringCornerRadius)
            .stroke(color.opacity(opacity), lineWidth: AttentionFlashPattern.lineWidth)
            .shadow(
                color: color.opacity(opacity * AttentionFlashPattern.glowOpacity),
                radius: AttentionFlashPattern.glowRadius
            )
            .padding(AttentionFlashPattern.ringInset)
            .allowsHitTesting(false)
    }
}

// 挂在窗格上;token 变化即触发一次 0.85 → 0 的淡出闪环
struct AttentionFlashModifier: ViewModifier {
    let token: Int
    let active: Bool
    @State private var opacity: Double = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                if opacity > 0 {
                    AttentionFlashRingView(opacity: opacity)
                }
            }
            .onChange(of: token) { _, _ in
                guard active else { return }
                opacity = 0.85
                withAnimation(.easeOut(duration: AttentionFlashPattern.fadeDuration)) {
                    opacity = 0
                }
            }
    }
}

extension View {
    func attentionFlash(token: Int, active: Bool) -> some View {
        modifier(AttentionFlashModifier(token: token, active: active))
    }
}
