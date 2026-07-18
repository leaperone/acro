// 终端窗格区:分屏树渲染 + 窗格头 + 注意力闪环。

import SwiftUI

struct TerminalPanesView: View {
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var runtime: RuntimeConnection

    var body: some View {
        if let root = model.currentLayout?.root {
            layoutView(root)
        } else if let selectedWorkspace = model.selectedWorkspace {
            ContentUnavailableView {
                Label("没有终端", systemImage: "terminal")
            } actions: {
                if model.projects(in: selectedWorkspace).isEmpty {
                    Button("添加项目") {
                        model.presentProjectPicker(for: selectedWorkspace)
                    }
                } else {
                    Button("新建终端") {
                        model.requestNewTerminal(in: selectedWorkspace)
                    }
                }
            }
        } else if runtime.connected {
            ContentUnavailableView("选择工作区", systemImage: "square.stack.3d.up")
        } else {
            VStack(spacing: 8) {
                Text("未连接 Runtime")
                Text("先用 acro pair <host:port> 完成配对")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func layoutView(_ node: TerminalLayoutNode) -> AnyView {
        switch node {
        case .leaf(let sessionId):
            return AnyView(pane(sessionId: sessionId))
        case .split(let direction, let first, let second):
            if direction == .horizontal {
                return AnyView(HSplitView {
                    layoutView(first)
                    layoutView(second)
                })
            }
            return AnyView(VSplitView {
                layoutView(first)
                layoutView(second)
            })
        }
    }

    private func pane(sessionId: String) -> some View {
        let session = model.activeSessions.first { $0.id == sessionId }
        let focused = model.currentLayout?.focusedSessionId == sessionId
        let workspaceId = model.selectedWorkspaceId
        return VStack(spacing: 0) {
            paneHeader(sessionId: sessionId, session: session, focused: focused, workspaceId: workspaceId)

            if let session {
                AcroTerminalView(
                    command: AttachCommand.resolve(sessionId: sessionId),
                    focusRequest: focused ? model.terminalFocusRequest : 0,
                    onClose: {
                        if let workspaceId {
                            model.closePane(workspaceId: workspaceId, sessionId: sessionId)
                        }
                    },
                    onFocus: { model.focusSession(session) }
                )
                .id(sessionId)
            } else {
                ContentUnavailableView("终端已结束", systemImage: "terminal")
            }
        }
        .frame(minWidth: 260, minHeight: 220)
        .attentionFlash(
            token: model.flashToken,
            active: model.flashSessionId == sessionId
        )
    }

    private func paneHeader(
        sessionId: String,
        session: Session?,
        focused: Bool,
        workspaceId: String?
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal.fill")
                .font(.caption)
                .foregroundStyle(focused ? Color.accentColor : .secondary)
            Text(session.map(model.sessionDisplayName) ?? "终端")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            if let session {
                Text(URL(fileURLWithPath: session.cwd).lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                model.focusSessionId(sessionId)
                model.splitTerminal(.horizontal)
            } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .buttonStyle(.borderless)
            .help("向右分屏")
            .accessibilityLabel("向右分屏")
            Button {
                model.focusSessionId(sessionId)
                model.splitTerminal(.vertical)
            } label: {
                Image(systemName: "rectangle.split.1x2")
            }
            .buttonStyle(.borderless)
            .help("向下分屏")
            .accessibilityLabel("向下分屏")
            Button {
                if let workspaceId {
                    model.closePane(workspaceId: workspaceId, sessionId: sessionId)
                }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("关闭窗格")
            .accessibilityLabel("关闭窗格")
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(focused ? Color.accentColor : Color(nsColor: .separatorColor))
                .frame(height: focused ? 2 : 1)
        }
    }
}
