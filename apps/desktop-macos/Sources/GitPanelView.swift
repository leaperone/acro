// 右侧栏 Git 面板:分支 + 改动文件列表(状态角标)+ 单文件 diff。
// 只读——展示 Mac mini 上仓库的状态,不做 stage/commit/push(那归终端 Agent)。

import AppKit
import SwiftUI

struct GitPanelView: View {
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var runtime: RuntimeConnection
    @StateObject private var git = GitPanelModel()

    private var selectedSessionId: String? { model.selectedSession?.id }
    private var followContext: FollowContext {
        FollowContext(
            serverId: model.selectedServerId,
            runtime: ObjectIdentifier(runtime),
            sessionId: selectedSessionId
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: followContext) {
            git.beginFollow(sessionId: selectedSessionId, runtime: runtime)
            guard let sessionId = selectedSessionId else {
                git.sync(root: "", runtime: runtime)
                return
            }
            while !Task.isCancelled {
                await git.follow(sessionId: sessionId, runtime: runtime)
                try? await Task.sleep(for: .seconds(4))
            }
        }
        .onDisappear { git.cancelAll() }
    }

    private struct FollowContext: Hashable {
        let serverId: String?
        let runtime: ObjectIdentifier
        let sessionId: String?
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(git.status?.branch ?? (git.status?.isRepo == true ? "detached" : "—"))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if let files = git.status?.files, !files.isEmpty {
                Text("\(files.count)").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button { git.reload() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("刷新")
                .accessibilityLabel("刷新 git 状态")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    @ViewBuilder
    private var content: some View {
        if git.isLoading {
            centered { ProgressView().controlSize(.small) }
        } else if let error = git.loadError {
            centered {
                VStack(spacing: 8) {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Button("重试") { git.reload() }.controlSize(.small)
                }
            }
        } else if let status = git.status {
            if !status.isRepo {
                centered { Text("不是 git 仓库").font(.caption).foregroundStyle(.secondary) }
            } else if status.files.isEmpty {
                centered { Text("工作区干净").font(.caption).foregroundStyle(.secondary) }
            } else if git.selectedPath != nil {
                VSplitView {
                    fileList(status).frame(minHeight: 100)
                    diffView.frame(minHeight: 140)
                }
            } else {
                fileList(status)
            }
        } else {
            centered { Text("未连接").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func fileList(_ status: GitStatus) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(status.files, id: \.path) { file in
                    GitFileRow(
                        file: file,
                        root: status.root ?? "",
                        selected: git.selectedPath == file.path
                    ) { git.selectFile(file.path) }
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var diffView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text((git.selectedPath.map { ($0 as NSString).lastPathComponent }) ?? "")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if git.diffTruncated {
                    Text("已截断").font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            Divider()
            if git.isDiffLoading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = git.diffError {
                Text(error).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let diff = git.diff, !diff.isEmpty {
                DiffText(diff: diff)
            } else {
                Text("无 diff(可能是未跟踪或二进制文件)")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func centered<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// 改动文件行:状态字母角标(配色)+ 相对路径。
private struct GitFileRow: View {
    let file: GitFileStatus
    let root: String
    let selected: Bool
    let onTap: () -> Void

    private var relativePath: String {
        guard !root.isEmpty, file.path.hasPrefix(root) else { return file.path }
        let tail = file.path.dropFirst(root.count)
        return tail.hasPrefix("/") ? String(tail.dropFirst()) : String(tail)
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(badge)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 14)
            Text(relativePath)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.head)
                .foregroundStyle(file.status == "deleted" ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        .contentShape(Rectangle())
        .background(selected ? Color.accentColor.opacity(0.18) : .clear)
        .onTapGesture(perform: onTap)
        .help(relativePath)
    }

    private var badge: String {
        switch file.status {
        case "modified": "M"
        case "added": "A"
        case "deleted": "D"
        case "renamed": "R"
        case "untracked": "U"
        case "conflicted": "C"
        default: "?"
        }
    }

    private var color: Color {
        switch file.status {
        case "added", "untracked": .green
        case "deleted", "conflicted": .red
        case "renamed": .blue
        default: .orange
        }
    }
}

// 单个原生文本存储承载大 diff,避免为每一行创建一棵 SwiftUI 子树。
private struct DiffText: NSViewRepresentable {
    let diff: String

    final class Coordinator {
        var renderedDiff: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isHorizontallyResizable = true
        text.isVerticallyResizable = true
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.renderedDiff != diff,
              let text = scroll.documentView as? NSTextView else { return }
        context.coordinator.renderedDiff = diff
        text.textStorage?.setAttributedString(Self.attributed(diff))
    }

    private static func attributed(_ diff: String) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let output = NSMutableAttributedString(
            string: diff,
            attributes: [.font: font, .foregroundColor: NSColor.textColor]
        )
        let source = diff as NSString
        var index = 0
        while index < source.length {
            let range = source.lineRange(for: NSRange(location: index, length: 0))
            let line = source.substring(with: range)
            let color: NSColor? = if line.hasPrefix("+++") || line.hasPrefix("---") {
                .secondaryLabelColor
            } else if line.hasPrefix("+") {
                .systemGreen
            } else if line.hasPrefix("-") {
                .systemRed
            } else if line.hasPrefix("@@") {
                .systemBlue
            } else {
                nil
            }
            if let color { output.addAttribute(.foregroundColor, value: color, range: range) }
            index = NSMaxRange(range)
        }
        return output
    }
}
