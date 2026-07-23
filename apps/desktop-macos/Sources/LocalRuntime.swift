// 本地优先:桌面 App 自己保证本机有一个可用的 runtime,并静默配对。
// 已有 LaunchAgent / 手动 runtime 时只配对不重复拉起;App 拉起的 runtime
// 在 App 退出时被终止(终端会话活在独立的 daemon 里不受影响),
// 下次启动总是拉当前版本的 bundle,避免孤儿旧版 runtime 长期占坑。

import AppKit
import Foundation

enum NodeExecutable {
    static func resolve(
        runtimeNode: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resourcePath: String? = Bundle.main.resourcePath,
        fileManager: FileManager = .default
    ) -> String? {
        let bundledNode = resourcePath.map { "\($0)/node" }
        return [
            environment["ACRO_NODE"],
            bundledNode,
            runtimeNode,
            "/opt/homebrew/bin/node",
            "/opt/homebrew/opt/node@22/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ]
        .compactMap { $0 }
        .first { fileManager.isExecutableFile(atPath: $0) }
    }
}

enum LocalRuntimeAvailability: Equatable {
    case healthy
    case unavailable
    case unresponsive

    static func classify(statusCode: Int?, error: Error?) -> Self {
        if statusCode == 200 { return .healthy }
        let nsError = error as NSError?
        if nsError?.domain == NSURLErrorDomain,
           nsError?.code == URLError.Code.cannotConnectToHost.rawValue {
            return .unavailable
        }
        return .unresponsive
    }
}

enum LocalRuntimeRecoveryAction: Equatable {
    case ensurePaired
    case spawnBundled
    case terminateOwned
    case wait
}

struct LocalRuntimeRecoveryPolicy {
    private let unhealthyLimit: Int
    private let stableHealthyLimit: Int
    private let retryDelays: [TimeInterval]
    private(set) var consecutiveOwnedFailures = 0
    private(set) var terminationRequested = false
    private(set) var retryNotBefore: Date?
    private var consecutiveHealthyChecks = 0
    private var retryIndex = 0

    init(
        unhealthyLimit: Int = 5,
        stableHealthyLimit: Int = 3,
        retryDelays: [TimeInterval] = [2, 5, 10, 30]
    ) {
        self.unhealthyLimit = max(unhealthyLimit, 1)
        self.stableHealthyLimit = max(stableHealthyLimit, 1)
        self.retryDelays = retryDelays.isEmpty ? [2] : retryDelays
    }

    mutating func action(
        availability: LocalRuntimeAvailability,
        ownsRunningProcess: Bool,
        now: Date = Date()
    ) -> LocalRuntimeRecoveryAction {
        if availability == .healthy {
            consecutiveOwnedFailures = 0
            terminationRequested = false
            retryNotBefore = nil
            consecutiveHealthyChecks += 1
            if consecutiveHealthyChecks >= stableHealthyLimit { retryIndex = 0 }
            return .ensurePaired
        }
        consecutiveHealthyChecks = 0
        guard ownsRunningProcess else {
            consecutiveOwnedFailures = 0
            terminationRequested = false
            guard availability == .unavailable else { return .wait }
            if let retryNotBefore, now < retryNotBefore { return .wait }
            return .spawnBundled
        }
        guard !terminationRequested else { return .wait }
        consecutiveOwnedFailures += 1
        guard consecutiveOwnedFailures >= unhealthyLimit else { return .wait }
        terminationRequested = true
        return .terminateOwned
    }

    mutating func ownedProcessStarted() {
        retryNotBefore = nil
    }

    mutating func spawnFailed(at now: Date = Date()) {
        consecutiveHealthyChecks = 0
        scheduleRetry(at: now)
    }

    mutating func ownedProcessExited(at now: Date = Date()) {
        consecutiveOwnedFailures = 0
        terminationRequested = false
        consecutiveHealthyChecks = 0
        scheduleRetry(at: now)
    }

    private mutating func scheduleRetry(at now: Date) {
        let delay = retryDelays[min(retryIndex, retryDelays.count - 1)]
        retryIndex = min(retryIndex + 1, retryDelays.count - 1)
        retryNotBefore = now.addingTimeInterval(delay)
    }
}

@MainActor
final class LocalRuntimeManager {
    // runtime config 默认端口(apps/runtime/src/config.ts)
    static let port = 8790
    private var spawnedProcess: Process?
    private var terminateObserver: NSObjectProtocol?
    private var recoveryPolicy = LocalRuntimeRecoveryPolicy()

