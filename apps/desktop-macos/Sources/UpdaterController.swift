// Sparkle 自动更新。方案与 cmux / ghostty 一致:Sparkle 2 + delegate 控制通道;
// 通道用 appcast 原生 sparkle:channel 区分(稳定条目无 channel,测试条目标 beta)。
// 更新只重启桌面 App;终端会话活在 runtime daemon 进程里,重启后自动重连,不会丢失。

import AppKit
import Sparkle

@MainActor
final class UpdaterController: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdaterController()
    static let channelKey = "acro.update.channel" // "stable" / "beta"

    private var controller: SPUStandardUpdaterController?
    var updater: SPUUpdater? { controller?.updater }

    // 只有打包后的 app(Info.plist 带 SUFeedURL)才启动更新器;swift build 裸跑开发时跳过
    private override init() {
        super.init()
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    var available: Bool { controller != nil }

    var automaticallyChecksForUpdates: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.string(forKey: Self.channelKey) == "beta" ? ["beta"] : []
    }
}
