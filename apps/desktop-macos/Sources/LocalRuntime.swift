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

@MainActor
final class LocalRuntimeManager {
    // runtime config 默认端口(apps/runtime/src/config.ts)
    static let port = 8790
    private var spawnAttempted = false
    private var spawnedProcess: Process?
    private var terminateObserver: NSObjectProtocol?

    func ensureLocalRuntime(hub: RuntimeHub) async {
        if await healthy() {
            await ensurePaired(hub: hub)
            return
        }
        guard spawnBundledRuntime() else { return }
        // 等它起来(最多 8s),起来后静默配对
        for _ in 0..<16 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await healthy() {
                await ensurePaired(hub: hub)
                return
            }
        }
    }

    private func healthy() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(Self.port)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else {
            return false
        }
        return (response as? HTTPURLResponse)?.statusCode == 200
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
        guard !spawnAttempted, let resources = Bundle.main.resourcePath else { return false }
        spawnAttempted = true
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
            // 只终止自己拉起的 runtime;LaunchAgent/手动 runtime 不归 App 管
            terminateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak process] _ in
                process?.terminate()
            }
            return true
        } catch {
            return false
        }
    }

    deinit {
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
    }

}
