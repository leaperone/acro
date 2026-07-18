// ⌘, 设置窗口:通用 / 远程 / 快捷键 / 外观。
// 结构与快捷键录制交互取自 cmux 的 Settings 窗口与 KeyboardShortcutRecorder
// (GPL-3.0-or-later, Copyright (c) 2024-present Manaflow, Inc.),按 acro 精简。
// 「远程」页对标 orca(MIT, Copyright (c) stablyai)的 Remote Orca Server 设置页。

import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var hub: RuntimeHub
    @ObservedObject var model: WorkbenchModel

    var body: some View {
        TabView {
            GeneralSettingsPane(hub: hub, model: model)
                .tabItem { Label("通用", systemImage: "gearshape") }
            RemoteSettingsPane(hub: hub)
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
    @ObservedObject var hub: RuntimeHub
    @ObservedObject var model: WorkbenchModel
    @AppStorage(WorkbenchModel.confirmCloseTabKey) private var confirmCloseTab = true

    var body: some View {
        Form {
            Section {
                LabeledContent("状态") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(connectedCount == hub.entries.count && !hub.entries.isEmpty
                                ? Color.green : (connectedCount > 0 ? Color.orange : Color.secondary))
                            .frame(width: 8, height: 8)
                        Text("\(connectedCount)/\(hub.entries.count) 台服务器已连接")
                    }
                }
                LabeledContent("当前查看", value: hub.server(for: model.selectedServerId)?.name ?? "-")
                LabeledContent("工作区 / 终端", value: "\(model.runtime.workspaces.count) / \(model.runtime.sessions.count { $0.alive })")
            } header: {
                Text("Runtime 连接")
            } footer: {
                Text("配对、入口和共享访问在「远程」标签页管理;所有已配对服务器会同时保持连接。")
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

            UpdateSection()

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

    private var connectedCount: Int {
        hub.entries.count { $0.connection.connected }
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

// ---- 更新(Sparkle) ----

private struct UpdateSection: View {
    @AppStorage(UpdaterController.channelKey) private var channel = "stable"
    @State private var autoCheck = UpdaterController.shared.automaticallyChecksForUpdates

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发构建"
    }

    var body: some View {
        Section {
            LabeledContent("当前版本") {
                HStack(spacing: 8) {
                    Text(version)
                    Button("检查更新…") { UpdaterController.shared.checkForUpdates() }
                        .disabled(!UpdaterController.shared.available)
                }
            }
            Picker("更新通道", selection: $channel) {
                Text("稳定").tag("stable")
                Text("测试").tag("beta")
            }
            .pickerStyle(.segmented)
            Toggle("自动检查更新", isOn: $autoCheck)
                .disabled(!UpdaterController.shared.available)
                .onChange(of: autoCheck) { _, value in
                    UpdaterController.shared.automaticallyChecksForUpdates = value
                }
        } header: {
            Text("更新")
        } footer: {
            Text(UpdaterController.shared.available
                ? "从 GitHub Releases 拉取新版本;安装只重启桌面 App,终端会话保存在 Runtime 中不受影响。「测试」通道会收到预发布版本。"
                : "开发构建(非打包 app)不支持自动更新。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// ---- 远程(对标 orca 的 Remote Orca Server 设置页) ----
// 三块职责:连接到远程服务器(配对/切换/删除)→ 入口地址(LAN + 公网)→ 共享此服务器(生成/撤销授权)。

private struct RemoteSettingsPane: View {
    @ObservedObject var hub: RuntimeHub
    @State private var config = ClientConfig.load()
    // 入口/共享区块管理的目标服务器(列表里点选)
    @State private var manageServerId: String?

    private var manageServer: ServerEntry? {
        config?.servers.first { $0.id == manageServerId } ?? config?.servers.first
    }

    var body: some View {
        Form {
            Section {
                Text("Runtime(如 Mac mini)持有仓库、终端会话和浏览器;这台设备只是它的一块屏幕。所有已配对服务器同时保持连接,侧边栏各自显示各自的工作区。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ConnectServersSection(hub: hub, config: $config, manageServerId: $manageServerId)

            if let manageServer {
                EndpointsSection(hub: hub, config: $config, serverId: manageServer.id)
                ShareServerSection(hub: hub, serverId: manageServer.id)
            }

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
        .task {
            config = ClientConfig.load()
        }
        .onReceive(hub.objectWillChange) { _ in
            // 认证补写 deviceId、配对/删除等都会经 hub 冒泡,保持显示与磁盘一致
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

// 已配对服务器列表 + 粘贴配对码添加。所有服务器常驻连接,点行选择下方区块的管理目标
private struct ConnectServersSection: View {
    @ObservedObject var hub: RuntimeHub
    @Binding var config: ClientConfig?
    @Binding var manageServerId: String?
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
            Text("远程服务器")
        } footer: {
            Text("配对码在远程 Mac 的 Acro「设置 → 远程 → 共享此服务器」里生成,包含地址、凭据和加密公钥,配对一次即可。所有服务器同时保持连接;点某一行可在下方管理它的入口与共享。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func serverRow(_ server: ServerEntry) -> some View {
        let connection = hub.connection(for: server.id)
        let isManaged = (manageServerId ?? config?.servers.first?.id) == server.id
        return Button {
            manageServerId = server.id
        } label: {
            LabeledContent {
                HStack(spacing: 8) {
                    Text(stateText(connection))
                        .font(.caption)
                        .foregroundStyle(connection?.connected == true ? .green : .orange)
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
                    Image(systemName: isManaged ? "checkmark.circle.fill" : "circle")
                        .font(.caption)
                        .foregroundStyle(isManaged ? Color.accentColor : .secondary)
                    Circle()
                        .fill(connection?.connected == true ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(server.name)
                    Text("\(server.endpoints.count) 个入口")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func stateText(_ connection: RuntimeConnection?) -> String {
        switch connection?.state {
        case .connected: "已连接"
        case .connecting: "连接中…"
        default: "未连接"
        }
    }

    // 统一走 ServerDirectory(与侧边栏共用一份"重读磁盘→变更→保存"逻辑)
    private func pair() {
        do {
            let entry = try ServerDirectory.pair(offerText: pairInput, name: pairName, hub: hub)
            config = ClientConfig.load()
            manageServerId = entry.id
            pairInput = ""
            pairName = ""
            pairError = nil
        } catch {
            pairError = error.localizedDescription
        }
    }

    private func remove(_ server: ServerEntry) {
        ServerDirectory.remove(server.id, hub: hub)
        config = ClientConfig.load()
        if manageServerId == server.id { manageServerId = config?.servers.first?.id }
    }
}

// 选中服务器的入口地址管理
private struct EndpointsSection: View {
    @ObservedObject var hub: RuntimeHub
    @Binding var config: ClientConfig?
    let serverId: String
    @State private var newLanEndpoint = ""
    @State private var newPublicEndpoint = ""

    private var server: ServerEntry? { config?.servers.first { $0.id == serverId } }
    private var connection: RuntimeConnection? { hub.connection(for: serverId) }

    var body: some View {
        Group {
            Section {
                LabeledContent("当前路径") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(pathColor)
                            .frame(width: 8, height: 8)
                        Text(pathText)
                    }
                }
            } header: {
                Text("连接方式(\(server?.name ?? ""))")
            } footer: {
                Text("连接永远先试局域网直连,几秒内不可达就自动切到公网入口;断线后重连,回到家又会自动切回局域网。两条路是同一凭据、同一批会话。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                endpointRows(server?.lanEndpoints ?? [])
                HStack {
                    TextField("局域网地址,如 192.168.1.10:8790", text: $newLanEndpoint)
                        .textFieldStyle(.roundedBorder)
                    Button("添加") { add($newLanEndpoint, expected: .lan, hint: "这不是局域网地址;公网地址请加在下面的「公网入口」。") }
                        .disabled(newLanEndpoint.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let addError, addErrorKind == .lan {
                    Text(addError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("局域网直连")
            } footer: {
                Text("与 Runtime 在同一网络时使用的私网地址,配对码会自动带上;网卡地址变了可在这里更新。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if server?.publicEndpoints.isEmpty ?? true {
                    Label("尚未配置公网入口——离开这个局域网后将无法连接。把 FRP 等映射地址加进来即可在外网使用。", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                endpointRows(server?.publicEndpoints ?? [])
                HStack {
                    TextField("公网地址,如 frp.example.com:7100", text: $newPublicEndpoint)
                        .textFieldStyle(.roundedBorder)
                    Button("添加") { add($newPublicEndpoint, expected: .publicNet, hint: "这是局域网地址;请加在上面的「局域网直连」。") }
                        .disabled(newPublicEndpoint.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let addError, addErrorKind == .publicNet {
                    Text(addError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("公网入口(FRP 等)")
            } footer: {
                Text("Runtime 通过 FRP 或其他代理映射到公网的地址。流量端到端加密,代理不需要配 TLS。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @State private var addError: String?
    @State private var addErrorKind: EndpointKind?

    private var pathText: String {
        switch connection?.state {
        case .connected:
            guard let endpoint = connection?.connectedEndpoint else { return "已连接" }
            let kind = EndpointKind.classify(endpoint) == .lan ? "局域网直连" : "公网入口"
            return "\(kind) · \(endpoint)"
        case .connecting:
            return "尝试中…(局域网优先,失败自动切公网)"
        default:
            return "未连接"
        }
    }

    private var pathColor: Color {
        switch connection?.state {
        case .connected: .green
        case .connecting: .orange
        default: .secondary.opacity(0.4)
        }
    }

    private func endpointRows(_ endpoints: [String]) -> some View {
        ForEach(endpoints, id: \.self) { endpoint in
            LabeledContent {
                HStack(spacing: 6) {
                    if connection?.connectedEndpoint == endpoint {
                        Text("当前使用").font(.caption).foregroundStyle(.green)
                    }
                    Button {
                        remove(endpoint)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled((server?.endpoints.count ?? 0) <= 1)
                    .help((server?.endpoints.count ?? 0) <= 1 ? "至少保留一个地址" : "删除地址")
                }
            } label: {
                Text(endpoint).font(.callout.monospaced())
            }
        }
    }

    // 校验地址类型放对了栏位:LAN 栏只收私网地址,公网栏只收域名/公网 IP
    private func add(_ field: Binding<String>, expected: EndpointKind, hint: String) {
        let endpoint = field.wrappedValue.trimmingCharacters(in: .whitespaces)
        guard !endpoint.isEmpty else { return }
        guard EndpointKind.classify(endpoint) == expected else {
            addError = hint
            addErrorKind = expected
            return
        }
        addError = nil
        addErrorKind = nil
        mutate { server in
            if !server.endpoints.contains(endpoint) { server.endpoints.append(endpoint) }
        }
        field.wrappedValue = ""
    }

    private func remove(_ endpoint: String) {
        mutate { server in
            guard server.endpoints.count > 1 else { return }
            server.endpoints.removeAll { $0 == endpoint }
        }
    }

    private func mutate(_ change: (inout ServerEntry) -> Void) {
        // 写入前重读磁盘,避免用过期快照覆盖连接层刚补写的 deviceId
        guard var next = ClientConfig.load(),
              let idx = next.servers.firstIndex(where: { $0.id == serverId })
        else { return }
        change(&next.servers[idx])
        next.save()
        config = next
        hub.reload() // 入口变了,该服务器按新列表重连
    }
}

// 把选中的 Runtime 共享给其他设备(生成配对码 + 授权列表 + 撤销)
private struct ShareServerSection: View {
    @ObservedObject var hub: RuntimeHub
    let serverId: String
    @State private var devices: [Device] = []

    private var connection: RuntimeConnection? { hub.connection(for: serverId) }
    private var connected: Bool { connection?.connected == true }
    @State private var shareName = ""
    @State private var shareExtraEndpoint = ""
    @State private var generatedOffer: String?
    @State private var copied = false
    @State private var shareError: String?

    var body: some View {
        Section {
            if !connected {
                Text("该服务器未连接,暂时无法生成配对码或管理授权。")
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
        .task(id: "\(serverId)-\(connected)") { await reload() }
    }

    private func deviceStatus(_ device: Device) -> String {
        guard let lastSeen = device.lastSeenAt else { return "未使用" }
        return "最后使用 \(shortDate(lastSeen))"
    }

    private func reload() async {
        guard let connection, connection.connected else {
            devices = []
            return
        }
        devices = (try? await connection.rpc("device.list", as: [Device].self)) ?? []
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
            guard let connection else { return }
            struct ShareResult: Decodable { let offer: String; let deviceId: String }
            let result = try await connection.rpc("device.share", params, as: ShareResult.self)
            generatedOffer = result.offer
            await reload()
        } catch {
            shareError = error.localizedDescription
        }
    }

    private func revoke(_ device: Device) async {
        shareError = nil
        do {
            guard let connection else { return }
            _ = try await connection.rpc("device.revoke", ["deviceId": device.id])
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
                    Text("⌃1-9 固定选择焦点窗格标签，⌘1-9 固定切换工作区；9 代表最后一个。菜单栏中的快捷键在重启应用后更新，其余立即生效。")
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
        if let reserved = ShortcutSettings.reservedNumberedShortcutDescription(shortcut) {
            feedback = reserved
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
