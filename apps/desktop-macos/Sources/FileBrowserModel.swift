// 文件浏览器状态。数据全部经 RuntimeConnection 的 fs.list / fs.read RPC 从 Mac mini 取。
// 设计参考 cmux 的 FileExplorerStore(懒加载子节点、目录优先)与 orca 的取消在途请求。

import Foundation

// session.cwd 的内联结果(非 codegen 模型),手写解码。
struct SessionCwd: Decodable {
    let cwd: String?
}

// 树节点(引用类型:懒加载 children、展开态可变)。id 用绝对路径。
@MainActor
final class FileNode: ObservableObject, Identifiable {
    let name: String
    let path: String
    let isDir: Bool
    let size: Int
    nonisolated let id: String

    @Published var children: [FileNode]?   // nil = 未加载
    @Published var isExpanded = false
    @Published var isLoading = false
    @Published var loadError: String?

    init(entry: FileEntry) {
        name = entry.name
        path = entry.path
        isDir = entry.kind == "dir"
        size = entry.size
        id = entry.path
    }
}

@MainActor
final class FileBrowserModel: ObservableObject {
    @Published private(set) var rootPath = ""
    @Published private(set) var rootNodes: [FileNode]?
    @Published private(set) var isRootLoading = false
    @Published private(set) var rootError: String?

    @Published private(set) var selectedPath: String?
    @Published private(set) var preview: FileContent?
    @Published private(set) var isPreviewLoading = false
    @Published private(set) var previewError: String?

    // 内容搜索(以当前根为范围,runtime 跑 ripgrep/grep)
    @Published var searchQuery = ""
    @Published private(set) var searchResults: [SearchHit]?
    @Published private(set) var isSearching = false
    @Published private(set) var searchError: String?

    var searchActive: Bool {
        searchResults != nil || isSearching || searchError != nil
    }

    private weak var runtime: RuntimeConnection?
    private var previewTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    // 跟随聚焦终端时最后一次已知的终端 cwd。用它判断"终端 cd 了"(而非用户手动导航):
    // 只在终端 cwd 真正变化时才改根,不打断用户在浏览器里的手动 goUp/展开。
    private var lastKnownCwd: String?

    // 以某路径为根同步文件树。仅当根变化时重载,避免每次刷新都抖动。
    // root 为空串时由 runtime 落到 home。
    func sync(root: String, runtime: RuntimeConnection) {
        self.runtime = runtime
        if root == rootPath, rootNodes != nil || isRootLoading { return }
        rootPath = root
        selectedPath = nil
        preview = nil
        previewError = nil
        reloadRoot()
    }

    // 聚焦终端切换时调用:清掉 lastKnownCwd,让下一次 follow 强制把根切到新终端的实时 cwd。
    func resetFollow() { lastKnownCwd = nil }

    // 跟随聚焦终端的实时工作目录。拉 session.cwd(daemon 走 lsof 实时查),
    // 只在终端 cwd 变化时改根;用户手动导航后终端没 cd 则不动。
    func follow(sessionId: String, runtime: RuntimeConnection) async {
        self.runtime = runtime
        do {
            let result = try await runtime.rpc(
                "session.cwd", ["sessionId": sessionId], as: SessionCwd.self)
            guard let cwd = result.cwd, !cwd.isEmpty else { return }
            if cwd != lastKnownCwd {
                lastKnownCwd = cwd
                setRoot(cwd)
            }
        } catch {
            // 拉取失败(会话死/超时):静默,保留当前视图
        }
    }

    // 把根切到指定绝对路径并重载(清掉选中/预览/搜索)。
    private func setRoot(_ path: String) {
        guard path != rootPath else { return }
        rootPath = path
        selectedPath = nil
        preview = nil
        previewError = nil
        clearSearch()
        reloadRoot()
    }

