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
    @AppStorage(WorkbenchModel.confirmCloseTabKey) private var confirmCloseTab = true
    @State private var config = ClientConfig.load()
    @State private var pairInput = ""
    @State private var pairError: String?
    @State private var newEndpoint = ""

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
                LabeledContent("服务器", value: config?.activeServer?.name ?? "未配对")
                LabeledContent("设备 ID") {
                    Text(config?.activeServer?.deviceId ?? "-")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("工作区 / 终端", value: "\(runtime.workspaces.count) / \(runtime.sessions.count { $0.alive })")
            }

            Section {
                if let server = config?.activeServer {
                    ForEach(server.endpoints, id: \.self) { endpoint in
                        LabeledContent(endpoint) {
                            HStack(spacing: 6) {
                                if runtime.connectedEndpoint == endpoint {
                                    Text("当前").font(.caption).foregroundStyle(.green)
                                }
                                Button {
                                    removeEndpoint(endpoint)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .disabled(server.endpoints.count <= 1)
                                .help("删除入口")
                            }
                        }
                        .font(.callout.monospaced())
                    }
                    HStack {
                        TextField("新入口 (如 frp.example.com:7100)", text: $newEndpoint)
                            .textFieldStyle(.roundedBorder)
                        Button("添加") { addEndpoint() }
                            .disabled(newEndpoint.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                HStack {
                    TextField(
                        config?.activeServer == nil ? "粘贴配对码 (acro://pair?c=…)" : "粘贴新配对码可重新配对",
                        text: $pairInput
                    )
                    .textFieldStyle(.roundedBorder)
                    Button("配对") { pair() }
                        .disabled(pairInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let pairError {
                    Text(pairError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("服务器与入口")
            } footer: {
                Text("多个入口共用同一凭据,按序尝试:在家走 LAN 直连,出门自动落到 FRP 等公网入口。连上后控制权与工作进度完全一致。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if runtime.connected {
                ShareAccessSection(runtime: runtime)
            }

            Section {
                Toggle("关闭标签时二次确认", isOn: $confirmCloseTab)
            } header: {
                Text("行为")
            } footer: {
                Text("开启时,⌘W 或点击标签 × 会先弹出确认框(回车可直接确认);关闭后立即终止终端。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("配置文件") {
                pathRow("配对凭据", path: ClientConfig.path)
                pathRow("快捷键覆写", path: ShortcutStore.settingsFilePath)
                pathRow("终端外观", path: TerminalAppearance.confPath)
            }

            Section {
                LabeledContent("许可", value: "GPL-3.0-or-later")
                LabeledContent("取材", value: "cmux · orca · muxy · ghostty")
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
    }

    private var stateText: String {
        switch runtime.state {
        case .connected: "已连接(\(runtime.connectedEndpoint ?? "-"))"
        case .connecting: "正在连接…"
        case .disconnected: "未连接"
        }
    }

    // 粘贴配对码:落盘 → 立即连接;deviceId 在认证成功后由连接层补写
    private func pair() {
        do {
            let offer = try PairingOffer.decode(pairInput)
            var next = config ?? ClientConfig(v: 2, servers: [], active: nil)
            let name = offer.endpoints.first ?? "Runtime"
            next.servers.removeAll { $0.name == name }
            let entry = ServerEntry(
                name: name, deviceId: "", token: offer.token,
                pub: offer.pub, endpoints: offer.endpoints)
            next.servers.append(entry)
            next.save()
            config = next
            pairInput = ""
            pairError = nil
            runtime.connect(server: entry)
        } catch {
            pairError = error.localizedDescription
        }
    }

    private func addEndpoint() {
        let endpoint = newEndpoint.trimmingCharacters(in: .whitespaces)
        guard !endpoint.isEmpty else { return }
        mutateActiveServer { server in
            if !server.endpoints.contains(endpoint) { server.endpoints.append(endpoint) }
        }
        newEndpoint = ""
    }

    private func removeEndpoint(_ endpoint: String) {
        mutateActiveServer { server in
            guard server.endpoints.count > 1 else { return }
            server.endpoints.removeAll { $0 == endpoint }
        }
    }

    private func mutateActiveServer(_ change: (inout ServerEntry) -> Void) {
        guard var next = config, let active = next.activeServer,
              let idx = next.servers.firstIndex(where: { $0.id == active.id })
        else { return }
        change(&next.servers[idx])
        next.save()
        config = next
        runtime.connect(server: next.servers[idx])
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

// ---- 共享服务器访问(对标 orca 的 runtime access grants) ----

private struct ShareAccessSection: View {
    @ObservedObject var runtime: RuntimeConnection
    @State private var devices: [Device] = []
    @State private var shareName = ""
    @State private var shareExtraEndpoint = ""
    @State private var generatedOffer: String?
    @State private var shareError: String?

    var body: some View {
        Section {
            HStack {
                TextField("名称(可选)", text: $shareName)
                    .textFieldStyle(.roundedBorder)
                TextField("公网入口(可选,如 frp.example.com:7100)", text: $shareExtraEndpoint)
                    .textFieldStyle(.roundedBorder)
                Button("新链接") { Task { await createShare() } }
            }
            if let generatedOffer {
                HStack(spacing: 6) {
                    Text(generatedOffer)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(generatedOffer, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("复制配对码")
                }
            }
            if let shareError {
                Text(shareError).font(.caption).foregroundStyle(.red)
            }
            ForEach(devices) { device in
                LabeledContent(device.name) {
                    HStack(spacing: 8) {
                        Text(device.lastSeenAt.map { "最后使用 \(shortDate($0))" } ?? "未使用")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            Task { await revoke(device) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .help("撤销授权并断开该设备")
                    }
                }
            }
        } header: {
            Text("共享服务器访问")
        } footer: {
            Text("任何持有效配对码的设备都可以连接,直到撤销为止;撤销会立即断开该设备的活动连接。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await reload() }
    }

    private func reload() async {
        devices = (try? await runtime.rpc("device.list", as: [Device].self)) ?? []
    }

    private func createShare() async {
        shareError = nil
        var params: [String: Any] = [:]
        let name = shareName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { params["name"] = name }
        let extra = shareExtraEndpoint.trimmingCharacters(in: .whitespaces)
        if !extra.isEmpty { params["extraEndpoints"] = [extra] }
        do {
            struct ShareResult: Decodable { let offer: String; let deviceId: String }
            let result = try await runtime.rpc("device.share", params, as: ShareResult.self)
            generatedOffer = result.offer
            await reload()
        } catch {
            shareError = error.localizedDescription
        }
    }

    private func revoke(_ device: Device) async {
        shareError = nil
        do {
            _ = try await runtime.rpc("device.revoke", ["deviceId": device.id])
            await reload()
        } catch {
            shareError = error.localizedDescription
        }
    }

    private func shortDate(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        // runtime 侧 toISOString() 带毫秒
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .shortened)
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
