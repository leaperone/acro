// 右侧上下文栏。

import SwiftUI

struct InspectorView: View {
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var runtime: RuntimeConnection

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sidebar.right")
                    .foregroundStyle(.secondary)
                Text("上下文")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button {
                    model.inspectorVisible = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("隐藏右侧栏")
                .accessibilityLabel("隐藏右侧栏")
            }
            .padding(.horizontal, 12)
            .frame(height: 38)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let selectedSession = model.selectedSession {
                        section("会话") {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.sessionDisplayName(selectedSession))
                                        .font(.callout.weight(.semibold))
                                        .lineLimit(1)
                                    Text("运行中")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            row("命令", selectedSession.command)
                            row("目录", selectedSession.cwd, monospaced: true)

                            HStack(spacing: 8) {
                                Button {
                                    model.requestTerminalFocus()
                                } label: {
                                    Image(systemName: "text.cursor")
                                }
                                .help("聚焦终端")
                                .accessibilityLabel("聚焦终端")
                                Button(role: .destructive) {
                                    model.pendingSessionTermination = selectedSession
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .help("关闭终端")
                                .accessibilityLabel("关闭终端")
                            }
                            .controlSize(.small)
                        }
                    }

                    if let selectedProject = model.selectedProject {
                        section("项目") {
                            row("名称", selectedProject.name)
                            row("路径", selectedProject.path, monospaced: true)
                            Button {
                                if let selectedWorkspace = model.selectedWorkspace {
                                    Task {
                                        _ = await model.openTerminal(
                                            project: selectedProject,
                                            workspace: selectedWorkspace
                                        )
                                    }
                                }
                            } label: {
                                Label("新建终端", systemImage: "plus")
                            }
                            .controlSize(.small)
                        }
                    }

                    if let selectedWorkspace = model.selectedWorkspace {
                        section("工作区") {
                            row("名称", selectedWorkspace.name)
                            row("项目", "\(selectedWorkspace.projectIds.count)")
                            row("终端", "\(model.activeSessionCount(in: selectedWorkspace))")
                        }
                    }

                    section("Runtime") {
                        row(
                            "连接",
                            runtime.connected ? "已连接" : "未连接",
                            valueColor: runtime.connected ? .green : .secondary
                        )
                        row("工作区", "\(runtime.workspaces.count)")
                        row("运行终端", "\(model.activeSessions.count)")
                    }
                }
                .padding(16)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.bar)
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(
        _ label: String,
        _ value: String,
        valueColor: Color = .secondary,
        monospaced: Bool = false
    ) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(monospaced ? .caption.monospaced() : .callout)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}
