// 右侧栏文件浏览器 + 预览。UI 对标 cmux 的 FileExplorer(树形、目录优先、懒加载),
// 数据走远端 runtime。预览支持文本/代码、图片、二进制降级(参考 orca 的判定与降级)。

import AppKit
import SwiftUI

struct FileBrowserView: View {
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var runtime: RuntimeConnection
    @StateObject private var browser = FileBrowserModel()

    // 以当前选中终端的实时 cwd 为根(Acro 里唯一可靠的路径信号)。
    private var rootPath: String { model.selectedSession?.cwd ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            searchBar
            Divider()
            content
        }
        .onAppear { browser.sync(root: rootPath, runtime: runtime) }
        .onChange(of: rootPath) { _, newValue in browser.sync(root: newValue, runtime: runtime) }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("在此目录内搜索内容", text: $browser.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit { browser.runSearch() }
            if browser.searchActive {
                Button { browser.clearSearch() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }

    @ViewBuilder
    private var content: some View {
        let top = browser.searchActive ? AnyView(searchResults) : AnyView(tree)
        if browser.selectedPath != nil {
            VSplitView {
                top.frame(minHeight: 120)
                FilePreviewView(browser: browser).frame(minHeight: 140)
            }
        } else {
            top
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if browser.isSearching {
            centered { ProgressView().controlSize(.small) }
        } else if let error = browser.searchError {
            centered { Text(error).font(.caption).foregroundStyle(.secondary) }
        } else if let hits = browser.searchResults {
            if hits.isEmpty {
                centered { Text("无匹配").font(.caption).foregroundStyle(.secondary) }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                            SearchResultRow(
                                hit: hit,
                                root: browser.rootPath,
                                selected: browser.selectedPath == hit.path
                            ) { browser.openPreview(hit.path) }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var pathBar: some View {
        HStack(spacing: 6) {
            Button { browser.goUp() } label: { Image(systemName: "arrow.up") }
                .buttonStyle(.borderless)
                .help("上一级目录")
                .accessibilityLabel("上一级目录")
            Text(displayRoot)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(browser.rootPath.isEmpty ? "家目录" : browser.rootPath)
            Button { browser.reloadRoot() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("刷新")
                .accessibilityLabel("刷新")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    private var displayRoot: String {
        if browser.rootPath.isEmpty { return "~" }
        return (browser.rootPath as NSString).abbreviatingWithTildeInPath
    }

    @ViewBuilder
    private var tree: some View {
        if browser.isRootLoading {
            centered { ProgressView().controlSize(.small) }
        } else if let error = browser.rootError {
            centered {
                VStack(spacing: 8) {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Button("重试") { browser.reloadRoot() }.controlSize(.small)
                }
            }
        } else if let nodes = browser.rootNodes {
            if nodes.isEmpty {
                centered { Text("空目录").font(.caption).foregroundStyle(.secondary) }
            } else {
                ScrollView {
                    // ponytail: 递归 VStack 非虚拟化;数千项的大目录才需要换 NSOutlineView。
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(nodes) { node in
                            FileRow(node: node, browser: browser, depth: 0)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        } else {
            centered { Text("未连接").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func centered<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// 单行 + 递归子节点。展开态与 loading 都在 FileNode 上。
private struct FileRow: View {
    @ObservedObject var node: FileNode
    let browser: FileBrowserModel
    let depth: Int

    private var isSelected: Bool { browser.selectedPath == node.path }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                if node.isDir {
                    Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                } else {
                    Spacer().frame(width: 10)
                }
                Image(systemName: FileIcon.symbol(name: node.name, isDir: node.isDir))
                    .font(.system(size: 12))
                    .foregroundStyle(node.isDir ? Color.accentColor : .secondary)
                    .frame(width: 16)
                Text(node.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if node.isLoading {
                    ProgressView().controlSize(.mini).scaleEffect(0.6)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 12 + 8)
            .padding(.trailing, 8)
            .frame(height: 22)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.18) : .clear)
            .onTapGesture { browser.select(node) }

            if node.isDir, node.isExpanded {
                if let children = node.children {
                    ForEach(children) { child in
                        FileRow(node: child, browser: browser, depth: depth + 1)
                    }
                } else if let error = node.loadError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, CGFloat(depth + 1) * 12 + 34)
                        .frame(height: 20)
                }
            }
        }
    }
}

// 搜索结果行:相对路径 + 行号 + 命中行片段。
private struct SearchResultRow: View {
    let hit: SearchHit
    let root: String
    let selected: Bool
    let onTap: () -> Void

    private var relativePath: String {
        guard !root.isEmpty, hit.path.hasPrefix(root) else { return hit.path }
        let tail = hit.path.dropFirst(root.count)
        return tail.hasPrefix("/") ? String(tail.dropFirst()) : String(tail)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(relativePath)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(":\(hit.line)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text(hit.preview.trimmingCharacters(in: .whitespaces))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(selected ? Color.accentColor.opacity(0.18) : .clear)
        .onTapGesture(perform: onTap)
    }
}

// ---- 预览 ----

private struct FilePreviewView: View {
    @ObservedObject var browser: FileBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            body(for: browser)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text((browser.selectedPath.map { ($0 as NSString).lastPathComponent }) ?? "")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let p = browser.preview {
                if p.truncated {
                    Text("已截断")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Text(FileIcon.byteSize(p.size))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
    }

    @ViewBuilder
    private func body(for browser: FileBrowserModel) -> some View {
        if browser.isPreviewLoading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = browser.previewError {
            message(error, systemImage: "exclamationmark.triangle")
        } else if let preview = browser.preview {
            switch preview.kind {
            case "text":
                ScrollView([.horizontal, .vertical]) {
                    Text(preview.text ?? "")
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            case "image":
                imagePreview(preview)
            default:
                message(
                    "二进制文件,不可预览\n\(FileIcon.byteSize(preview.size))",
                    systemImage: "doc.binary"
                )
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func imagePreview(_ preview: FileContent) -> some View {
        if let base64 = preview.base64,
           let data = Data(base64Encoded: base64),
           let image = NSImage(data: data) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .padding(8)
            }
        } else {
            message("图片无法解码", systemImage: "photo")
        }
    }

    private func message(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.title2).foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// 文件图标(SF Symbol,按扩展名)+ 字节格式化。
enum FileIcon {
    static func symbol(name: String, isDir: Bool) -> String {
        if isDir { return "folder.fill" }
        switch (name as NSString).pathExtension.lowercased() {
        case "swift", "ts", "tsx", "js", "jsx", "py", "rs", "go", "c", "h", "cpp", "java", "rb",
             "sh", "zig", "kt":
            return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "yml", "toml", "xml", "plist", "lock":
            return "curlybraces"
        case "md", "markdown", "txt", "rtf":
            return "doc.text"
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "ico", "heic", "tiff", "svg":
            return "photo"
        case "pdf":
            return "doc.richtext"
        case "zip", "gz", "tar", "tgz", "bz2", "xz", "7z", "rar":
            return "doc.zipper"
        case "mp4", "mov", "mp3", "wav", "m4a", "avi", "mkv":
            return "play.rectangle"
        default:
            return "doc"
        }
    }

    static func byteSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
