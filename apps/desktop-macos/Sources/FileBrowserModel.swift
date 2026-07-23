// 文件浏览器状态。数据全部经 RuntimeConnection 的 fs.list / fs.read RPC 从 Mac mini 取。
// 设计参考 cmux 的 FileExplorerStore(懒加载子节点、目录优先)与 orca 的取消在途请求。

import AppKit
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
    struct Operations {
        let cwd: (RuntimeConnection, String) async throws -> String?
        let list: (RuntimeConnection, String) async throws -> [FileEntry]
        let read: (RuntimeConnection, String) async throws -> FileContent
        let search: (RuntimeConnection, String, String) async throws -> [SearchHit]

        static let live = Operations(
            cwd: { runtime, sessionId in
                try await runtime.rpc(
                    "session.cwd", ["sessionId": sessionId], as: SessionCwd.self
                ).cwd
            },
            list: { runtime, path in
                try await runtime.rpc("fs.list", ["path": path], as: [FileEntry].self)
            },
            read: { runtime, path in
                try await runtime.rpc("fs.read", ["path": path], as: FileContent.self)
            },
            search: { runtime, path, query in
                try await runtime.rpc(
                    "fs.search", ["path": path, "query": query], as: [SearchHit].self
                )
            }
        )
    }

    private struct FollowContext: Equatable {
        let runtime: ObjectIdentifier
        let sessionId: String?
    }

    private struct ChildTask {
        let id: Int
        let task: Task<Void, Never>
    }

    @Published private(set) var rootPath = ""
    @Published private(set) var rootNodes: [FileNode]?
    @Published private(set) var isRootLoading = false
    @Published private(set) var rootError: String?

    @Published private(set) var selectedPath: String?
    @Published private(set) var preview: FileContent?
    @Published private(set) var previewImage: NSImage?
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
    private let operations: Operations
    private var requestGeneration = 0
    private var rootTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var childTasks: [String: ChildTask] = [:]
    private var loadingNodes: [String: FileNode] = [:]
    private var nextChildTaskId = 0
    private var followContext: FollowContext?
    // 跟随聚焦终端时最后一次已知的终端 cwd。用它判断"终端 cd 了"(而非用户手动导航):
    // 只在终端 cwd 真正变化时才改根,不打断用户在浏览器里的手动 goUp/展开。
    private var lastKnownCwd: String?

    init(operations: Operations = .live) {
        self.operations = operations
    }

    // 以某路径为根同步文件树。仅当根变化时重载,避免每次刷新都抖动。
    // root 为空串时由 runtime 落到 home。
    func sync(root: String, runtime: RuntimeConnection) {
        bind(runtime)
        if root == rootPath, rootNodes != nil || isRootLoading { return }
        rootPath = root
        selectedPath = nil
        preview = nil
        previewImage = nil
        previewError = nil
        reloadRoot()
    }

    // 聚焦终端或 Runtime 切换时先建立新的请求所有权边界，并立即清掉旧上下文。
    func beginFollow(sessionId: String?, runtime: RuntimeConnection) {
        let next = FollowContext(runtime: ObjectIdentifier(runtime), sessionId: sessionId)
        guard followContext != next else { return }
        invalidateRequests(clearState: true)
        self.runtime = runtime
        followContext = next
        lastKnownCwd = nil
    }

    // 跟随聚焦终端的实时工作目录。拉 session.cwd(daemon 走 lsof 实时查),
    // 只在终端 cwd 变化时改根;用户手动导航后终端没 cd 则不动。
    func follow(sessionId: String, runtime: RuntimeConnection) async {
        beginFollow(sessionId: sessionId, runtime: runtime)
        let generation = requestGeneration
        do {
            let cwd = try await operations.cwd(runtime, sessionId)
            guard !Task.isCancelled,
                  owns(runtime, generation: generation),
                  followContext?.sessionId == sessionId,
                  let cwd,
                  !cwd.isEmpty
            else { return }
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
        if path == rootPath {
            if rootNodes == nil, !isRootLoading { reloadRoot() }
            return
        }
        rootPath = path
        selectedPath = nil
        preview = nil
        previewImage = nil
        previewError = nil
        clearSearch()
        reloadRoot()
    }

    func reloadRoot() {
        guard let runtime else { return }
        rootTask?.cancel()
        isRootLoading = true
        rootError = nil
        let path = rootPath
        let generation = requestGeneration
        rootTask = Task {
            do {
                let entries = try await operations.list(runtime, path)
                guard !Task.isCancelled,
                      owns(runtime, generation: generation),
                      path == rootPath
                else { return }
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
                guard !Task.isCancelled,
                      owns(runtime, generation: generation),
                      path == rootPath
                else { return }
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
        previewImage = nil
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
        childTasks[node.path]?.task.cancel()
        node.isLoading = true
        node.loadError = nil
        let generation = requestGeneration
        nextChildTaskId &+= 1
        let taskId = nextChildTaskId
        loadingNodes[node.path] = node
        let task = Task {
            defer { finishChildTask(path: node.path, id: taskId) }
            do {
                let entries = try await operations.list(runtime, node.path)
                guard !Task.isCancelled, owns(runtime, generation: generation) else { return }
                node.children = entries.map(FileNode.init)
                node.isLoading = false
            } catch {
                guard !Task.isCancelled, owns(runtime, generation: generation) else { return }
                node.loadError = Self.friendly(error)
                node.isLoading = false
            }
        }
        childTasks[node.path] = ChildTask(id: taskId, task: task)
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
        let generation = requestGeneration
        searchTask = Task {
            do {
                let hits = try await operations.search(runtime, root, query)
                guard !Task.isCancelled,
                      owns(runtime, generation: generation),
                      root == rootPath
                else { return }
                searchResults = hits
                isSearching = false
            } catch {
                guard !Task.isCancelled,
                      owns(runtime, generation: generation),
                      root == rootPath
                else { return }
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
        previewImage = nil
        previewError = nil
        isPreviewLoading = true
        let generation = requestGeneration
        previewTask = Task {
            do {
                let content = try await operations.read(runtime, path)
                let imageData = content.kind == "image"
                    ? await Task.detached(priority: .userInitiated) {
                        content.base64.flatMap { Data(base64Encoded: $0) }
                    }.value
                    : nil
                guard !Task.isCancelled,
                      owns(runtime, generation: generation),
                      selectedPath == path
                else { return }
                preview = content
                previewImage = imageData.flatMap(NSImage.init(data:))
                isPreviewLoading = false
            } catch {
                guard !Task.isCancelled,
                      owns(runtime, generation: generation),
                      selectedPath == path
                else { return }
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

    @discardableResult
    private func bind(_ runtime: RuntimeConnection) -> Int {
        guard self.runtime !== runtime else { return requestGeneration }
        invalidateRequests(clearState: true)
        self.runtime = runtime
        followContext = nil
        lastKnownCwd = nil
        return requestGeneration
    }

    func cancelAll() {
        invalidateRequests(clearState: false)
        lastKnownCwd = nil
    }

    private func invalidateRequests(clearState: Bool) {
        requestGeneration &+= 1
        let previewWasLoading = isPreviewLoading
        let tasks = [rootTask, previewTask, searchTask].compactMap { $0 }
        let children = childTasks.values.map(\.task)
        rootTask = nil
        previewTask = nil
        searchTask = nil
        childTasks = [:]
        for node in loadingNodes.values { node.isLoading = false }
        loadingNodes = [:]
        isRootLoading = false
        isPreviewLoading = false
        isSearching = false
        for task in tasks + children { task.cancel() }
        if !clearState, previewWasLoading {
            selectedPath = nil
            preview = nil
            previewImage = nil
            previewError = nil
        }
        guard clearState else { return }
        rootPath = ""
        rootNodes = nil
        rootError = nil
        selectedPath = nil
        preview = nil
        previewImage = nil
        previewError = nil
        searchQuery = ""
        searchResults = nil
        searchError = nil
    }

    private func finishChildTask(path: String, id: Int) {
        guard childTasks[path]?.id == id else { return }
        childTasks[path] = nil
        loadingNodes[path] = nil
    }

    private func owns(_ runtime: RuntimeConnection, generation: Int) -> Bool {
        self.runtime === runtime && requestGeneration == generation
    }
}
