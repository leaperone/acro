// Git 面板状态。数据经 git.status / git.diff RPC 从 Mac mini 取(只读)。

import Foundation

// git.diff 的内联结果(非 codegen 模型),手写解码。
struct GitDiffResult: Decodable {
    let diff: String
    let truncated: Bool
}

@MainActor
final class GitPanelModel: ObservableObject {
    @Published private(set) var status: GitStatus?
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    @Published private(set) var selectedPath: String?
    @Published private(set) var diff: String?
    @Published private(set) var diffTruncated = false
    @Published private(set) var isDiffLoading = false
    @Published private(set) var diffError: String?

    private weak var runtime: RuntimeConnection?
    private var currentRoot = ""
    private var diffTask: Task<Void, Never>?

    func sync(root: String, runtime: RuntimeConnection) {
        self.runtime = runtime
        if root == currentRoot, status != nil || isLoading { return }
        currentRoot = root
        selectedPath = nil
        diff = nil
        reload()
    }

    func reload() {
        guard let runtime else { return }
        isLoading = true
        loadError = nil
        let root = currentRoot
        Task {
            do {
                let result = try await runtime.rpc("git.status", ["path": root], as: GitStatus.self)
                guard root == currentRoot else { return }
                status = result
                isLoading = false
            } catch {
                guard root == currentRoot else { return }
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
        diffTask = Task {
            do {
                let result = try await runtime.rpc("git.diff", ["path": path], as: GitDiffResult.self)
                guard !Task.isCancelled, selectedPath == path else { return }
                diff = result.diff
                diffTruncated = result.truncated
                isDiffLoading = false
            } catch {
                guard !Task.isCancelled, selectedPath == path else { return }
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
}
