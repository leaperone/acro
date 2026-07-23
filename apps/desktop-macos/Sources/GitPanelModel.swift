// Git 面板状态。数据经 git.status / git.diff RPC 从 Mac mini 取(只读)。

import Foundation

// git.diff 的内联结果(非 codegen 模型),手写解码。
struct GitDiffResult: Decodable {
    let diff: String
    let truncated: Bool
}

@MainActor
final class GitPanelModel: ObservableObject {
    struct Operations {
        let cwd: (RuntimeConnection, String) async throws -> String?
        let status: (RuntimeConnection, String) async throws -> GitStatus
        let diff: (RuntimeConnection, String) async throws -> GitDiffResult

        static let live = Operations(
            cwd: { runtime, sessionId in
                try await runtime.rpc(
                    "session.cwd", ["sessionId": sessionId], as: SessionCwd.self
                ).cwd
            },
            status: { runtime, root in
                try await runtime.rpc("git.status", ["path": root], as: GitStatus.self)
            },
            diff: { runtime, path in
                try await runtime.rpc("git.diff", ["path": path], as: GitDiffResult.self)
            }
        )
    }

    private struct FollowContext: Equatable {
        let runtime: ObjectIdentifier
        let sessionId: String?
    }

    @Published private(set) var status: GitStatus?
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    @Published private(set) var selectedPath: String?
    @Published private(set) var diff: String?
    @Published private(set) var diffTruncated = false
    @Published private(set) var isDiffLoading = false
    @Published private(set) var diffError: String?

    private weak var runtime: RuntimeConnection?
    private let operations: Operations
    private var currentRoot = ""
    private var requestGeneration = 0
    private var lastKnownCwd: String?
    private var followContext: FollowContext?
    private var statusTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?

    init(operations: Operations = .live) {
        self.operations = operations
    }

    func sync(root: String, runtime: RuntimeConnection) {
        bind(runtime)
        if root == currentRoot, status != nil || isLoading { return }
        currentRoot = root
        selectedPath = nil
        diff = nil
        reload()
    }

    func beginFollow(sessionId: String?, runtime: RuntimeConnection) {
        let next = FollowContext(runtime: ObjectIdentifier(runtime), sessionId: sessionId)
        guard followContext != next else { return }
        invalidateRequests(clearState: true)
        self.runtime = runtime
        followContext = next
        lastKnownCwd = nil
    }

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
                sync(root: cwd, runtime: runtime)
            }
        } catch {
            // 会话结束或连接切换时保留最后一份可用状态,下一轮继续跟随。
        }
    }

    func reload() {
        guard let runtime else { return }
        statusTask?.cancel()
        isLoading = true
        loadError = nil
        let root = currentRoot
        let generation = requestGeneration
        statusTask = Task {
            do {
                let result = try await operations.status(runtime, root)
                guard !Task.isCancelled,
                      owns(runtime, generation: generation),
                      root == currentRoot
                else { return }
                status = result
                isLoading = false
            } catch {
                guard !Task.isCancelled,
                      owns(runtime, generation: generation),
                      root == currentRoot
                else { return }
                loadError = Self.friendly(error)
                status = nil
                isLoading = false
            }
        }
    }

    func selectFile(_ path: String) {
        selectedPath = path
        loadDiff(path)
    }

    private func loadDiff(_ path: String) {
        guard let runtime else { return }
        diffTask?.cancel()
        isDiffLoading = true
        diff = nil
        diffError = nil
        diffTruncated = false
        let generation = requestGeneration
        diffTask = Task {
            do {
                let result = try await operations.diff(runtime, path)
                guard !Task.isCancelled,
                      owns(runtime, generation: generation),
                      selectedPath == path
                else { return }
                diff = result.diff
                diffTruncated = result.truncated
                isDiffLoading = false
            } catch {
                guard !Task.isCancelled,
                      owns(runtime, generation: generation),
                      selectedPath == path
                else { return }
                diffError = Self.friendly(error)
                isDiffLoading = false
            }
        }
    }

    private static func friendly(_ error: Error) -> String {
        let message = (error as? RpcError)?.message ?? error.localizedDescription
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
        let diffWasLoading = isDiffLoading
        let tasks = [statusTask, diffTask].compactMap { $0 }
        statusTask = nil
        diffTask = nil
        isLoading = false
        isDiffLoading = false
        for task in tasks { task.cancel() }
        if !clearState, diffWasLoading {
            selectedPath = nil
            diff = nil
            diffTruncated = false
            diffError = nil
        }
        guard clearState else { return }
        currentRoot = ""
        status = nil
        loadError = nil
        selectedPath = nil
        diff = nil
        diffTruncated = false
        diffError = nil
    }

    private func owns(_ runtime: RuntimeConnection, generation: Int) -> Bool {
        self.runtime === runtime && requestGeneration == generation
    }
}