    func monitor(hub: RuntimeHub) async {
        while !Task.isCancelled {
            await ensureLocalRuntime(hub: hub)
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
        }
    }

    func ensureLocalRuntime(hub: RuntimeHub) async {
        let availability = await availability()
        guard !Task.isCancelled else { return }
        if Self.consumeExitedProcess(&spawnedProcess) {
            recoveryPolicy.ownedProcessExited()
        }
        // consume 后只看 slot 是否仍归本管理器持有，不再次读取 isRunning。
        // 若进程刚在两行之间退出，宁可多等一轮，让退出回调或下一轮统一记账。
        let ownsRunningProcess = spawnedProcess != nil
        switch recoveryPolicy.action(
            availability: availability,
            ownsRunningProcess: ownsRunningProcess
        ) {
        case .ensurePaired:
            await ensurePaired(hub: hub)
        case .spawnBundled:
            guard spawnedProcess == nil else { break }
            if spawnBundledRuntime() {
                recoveryPolicy.ownedProcessStarted()
            } else {
                recoveryPolicy.spawnFailed()
            }
        case .terminateOwned:
            spawnedProcess?.terminate()
        case .wait:
            break
        }
    }

    private func availability() async -> LocalRuntimeAvailability {
        guard let url = URL(string: "http://127.0.0.1:\(Self.port)/health") else {
            return .unresponsive
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return LocalRuntimeAvailability.classify(
                statusCode: (response as? HTTPURLResponse)?.statusCode,
                error: nil
            )
        } catch {
            return LocalRuntimeAvailability.classify(statusCode: nil, error: error)
        }
    }

    // 本机配对码只从当前用户的 0700 state 目录读取。回环 HTTP 无法区分
    // 本机不同账号，不能承载会授予终端与 Computer Use 权限的凭据。
    private func ensurePaired(hub: RuntimeHub) async {
        let statePath = ProcessInfo.processInfo.environment["ACRO_STATE_DIR"]
            ?? "\(NSHomeDirectory())/.acro"
        let path = "\(statePath)/local-offer.txt"
        guard let data = FileManager.default.contents(atPath: path),
              let offer = String(data: data, encoding: .utf8)
        else { return }
        _ = try? ServerDirectory.pairLocal(offerText: offer, hub: hub)
    }

    private func spawnBundledRuntime() -> Bool {
        guard spawnedProcess == nil else { return false }
        guard let resources = Bundle.main.resourcePath else { return false }
        let runtimeEntry = "\(resources)/runtime/runtime.cjs"
        guard FileManager.default.fileExists(atPath: runtimeEntry),
              let node = NodeExecutable.resolve()
        else { return false }

        let statePath = "\(NSHomeDirectory())/.acro"
        let logPath = "\(statePath)/app-runtime.log"
        do {
            try FileManager.default.createDirectory(
                atPath: statePath, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: statePath)
            if !FileManager.default.fileExists(atPath: logPath) {
                FileManager.default.createFile(
                    atPath: logPath, contents: nil,
                    attributes: [.posixPermissions: 0o600])
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: logPath)
        } catch {
            return false
        }
        let log = FileHandle(forWritingAtPath: logPath)
        log?.seekToEndOfFile()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [runtimeEntry]
        var env = ProcessInfo.processInfo.environment
        // 打包形态下 daemon 入口在 app 资源里,由环境变量显式指定
        env["ACRO_DAEMON_ENTRY"] = "\(resources)/runtime/daemon.cjs"
        process.environment = env
        if let log {
            process.standardOutput = log
            process.standardError = log
        }
        do {
            try process.run()
            spawnedProcess = process
            process.terminationHandler = { [weak self, weak process] _ in
                Task { @MainActor in
                    guard let self, self.spawnedProcess === process else { return }
                    self.spawnedProcess = nil
                    self.recoveryPolicy.ownedProcessExited()
                }
            }
            // 只终止自己拉起的 runtime;LaunchAgent/手动 runtime 不归 App 管
            if terminateObserver == nil {
                terminateObserver = NotificationCenter.default.addObserver(
                    forName: NSApplication.willTerminateNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.spawnedProcess?.terminate()
                    }
                }
            }
            return true
        } catch {
            return false
        }
    }

    static func consumeExitedProcess(_ process: inout Process?) -> Bool {
        guard let current = process, !current.isRunning else { return false }
        process = nil
        return true
    }

    deinit {
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
    }

}
