// ⌘, 设置窗口:通用 / 远程 / 快捷键 / 外观。
// 结构与快捷键录制交互取自 cmux 的 Settings 窗口与 KeyboardShortcutRecorder
// (GPL-3.0-or-later, Copyright (c) 2024-present Manaflow, Inc.),按 acro 精简。
// 「远程」页对标 orca(MIT, Copyright (c) stablyai)的 Remote Orca Server 设置页。

import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var runtime: RuntimeConnection

    var body: some View {
        TabView {
            GeneralSettingsPane(runtime: runtime)
                .tabItem { Label("通用", systemImage: "gearshape") }
            RemoteSettingsPane(runtime: runtime)
                .tabItem { Label("远程", systemImage: "antenna.radiowaves.left.and.right") }
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

    var body: some View {
        Form {
            Section {
                LabeledContent("状态") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(runtime.connected ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(stateText)
                    }
                }
                LabeledContent("服务器", value: ClientConfig.load()?.activeServer?.name ?? "未配对")
                LabeledContent("工作区 / 终端", value: "\(runtime.workspaces.count) / \(runtime.sessions.count { $0.alive })")
            } header: {
                Text("Runtime 连接")
            } footer: {
                Text("配对、切换服务器和共享访问在「远程」标签页管理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .frame(height: 420)
    }

    private var stateText: String {
        switch runtime.state {
        case .connected: "已连接(\(runtime.connectedEndpoint ?? "-"))"
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

// ---- 远程(对标 orca 的 Remote Orca Server 设置页) ----
// 三块职责:连接到远程服务器(配对/切换/删除)→ 入口地址(LAN + 公网)→ 共享此服务器(生成/撤销授权)。

private struct RemoteSettingsPane: View {
    @ObservedObject var runtime: RuntimeConnection
    @State private var config = ClientConfig.load()

    var body: some View {
        Form {
            Section {
                Text("Runtime(如 Mac mini)持有仓库、终端会话和浏览器;这台设备只是它的一块屏幕。从任何入口连上都是同一批工作区和会话,断线重连不丢进度。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ConnectServersSection(runtime: runtime, config: $config)

            if config?.activeServer != nil {
                EndpointsSection(runtime: runtime, config: $config)
            }

            ShareServerSection(runtime: runtime)

            Section("使用说明") {
                VStack(alignment: .leading, spacing: 6) {
                    helpRow("1", "在 Runtime 所在的 Mac 上打开 Acro,进入本页「共享此服务器」,点「生成配对码」。要在外网使用,先把 FRP 等公网地址填进「公网入口」一起打包。")
                    helpRow("2", "把配对码复制给要连接的设备:MacBook 粘贴在本页「连接到远程服务器」,iPhone 粘贴在 App 首屏。每台设备只需配对一次。")
                    helpRow("3", "连接自动选路:局域网可达就直连,不可达自动切到公网入口。所有流量端到端加密,不依赖代理提供 TLS。")
                    helpRow("4", "不再信任某台设备时,在「已授权设备」点撤销,它会立即断线;它持有的配对码同时作废。")
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .frame(height: 620)
        .onChange(of: runtime.state) { _, _ in
            // 认证成功后连接层会补写 deviceId,重新读盘保持一致
            config = ClientConfig.load()
        }
    }

    private func helpRow(_ index: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(index)
                .font(.caption.bold().monospaced())
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// 已配对服务器列表 + 粘贴配对码添加
private struct ConnectServersSection: View {
    @ObservedObject var runtime: RuntimeConnection
    @Binding var config: ClientConfig?
    @State private var pairInput = ""
    @State private var pairName = ""
    @State private var pairError: String?

    var body: some View {
        Section {
            if let servers = config?.servers, !servers.isEmpty {
                ForEach(servers) { server in
                    serverRow(server)
                }
            } else {
                Text("没有已配对的服务器。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("粘贴配对码 (acro://pair?c=…)", text: $pairInput)
                        .textFieldStyle(.roundedBorder)
                    TextField("名称(可选)", text: $pairName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    Button("添加并连接") { pair() }
                        .disabled(pairInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let pairError {
                    Text(pairError).font(.caption).foregroundStyle(.red)
                }
            }
        } header: {
            Text("连接到远程服务器")
        } footer: {
            Text("配对码在远程 Mac 的 Acro「设置 → 远程 → 共享此服务器」里生成,包含地址、凭据和加密公钥,配对一次即可。带绿点的是当前服务器。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func serverRow(_ server: ServerEntry) -> some View {
        let isActive = config?.activeServer?.id == server.id
        return LabeledContent {
            HStack(spacing: 8) {
                if isActive {
                    Text(stateText)
                        .font(.caption)
                        .foregroundStyle(runtime.connected ? .green : .orange)
                } else {
                    Button("连接") { switchTo(server) }
                }
                Button {
                    remove(server)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("删除此服务器的本机配对(不影响服务端授权,可在服务端撤销)")
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(isActive ? (runtime.connected ? Color.green : Color.orange) : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
                Text(server.name)
                Text("\(server.endpoints.count) 个入口")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var stateText: String {
        switch runtime.state {
        case .connected: "已连接"
        case .connecting: "连接中…"
        case .disconnected: "未连接"
        }
    }

    // 粘贴配对码:落盘 → 立即连接;deviceId 在认证成功后由连接层补写
    private func pair() {
        do {
            let offer = try PairingOffer.decode(pairInput)
            var next = config ?? ClientConfig(v: 2, servers: [], active: nil)
            let name = pairName.trimmingCharacters(in: .whitespaces).isEmpty
                ? (offer.endpoints.first ?? "Runtime")
                : pairName.trimmingCharacters(in: .whitespaces)
            next.servers.removeAll { $0.name == name }
            let entry = ServerEntry(
                name: name, deviceId: "", token: offer.token,
                pub: offer.pub, endpoints: offer.endpoints)
            next.servers.append(entry)
            next.active = entry.deviceId
            next.save()
            config = next
            pairInput = ""
            pairName = ""
            pairError = nil
            runtime.connect(server: entry)
        } catch {
            pairError = "配对码无法解析:\(error.localizedDescription)"
        }
    }

    private func switchTo(_ server: ServerEntry) {
        guard var next = config else { return }
        next.active = server.deviceId
        next.save()
        config = next
        runtime.connect(server: server)
    }

    private func remove(_ server: ServerEntry) {
        guard var next = config else { return }
        next.servers.removeAll { $0.id == server.id }
        if next.active == server.deviceId { next.active = next.servers.first?.deviceId }
        next.save()
        config = next
        if let fallback = next.activeServer {
            runtime.connect(server: fallback)
        } else {
            runtime.disconnect()
        }
    }
}

// 当前服务器的入口地址管理
private struct EndpointsSection: View {
    @ObservedObject var runtime: RuntimeConnection
    @Binding var config: ClientConfig?
    @State private var newEndpoint = ""

    var body: some View {
        Section {
            if let server = config?.activeServer {
                ForEach(server.endpoints, id: \.self) { endpoint in
                    LabeledContent {
                        HStack(spacing: 6) {
                            if runtime.connectedEndpoint == endpoint {
                                Text("当前使用").font(.caption).foregroundStyle(.green)
                            }
                            Button {
                                remove(endpoint)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .disabled(server.endpoints.count <= 1)
                            .help(server.endpoints.count <= 1 ? "至少保留一个入口" : "删除入口")
                        }
                    } label: {
                        Text(endpoint).font(.callout.monospaced())
                    }
                }
                HStack {
                    TextField("添加入口,如 frp.example.com:7100", text: $newEndpoint)
                        .textFieldStyle(.roundedBorder)
                    Button("添加") { add() }
                        .disabled(newEndpoint.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } header: {
            Text("入口地址(\(config?.activeServer?.name ?? ""))")
        } footer: {
            Text("按从上到下顺序尝试,失败自动切换下一个;所有入口共用同一凭据。在家走局域网直连,出门前把 FRP 等公网映射地址加进来即可,无需再改配置。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func add() {
        let endpoint = newEndpoint.trimmingCharacters(in: .whitespaces)
        guard !endpoint.isEmpty else { return }
        mutate { server in
            if !server.endpoints.contains(endpoint) { server.endpoints.append(endpoint) }
        }
        newEndpoint = ""
    }

    private func remove(_ endpoint: String) {
        mutate { server in
            guard server.endpoints.count > 1 else { return }
            server.endpoints.removeAll { $0 == endpoint }
        }
    }

    private func mutate(_ change: (inout ServerEntry) -> Void) {
        guard var next = config, let active = next.activeServer,
              let idx = next.servers.firstIndex(where: { $0.id == active.id })
        else { return }
        change(&next.servers[idx])
        next.save()
        config = next
        runtime.connect(server: next.servers[idx])
    }
}

// 把当前连接的 Runtime 共享给其他设备(生成配对码 + 授权列表 + 撤销)
private struct ShareServerSection: View {
    @ObservedObject var runtime: RuntimeConnection
    @State private var devices: [Device] = []
    @State private var shareName = ""
    @State private var shareExtraEndpoint = ""
    @State private var generatedOffer: String?
    @State private var copied = false
    @State private var shareError: String?

    var body: some View {
        Section {
            if !runtime.connected {
                Text("未连接 Runtime,暂时无法生成配对码或管理授权。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    TextField("设备名称,如 MacBook Air", text: $shareName)
                        .textFieldStyle(.roundedBorder)
                    TextField("公网入口(可选)", text: $shareExtraEndpoint)
                        .textFieldStyle(.roundedBorder)
                    Button("生成配对码") { Task { await createShare() } }
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
                            copied = true
                        } label: {
                            Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                if let shareError {
                    Text(shareError).font(.caption).foregroundStyle(.red)
                }
                if !devices.isEmpty {
                    Text("已授权设备")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                ForEach(devices) { device in
                    LabeledContent(device.name) {
                        HStack(spacing: 8) {
                            Text(deviceStatus(device))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button {
                                Task { await revoke(device) }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                            .help("撤销授权并立即断开该设备")
                        }
                    }
                }
            }
        } header: {
            Text("共享此服务器")
        } footer: {
            Text("配对码是完整的访问凭据:含入口地址、随机 token 和加密公钥,任何拿到它的设备都能连接,请通过可信渠道传输。生成时会自动带上本机局域网地址;「公网入口」填 FRP 等映射地址,让设备在外网也能连。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: runtime.connected) { await reload() }
    }

    private func deviceStatus(_ device: Device) -> String {
        guard let lastSeen = device.lastSeenAt else { return "未使用" }
        return "最后使用 \(shortDate(lastSeen))"
    }

    private func reload() async {
        guard runtime.connected else { return }
        devices = (try? await runtime.rpc("device.list", as: [Device].self)) ?? []
    }

    private func createShare() async {
        shareError = nil
        copied = false
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
