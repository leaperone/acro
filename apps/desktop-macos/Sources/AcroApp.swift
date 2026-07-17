// Acro Desktop:工作区侧边栏 + libghostty 终端表面。
// 终端渲染由 libghostty 完成,surface command 跑 `acro attach <sessionId>`,
// 会话本体永远活在 Runtime 侧的 terminal daemon 里。

import AppKit
import SwiftUI

@main
struct AcroApp: App {
    @StateObject private var runtime = RuntimeConnection()

    var body: some Scene {
        WindowGroup("Acro") {
            ContentView()
                .environmentObject(runtime)
                .onAppear {
                    _ = Ghostty.shared // 初始化 libghostty
                    if let config = ClientConfig.load() {
                        runtime.connect(config: config)
                    }
                }
        }
    }
}

// 解析 attach 命令:node + acro CLI 的绝对路径(GUI 进程没有用户 PATH)
enum AttachCommand {
    static func resolve(sessionId: String) -> String {
        let env = ProcessInfo.processInfo.environment
        let node = env["ACRO_NODE"]
            ?? ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "node"
        let cli = env["ACRO_CLI_PATH"]
            ?? "\(NSHomeDirectory())/project/acro/apps/cli/src/cli.ts"
        return "\(node) \(cli) attach \(sessionId)"
    }
}

struct ContentView: View {
    @EnvironmentObject var runtime: RuntimeConnection
    @State private var selectedSessionId: String?

    var body: some View {
        NavigationSplitView {
            List {
                Section("项目") {
                    ForEach(runtime.projects.indices, id: \.self) { i in
                        let p = runtime.projects[i]
                        HStack {
                            Label(p["name"] as? String ?? "?", systemImage: "folder")
                            Spacer()
                            Button("开终端") {
                                Task {
                                    if let result = try? await runtime.rpc("session.create", [
                                        "projectId": p["id"] as? String ?? "",
                                        "cols": 140,
                                        "rows": 40,
                                    ]) as? [String: Any], let id = result["id"] as? String {
                                        await runtime.refresh()
                                        selectedSessionId = id
                                    }
                                }
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                Section("会话") {
                    ForEach(runtime.sessions.indices, id: \.self) { i in
                        let s = runtime.sessions[i]
                        let alive = s["alive"] as? Bool ?? false
                        let id = s["id"] as? String ?? ""
                        HStack {
                            Circle()
                                .fill(alive ? Color.green : Color.gray)
                                .frame(width: 8, height: 8)
                            Text(s["command"] as? String ?? "?")
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if alive { selectedSessionId = id }
                        }
                        .listRowBackground(selectedSessionId == id ? Color.accentColor.opacity(0.2) : nil)
                    }
                }
            }
            .listStyle(.sidebar)
        } detail: {
            if let sessionId = selectedSessionId {
                AcroTerminalView(
                    command: AttachCommand.resolve(sessionId: sessionId),
                    onClose: { selectedSessionId = nil }
                )
                .id(sessionId) // 切换会话时重建 surface
            } else if runtime.connected {
                Text("选择会话,或在项目上点\u{201C}开终端\u{201D}")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    Text("未连接 Runtime")
                    Text("先用 acro pair <host:port> 完成配对")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}
