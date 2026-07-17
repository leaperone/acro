// Acro Desktop 骨架:工作区侧边栏 + 会话列表。
// 终端渲染下一步接 libghostty(acro attach 作 surface command,集成方式取自 muxy);
// 骨架阶段先用 Terminal.app 打开 attach 会话,保证桌面端立即可用。

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
                    if let config = ClientConfig.load() {
                        runtime.connect(config: config)
                    }
                }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var runtime: RuntimeConnection

    var body: some View {
        NavigationSplitView {
            List {
                Section("项目") {
                    ForEach(runtime.projects.indices, id: \.self) { i in
                        let p = runtime.projects[i]
                        Label(p["name"] as? String ?? "?", systemImage: "folder")
                    }
                }
                Section("会话") {
                    ForEach(runtime.sessions.indices, id: \.self) { i in
                        let s = runtime.sessions[i]
                        let alive = s["alive"] as? Bool ?? false
                        HStack {
                            Circle()
                                .fill(alive ? Color.green : Color.gray)
                                .frame(width: 8, height: 8)
                            Text(s["command"] as? String ?? "?")
                                .lineLimit(1)
                            Spacer()
                            if alive, let id = s["id"] as? String {
                                Button("attach") { openInTerminal(sessionId: id) }
                                    .buttonStyle(.link)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        } detail: {
            if runtime.connected {
                Text("选择会话,或用 acro CLI 创建")
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
        .frame(minWidth: 720, minHeight: 480)
    }

    // ponytail: 骨架阶段借 Terminal.app 跑 `acro attach`;libghostty surface 落地后替换
    private func openInTerminal(sessionId: String) {
        let script = "tell application \"Terminal\" to do script \"acro attach \(sessionId)\""
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            NSWorkspace.shared.launchApplication("Terminal")
        }
    }
}
