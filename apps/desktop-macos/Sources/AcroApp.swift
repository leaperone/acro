// Acro Desktop 入口:App、菜单命令与 attach 命令解析。
// 终端渲染由 libghostty 完成,surface command 跑 `acro attach <sessionId>`,
// 会话本体永远活在 Runtime 侧的 terminal daemon 里。

import AppKit
import SwiftUI

final class AcroAppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Self.handleKeyDown(event, firstResponder: event.window?.firstResponder)
        }
    }

    static func handleKeyDown(_ event: NSEvent, firstResponder: NSResponder?) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command,
              event.charactersIgnoringModifiers?.lowercased() == "w"
        else { return event }
        guard !event.isARepeat else { return nil }
        (firstResponder as? AcroTerminalNSView)?.closePaneFromShortcut()
        return nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}

struct WorkbenchActions {
    let newWorkspaceGroup: () -> Void
    let newWorkspace: () -> Void
    let newTerminal: () -> Void
    let showCommandPalette: () -> Void
    let splitRight: () -> Void
    let splitDown: () -> Void
    let focusPreviousPane: () -> Void
    let focusNextPane: () -> Void
    let closePane: () -> Void
    let toggleLeftSidebar: () -> Void
    let toggleInspector: () -> Void
    let previousSession: () -> Void
    let nextSession: () -> Void
    let selectSessionAtIndex: (Int) -> Void
    let focusTerminal: () -> Void
    let closeSession: () -> Void
    let canCreateTerminal: Bool
    let canSplitTerminal: Bool
    let canNavigatePanes: Bool
    let canClosePane: Bool
    let canNavigateSessions: Bool
    let canFocusTerminal: Bool
    let canCloseSession: Bool
    let sessionCount: Int
    let leftSidebarVisible: Bool
    let inspectorVisible: Bool
}

private struct WorkbenchActionsKey: FocusedValueKey {
    typealias Value = WorkbenchActions
}

extension FocusedValues {
    var workbenchActions: WorkbenchActions? {
        get { self[WorkbenchActionsKey.self] }
        set { self[WorkbenchActionsKey.self] = newValue }
    }
}

struct AcroWorkbenchCommands: Commands {
    @FocusedValue(\.workbenchActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建终端", systemImage: "terminal") {
                actions?.newTerminal()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(actions?.canCreateTerminal != true)

            Button("新建工作区", systemImage: "plus") {
                actions?.newWorkspace()
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("新建分组", systemImage: "folder.badge.plus") {
                actions?.newWorkspaceGroup()
            }
        }

        CommandMenu("工作台") {
            Button("命令面板", systemImage: "command") {
                actions?.showCommandPalette()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Divider()

            Button(actions?.leftSidebarVisible == true ? "隐藏左侧栏" : "显示左侧栏", systemImage: "sidebar.left") {
                actions?.toggleLeftSidebar()
            }
            .keyboardShortcut("b", modifiers: [.command, .option])

            Button(actions?.inspectorVisible == true ? "隐藏右侧栏" : "显示右侧栏", systemImage: "sidebar.right") {
                actions?.toggleInspector()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])

            Divider()

            Button("向右分屏", systemImage: "rectangle.split.2x1") {
                actions?.splitRight()
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(actions?.canSplitTerminal != true)

            Button("向下分屏", systemImage: "rectangle.split.1x2") {
                actions?.splitDown()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(actions?.canSplitTerminal != true)

            Button("上一个窗格", systemImage: "chevron.left") {
                actions?.focusPreviousPane()
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled(actions?.canNavigatePanes != true)

            Button("下一个窗格", systemImage: "chevron.right") {
                actions?.focusNextPane()
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(actions?.canNavigatePanes != true)

            Button("关闭窗格", systemImage: "rectangle.split.2x1") {
                actions?.closePane()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(actions?.canClosePane != true)

            Divider()

            Button("上一个终端", systemImage: "chevron.left") {
                actions?.previousSession()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(actions?.canNavigateSessions != true)

            Button("下一个终端", systemImage: "chevron.right") {
                actions?.nextSession()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(actions?.canNavigateSessions != true)

            Menu("切换终端", systemImage: "rectangle.stack") {
                ForEach(1...9, id: \.self) { number in
                    Button("终端 \(number)") {
                        actions?.selectSessionAtIndex(number - 1)
                    }
                    .keyboardShortcut(
                        KeyEquivalent(Character(String(number))),
                        modifiers: .command
                    )
                    .disabled((actions?.sessionCount ?? 0) < number)
                }
            }
            .disabled((actions?.sessionCount ?? 0) == 0)

            Button("聚焦终端", systemImage: "text.cursor") {
                actions?.focusTerminal()
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(actions?.canFocusTerminal != true)

            Button("关闭终端", systemImage: "xmark") {
                actions?.closeSession()
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(actions?.canCloseSession != true)
        }
    }
}

@main
struct AcroApp: App {
    @NSApplicationDelegateAdaptor(AcroAppDelegate.self) private var appDelegate
    @StateObject private var runtime: RuntimeConnection
    @StateObject private var model: WorkbenchModel

    init() {
        let runtime = RuntimeConnection()
        _runtime = StateObject(wrappedValue: runtime)
        _model = StateObject(wrappedValue: WorkbenchModel(runtime: runtime))
    }

    var body: some Scene {
        WindowGroup("Acro") {
            WorkbenchView(model: model, runtime: runtime)
                .onAppear {
                    _ = Ghostty.shared // 初始化 libghostty
                    if let config = ClientConfig.load() {
                        runtime.connect(config: config)
                    }
                }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            AcroWorkbenchCommands()
        }
    }
}

// 解析 attach 命令:node + acro CLI 的绝对路径(GUI 进程没有用户 PATH)
enum AttachCommand {
    static func resolve(sessionId: String) -> String {
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
        let cli = env["ACRO_CLI_PATH"]
            ?? runtimeCliPath(from: runtimeArguments)
            ?? "\(NSHomeDirectory())/project/acro/apps/cli/src/cli.ts"
        return [node, cli, "attach", sessionId].map(shellQuote).joined(separator: " ")
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
