// ⌘, 设置窗口:通用 / 快捷键 / 外观。
// 结构与快捷键录制交互取自 cmux 的 Settings 窗口与 KeyboardShortcutRecorder
// (GPL-3.0-or-later, Copyright (c) 2024-present Manaflow, Inc.),按 acro 精简。

import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var runtime: RuntimeConnection

    var body: some View {
        TabView {
            GeneralSettingsPane(runtime: runtime)
                .tabItem { Label("通用", systemImage: "gearshape") }
            ShortcutSettingsPane()
                .tabItem { Label("快捷键", systemImage: "keyboard") }
            AppearanceSettingsPane()
                .tabItem { Label("外观", systemImage: "paintbrush") }
        }
        .frame(width: 560)
    }
}

// ---- 通用 ----

private struct GeneralSettingsPane: View {
    @ObservedObject var runtime: RuntimeConnection
    private let config = ClientConfig.load()

    var body: some View {
        Form {
            Section("Runtime 连接") {
                LabeledContent("状态") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(runtime.connected ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(stateText)
                    }
                }
                LabeledContent("地址", value: config?.host ?? "未配对")
                LabeledContent("设备 ID") {
                    Text(config?.deviceId ?? "-")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("工作区 / 终端", value: "\(runtime.workspaces.count) / \(runtime.sessions.count { $0.alive })")
            }

            Section("配置文件") {
                pathRow("配对凭据", path: "\(NSHomeDirectory())/.acro/client.json")
                pathRow("快捷键覆写", path: ShortcutStore.settingsFilePath)
                pathRow("终端外观", path: TerminalAppearance.confPath)
            }

            Section {
                LabeledContent("许可", value: "GPL-3.0-or-later")
                LabeledContent("取材", value: "cmux · orca · muxy · ghostty")
            }
        }
        .formStyle(.grouped)
        .frame(height: 380)
    }

    private var stateText: String {
        switch runtime.state {
        case .connected: "已连接"
        case .connecting: "正在连接…"
        case .disconnected: "未连接"
        }
    }

    private func pathRow(_ label: String, path: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(("~" as NSString).appendingPathComponent(
                    path.replacingOccurrences(of: NSHomeDirectory(), with: "")
                ))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Image(systemName: "arrow.right.circle")
                }
                .buttonStyle(.borderless)
                .help("在 Finder 中显示")
                .accessibilityLabel("在 Finder 中显示 \(label)")
            }
        }
    }
}

// ---- 快捷键 ----

private struct ShortcutSettingsPane: View {
    @ObservedObject private var store = ShortcutStore.shared
    @State private var recordingAction: ShortcutAction?
    @State private var feedback: String?
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(ShortcutAction.allCases) { action in
                        row(action)
                    }
                } footer: {
                    Text("⌘1-9 固定用于切换工作区。菜单栏中的快捷键在重启应用后更新，其余立即生效。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            if let feedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
        .frame(height: 420)
        .onDisappear(perform: stopRecording)
    }

    private func row(_ action: ShortcutAction) -> some View {
        LabeledContent(action.title) {
            HStack(spacing: 6) {
                Button {
                    recordingAction == action ? stopRecording() : beginRecording(action)
                } label: {
                    Text(recordingAction == action ? "按下新快捷键…" : store.stored(action).displayString)
                        .font(.callout.monospaced())
                        .frame(minWidth: 110)
                }
                .buttonStyle(.bordered)
                .tint(recordingAction == action ? .accentColor : nil)
                .accessibilityLabel("录制 \(action.title) 快捷键")

                Button {
                    store.reset(action)
                    feedback = nil
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .disabled(!store.isOverridden(action))
                .help("恢复默认")
                .accessibilityLabel("恢复 \(action.title) 默认快捷键")
            }
        }
    }

    // cmux KeyboardShortcutRecorder 的精简版:local monitor 抓下一次按键
    private func beginRecording(_ action: ShortcutAction) {
        stopRecording()
        recordingAction = action
        feedback = nil
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleRecorded(event, for: action)
            return nil
        }
    }

    private func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        recordingAction = nil
    }

    private func handleRecorded(_ event: NSEvent, for action: ShortcutAction) {
        if event.keyCode == 53 { // Esc 取消
            stopRecording()
            return
        }
        let shortcut = StoredShortcut.from(event)
        guard shortcut.hasModifier else {
            feedback = "快捷键至少需要 ⌘、⌥ 或 ⌃ 修饰键"
            return
        }
        if let conflict = ShortcutStore.shared.conflict(of: shortcut, excluding: action) {
            feedback = "\(shortcut.displayString) 已被「\(conflict.title)」占用"
            return
        }
        ShortcutStore.shared.set(shortcut, for: action)
        feedback = nil
        stopRecording()
    }
}

// ---- 外观(写 ghostty conf,启动时加载) ----

enum TerminalAppearance {
    static let confPath = "\(NSHomeDirectory())/.config/acro/ghostty.conf"

    static func write(fontFamily: String, fontSize: Int, theme: String) {
        var lines: [String] = ["# 由 Acro 设置窗口生成;重启应用后生效"]
        let family = fontFamily.trimmingCharacters(in: .whitespaces)
        if !family.isEmpty { lines.append("font-family = \(family)") }
        if fontSize > 0 { lines.append("font-size = \(fontSize)") }
        let trimmedTheme = theme.trimmingCharacters(in: .whitespaces)
        if !trimmedTheme.isEmpty { lines.append("theme = \(trimmedTheme)") }
        let directory = (confPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").appending("\n")
            .write(toFile: confPath, atomically: true, encoding: .utf8)
    }
}

private struct AppearanceSettingsPane: View {
    @AppStorage("acro.terminal.font-family") private var fontFamily = ""
    @AppStorage("acro.terminal.font-size") private var fontSize = 0
    @AppStorage("acro.terminal.theme") private var theme = ""

    var body: some View {
        Form {
            Section {
                TextField("字体(留空使用默认)", text: $fontFamily, prompt: Text("JetBrains Mono"))
                LabeledContent("字号") {
                    Stepper(value: $fontSize, in: 0...32) {
                        Text(fontSize > 0 ? "\(fontSize) pt" : "默认")
                    }
                }
                TextField("主题(ghostty 主题名,留空使用默认)", text: $theme, prompt: Text("catppuccin-mocha"))
            } header: {
                Text("终端")
            } footer: {
                Text("写入 ~/.config/acro/ghostty.conf,重启应用后生效。主题名参考 ghostty 内置主题列表。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 300)
        .onChange(of: fontFamily) { _, _ in persist() }
        .onChange(of: fontSize) { _, _ in persist() }
        .onChange(of: theme) { _, _ in persist() }
    }

    private func persist() {
        TerminalAppearance.write(fontFamily: fontFamily, fontSize: fontSize, theme: theme)
    }
}