    func reloadRoot() {
        guard let runtime else { return }
        isRootLoading = true
        rootError = nil
        let path = rootPath
        Task {
            do {
                let entries = try await runtime.rpc("fs.list", ["path": path], as: [FileEntry].self)
                guard path == rootPath else { return }   // 根已变,丢弃过期结果
                rootNodes = entries.map(FileNode.init)
                // path 为空("home")时,用返回条目的父目录把 rootPath 锚定成 runtime 侧的
                // 绝对路径——客户端不知道 Mac mini 的 home,goUp/显示都要用真实远端路径。
                if rootPath.isEmpty,
                   let anchor = entries.first.map({ ($0.path as NSString).deletingLastPathComponent }),
                   !anchor.isEmpty {
                    rootPath = anchor
                }
                isRootLoading = false
            } catch {
                guard path == rootPath else { return }
                rootError = Self.friendly(error)
                rootNodes = nil
                isRootLoading = false
            }
        }
    }

    // 上一级目录。rootPath 是 runtime 侧的绝对路径(加载后已锚定);为空则还没锚定,不动。
    func goUp() {
        guard runtime != nil, !rootPath.isEmpty else { return }
        let parent = (rootPath as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != rootPath else { return }
        rootPath = parent
        selectedPath = nil
        preview = nil
        reloadRoot()
    }

    func toggle(_ node: FileNode) {
        guard node.isDir else { return }
        node.isExpanded.toggle()
        if node.isExpanded, node.children == nil, !node.isLoading {
            loadChildren(node)
        }
    }

    private func loadChildren(_ node: FileNode) {
        guard let runtime else { return }
        node.isLoading = true
        node.loadError = nil
        Task {
            do {
                let entries = try await runtime.rpc(
                    "fs.list", ["path": node.path], as: [FileEntry].self)
                node.children = entries.map(FileNode.init)
                node.isLoading = false
            } catch {
                node.loadError = Self.friendly(error)
                node.isLoading = false
            }
        }
    }

    // 选中:目录则展开/折叠,文件则拉预览(取消上一个在途预览)。
    func select(_ node: FileNode) {
        if node.isDir { toggle(node); return }
        openPreview(node.path)
    }

    // 直接以路径打开预览(搜索结果点击也走这里)。
    func openPreview(_ path: String) {
        selectedPath = path
        loadPreview(path)
    }

    // 内容搜索:以当前根为范围。空串清空。取消上一个在途搜索。
    func runSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard let runtime, !query.isEmpty else { clearSearch(); return }
        searchTask?.cancel()
        isSearching = true
        searchError = nil
        searchResults = nil
        let root = rootPath
        searchTask = Task {
            do {
                let hits = try await runtime.rpc(
                    "fs.search", ["path": root, "query": query], as: [SearchHit].self)
                guard !Task.isCancelled else { return }
                searchResults = hits
                isSearching = false
            } catch {
                guard !Task.isCancelled else { return }
                searchError = Self.friendly(error)
                isSearching = false
            }
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        searchQuery = ""
        searchResults = nil
        searchError = nil
        isSearching = false
    }

    private func loadPreview(_ path: String) {
        guard let runtime else { return }
        previewTask?.cancel()
        preview = nil
        previewError = nil
        isPreviewLoading = true
        previewTask = Task {
            do {
                let content = try await runtime.rpc("fs.read", ["path": path], as: FileContent.self)
                guard !Task.isCancelled, selectedPath == path else { return }
                preview = content
                isPreviewLoading = false
            } catch {
                guard !Task.isCancelled, selectedPath == path else { return }
                previewError = Self.friendly(error)
                isPreviewLoading = false
            }
        }
    }

    // RPC 错误码 → 人话(参考 orca 的错误映射)
    private static func friendly(_ error: Error) -> String {
        let message = (error as? RpcError)?.message ?? error.localizedDescription
        if message.contains("ENOENT") || message.contains("no such file") { return "路径不存在" }
        if message.contains("EACCES") || message.contains("permission") { return "没有访问权限" }
        if message.contains("ENOTDIR") { return "不是目录" }
        if message.contains("timeout") { return "请求超时" }
        return message
    }
}
