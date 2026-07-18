// 本地优先:桌面 App 自己保证本机有一个可用的 runtime,并静默配对。
// 已有 LaunchAgent / 手动 runtime 时只配对不重复拉起。
// App 拉起的 runtime 随 App 退出而结束,但终端会话活在独立的 daemon 里不受影响。

import Foundation

@MainActor
final class LocalRuntimeManager {
    // runtime config 默认端口(apps/runtime/src/config.ts)
    static let port = 8790
    private var spawnAttempted = false

    func ensureLocalRuntime(hub: RuntimeHub) async {
        if await healthy() {
            ensurePaired(hub: hub)
            return
        }
        guard spawnBundledRuntime() else { return }
        // 等它起来(最多 8s),起来后静默配对
        for _ in 0..<16 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await healthy() {
                ensurePaired(hub: hub)
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

    // 配置里已有本机条目(全回环入口)就不动;
    // 没有则读 runtime 首启写下的 bootstrap 配对码,静默配对成"本机"
    private func ensurePaired(hub: RuntimeHub) {
        if ClientConfig.load()?.servers.contains(where: { $0.isLocal }) == true { return }
        let bootstrapPath = "\(NSHomeDirectory())/.acro/bootstrap-offer.txt"
        guard let raw = try? String(contentsOfFile: bootstrapPath, encoding: .utf8) else { return }
        _ = try? ServerDirectory.pair(offerText: raw, name: "本机", hub: hub)
    }

    private func spawnBundledRuntime() -> Bool {
        guard !spawnAttempted, let resources = Bundle.main.resourcePath else { return false }
        spawnAttempted = true
        let runtimeEntry = "\(resources)/runtime/runtime.cjs"
        guard FileManager.default.fileExists(atPath: runtimeEntry),
              let node = Self.findNode()
        else { return false }

        let logPath = "\(NSHomeDirectory())/.acro/app-runtime.log"
        try? FileManager.default.createDirectory(
            atPath: "\(NSHomeDirectory())/.acro", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logPath, contents: nil)
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
            return true
        } catch {
            return false
        }
    }

    // 与 AttachCommand 相同的 node 候选序(GUI 进程没有用户 PATH)
    static func findNode() -> String? {
        let env = ProcessInfo.processInfo.environment
        return [
            env["ACRO_NODE"],
            "/opt/homebrew/bin/node",
            "/opt/homebrew/opt/node@22/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ]
        .compactMap { $0 }
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
