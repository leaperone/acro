// libghostty 运行时单例。集成方式取自 muxy(MIT, Copyright (c) 2026 Muxy)。
// ponytail: 剪贴板读取与 IME 预编辑暂未接,粘贴走终端 bracketed paste 之外的路径时再补。

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
        ghostty_config_finalize(cfg)

        var rt = ghostty_runtime_config_s()
        rt.userdata = nil
        rt.supports_selection_clipboard = false
        rt.wakeup_cb = { _ in
            Task { @MainActor in Ghostty.shared.tick() }
        }
        rt.action_cb = { _, _, _ in false }
        rt.read_clipboard_cb = { _, _, _ in false }
        rt.confirm_read_clipboard_cb = { _, _, _, _ in }
        rt.write_clipboard_cb = { _, _, _, _, _ in }
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
