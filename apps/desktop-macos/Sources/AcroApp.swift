// Acro Desktop 入口:App、菜单命令与 attach 命令解析。
// 终端渲染由 libghostty 完成,surface command 跑 `acro attach <sessionId>`,
// 会话本体永远活在 Runtime 侧的 terminal daemon 里。
// 快捷键统一走 ShortcutSettings(cmux 范式):菜单、终端拦截、提示共用一份定义。

import AppKit
import SwiftUI

extension Notification.Name {
    // 全部应用快捷键与菜单点击统一走这两条通知,由 WorkbenchModel 执行。
    // (cmux 的 AppDelegate 快捷键路由模式;SwiftUI Commands 的 FocusedValue /
    // @ObservedObject 在本应用形态下都不可靠,菜单只做哑触发器。)
    static let acroShortcutAction = Notification.Name("acro.shortcut.action")
    static let acroSelectWorkspace = Notification.Name("acro.shortcut.selectWorkspace")
}

func postShortcut(_ action: ShortcutAction) {
    NotificationCenter.default.post(
        name: .acroShortcutAction, object: nil, userInfo: ["action": action.rawValue]
    )
}

final class AcroAppDelegate: NSObject, NSApplicationDelegate {
    static let settingsWindowTitle = "Acro 设置"
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // 在菜单分发之前拦截应用快捷键并路由到 model:
        // 系统 Close(⌘W)、终端按键竞争、菜单状态冻结全部绕开。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !event.isARepeat else { return event }
            // 设置窗口保持系统语义(⌘W 关窗等)
            if event.window?.title == Self.settingsWindowTitle { return event }
            if let digit = ShortcutSettings.workspaceDigit(event) {
                NotificationCenter.default.post(
                    name: .acroSelectWorkspace, object: nil, userInfo: ["index": digit - 1]
                )
                return nil
            }
            if let action = ShortcutSettings.action(for: event) {
                postShortcut(action)
                return nil
            }
            return event
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}

// 菜单项 = 哑触发器:点击发通知;快捷键显示仅作提示(实际触发在 keyMonitor)。
struct AcroWorkbenchCommands: Commands {
    private func item(
        _ title: String,
        _ symbol: String,
        _ action: ShortcutAction
    ) -> some View {
        Button(title, systemImage: symbol) {
            postShortcut(action)
        }
        .keyboardShortcut(ShortcutSettings.keyboardShortcut(action))
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            item("新建标签", "terminal", .newTerminalTab)
            item("新建工作区", "plus", .newWorkspace)
            item("新建分组", "folder.badge.plus", .newWorkspaceGroup)
        }

        CommandMenu("工作台") {
            item("设置…", "gearshape", .openSettings)
            item("命令面板", "command", .commandPalette)
            Button("检查更新…", systemImage: "arrow.down.circle") {
                UpdaterController.shared.checkForUpdates()
            }

            Divider()

            item("切换左侧栏", "sidebar.left", .toggleSidebar)
            item("切换右侧栏", "sidebar.right", .toggleInspector)

            Divider()

            item("向右分屏", "rectangle.split.2x1", .splitRight)
            item("向下分屏", "rectangle.split.1x2", .splitDown)
            item("均分窗格", "rectangle.split.3x1", .equalizeSplits)
            item("聚焦左侧窗格", "arrow.left.square", .focusPaneLeft)
            item("聚焦下方窗格", "arrow.down.square", .focusPaneDown)
            item("聚焦上方窗格", "arrow.up.square", .focusPaneUp)
            item("聚焦右侧窗格", "arrow.right.square", .focusPaneRight)

            Divider()

            item("上一个标签", "chevron.left", .previousTab)
            item("下一个标签", "chevron.right", .nextTab)
            item("关闭标签", "xmark.rectangle", .closeTab)

            Divider()

            Menu("切换工作区", systemImage: "square.stack.3d.up") {
                ForEach(1...9, id: \.self) { number in
                    Button("工作区 \(number)") {
                        NotificationCenter.default.post(
                            name: .acroSelectWorkspace,
                            object: nil,
                            userInfo: ["index": number - 1]
                        )
                    }
                    .keyboardShortcut(
                        KeyEquivalent(Character(String(number))),
                        modifiers: .command
                    )
                }
            }

            item("聚焦终端", "text.cursor", .focusTerminal)
        }
    }
}

@main
struct AcroApp: App {
    @NSApplicationDelegateAdaptor(AcroAppDelegate.self) private var appDelegate
    @StateObject private var hub: RuntimeHub
    @StateObject private var model: WorkbenchModel
    private let localRuntime = LocalRuntimeManager()

    init() {
        let hub = RuntimeHub()
        _hub = StateObject(wrappedValue: hub)
        _model = StateObject(wrappedValue: WorkbenchModel(hub: hub))
    }

    var body: some Scene {
        WindowGroup("Acro") {
            WorkbenchView(model: model, runtime: model.runtime)
                .onAppear {
                    _ = Ghostty.shared // 初始化 libghostty
                    hub.reload() // 为每台已配对服务器建立常驻连接
                }
                .task {
                    // 本地优先:确保本机 runtime 在跑并已静默配对
                    await localRuntime.ensureLocalRuntime(hub: hub)
                }
        }
        // 紧凑模式(cmux compact):无标题栏,内容顶到窗口顶部,tab 条即顶行
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands {
            AcroWorkbenchCommands()
        }

        // ⌘, 设置窗口(cmux Settings 窗口的 acro 版)。
        // 裸可执行(无 bundle)下 SwiftUI Settings scene 不注册菜单项,用显式 Window。
        Window("Acro 设置", id: "settings") {
            SettingsView(hub: hub, model: model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commandsRemoved()
    }
}


// 解析 attach 命令:node + acro CLI 的绝对路径(GUI 进程没有用户 PATH)
enum AttachCommand {
    static func resolve(sessionId: String, serverId: String?) -> String {
        let env = ProcessInfo.processInfo.environment
        let runtimeArguments = runtimeProgramArguments()
        let node = [
            env["ACRO_NODE"],
            runtimeArguments?.first,
            "/opt/homebrew/bin/node",
            "/opt/homebrew/opt/node@22/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ]
        .compactMap { $0 }
        .first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "node"
        // 优先级:显式 env → app bundle 内置(打包分发) → runtime 同仓(开发机) → 开发默认
        let bundledCli = Bundle.main.resourcePath.map { "\($0)/cli.cjs" }
        let cli = env["ACRO_CLI_PATH"]
            ?? bundledCli.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            ?? runtimeCliPath(from: runtimeArguments)
            ?? "\(NSHomeDirectory())/project/acro/apps/cli/src/cli.ts"
        var arguments = [node, cli, "attach", sessionId]
        // 多主机:attach 指定目标服务器,不依赖 client.json 的默认项
        if let serverId, !serverId.isEmpty {
            arguments += ["--server", serverId]
        }
        return arguments.map(shellQuote).joined(separator: " ")
    }

    private static func runtimeProgramArguments() -> [String]? {
        let path = "\(NSHomeDirectory())/Library/LaunchAgents/one.leaper.acro.runtime.plist"
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any],
              let arguments = dictionary["ProgramArguments"] as? [String]
        else { return nil }
        return arguments
    }

    private static func runtimeCliPath(from arguments: [String]?) -> String? {
        guard let runtimeScript = arguments?.dropFirst().first else { return nil }
        var root = URL(fileURLWithPath: runtimeScript)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("apps/cli/src/cli.ts").path
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
