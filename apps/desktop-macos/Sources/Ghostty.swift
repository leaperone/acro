// libghostty 运行时单例。集成与剪贴板回调取自 muxy
// (MIT, Copyright (c) 2026 Muxy)的简化版。

import AppKit
import GhosttyKit

@MainActor
final class Ghostty {
    static let shared = Ghostty()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?

    private init() {
        Self.setupResourcesDir()

        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            NSLog("ghostty_init failed")
            return
        }
        guard let cfg = ghostty_config_new() else {
            NSLog("ghostty_config_new failed")
            return
        }
        // 设置窗口写的外观配置(字体/主题);不存在则用 ghostty 默认
        if FileManager.default.fileExists(atPath: TerminalAppearance.confPath) {
            TerminalAppearance.confPath.withCString { ptr in
                ghostty_config_load_file(cfg, ptr)
            }
        }
        ghostty_config_finalize(cfg)

        var rt = ghostty_runtime_config_s()
        rt.userdata = nil
        rt.supports_selection_clipboard = true
        rt.wakeup_cb = { _ in
            Task { @MainActor in Ghostty.shared.tick() }
        }
        rt.action_cb = { _, _, _ in false }
        rt.read_clipboard_cb = { userdata, _, state in
            guard let userdata else { return false }
            let view = Unmanaged<AcroTerminalNSView>.fromOpaque(userdata).takeUnretainedValue()
            view.completeClipboardRequest(
                NSPasteboard.general.string(forType: .string) ?? "",
                state: state,
                confirmed: false
            )
            return true
        }
        rt.confirm_read_clipboard_cb = { userdata, content, state, _ in
            guard let userdata, let content else { return }
            let view = Unmanaged<AcroTerminalNSView>.fromOpaque(userdata).takeUnretainedValue()
            view.completeClipboardRequest(String(cString: content), state: state, confirmed: true)
        }
        rt.write_clipboard_cb = { _, _, content, count, _ in
            guard let content, count > 0 else { return }
            for item in UnsafeBufferPointer(start: content, count: Int(count)) {
                guard let mime = item.mime, String(cString: mime).hasPrefix("text/plain"),
                      let data = item.data
                else { continue }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(cString: data), forType: .string)
                return
            }
        }
        rt.close_surface_cb = { userdata, _ in
            guard let userdata else { return }
            let view = Unmanaged<AcroTerminalNSView>.fromOpaque(userdata).takeUnretainedValue()
            Task { @MainActor in view.surfaceDidRequestClose() }
        }

        guard let created = ghostty_app_new(&rt, cfg) else {
            NSLog("ghostty_app_new failed")
            ghostty_config_free(cfg)
            return
        }
        app = created
        config = cfg
    }

    func tick() {
        if let app { ghostty_app_tick(app) }
    }

    // 资源目录:env 覆盖 > 包目录(swift build 布局)
    private static func setupResourcesDir() {
        if ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] != nil { return }
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let candidates = [
            exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/ghostty"), // <pkg>/.build/debug/AcroDesktop → <pkg>/Resources/ghostty
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/ghostty"),
        ]
        for url in candidates
        where FileManager.default.fileExists(atPath: url.appendingPathComponent("shell-integration").path) {
            setenv("GHOSTTY_RESOURCES_DIR", url.path, 1)
            return
        }
        NSLog("ghostty resources not found; run scripts/setup-ghostty.sh")
    }
}
