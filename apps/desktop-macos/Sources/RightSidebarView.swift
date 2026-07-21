// 右侧栏容器:标题栏 + 「上下文 / 文件」模式切换 + 关闭。
// 上下文页是 InspectorView;文件页是 FileBrowserView(远端文件浏览器 + 预览)。
// 模式切换对标 cmux 右侧栏的 RightSidebarMode(files / sessions / …)。

import SwiftUI

struct RightSidebarView: View {
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var runtime: RuntimeConnection

    private enum Mode: String, CaseIterable {
        case context, files, git
        var title: String {
            switch self {
            case .context: "上下文"
            case .files: "文件"
            case .git: "Git"
            }
        }
        var icon: String {
            switch self {
            case .context: "sidebar.right"
            case .files: "folder"
            case .git: "arrow.triangle.branch"
            }
        }
    }

    @State private var mode: Mode = .context

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { m in
                        Label(m.title, systemImage: m.icon).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

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

            switch mode {
            case .context:
                InspectorView(model: model, runtime: runtime)
            case .files:
                FileBrowserView(model: model, runtime: runtime)
            case .git:
                GitPanelView(model: model, runtime: runtime)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.bar)
    }
}
