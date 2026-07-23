// 多主机连接枢纽:每台已配对服务器一条常驻 E2EE 连接,全部同时在线。
// 模型对标 orca(MIT, Copyright (c) stablyai)的 multi-host:切换查看目标
// 不销毁其他主机的连接与会话,侧边栏各服务器实时显示各自内容。

import Combine
import Foundation
import SwiftUI

@MainActor
final class RuntimeHub: ObservableObject {
    struct Entry: Identifiable {
        let server: ServerEntry
        let connection: RuntimeConnection
        var id: String { server.id }
    }

    @Published private(set) var entries: [Entry] = []
    private var cancellables: [String: AnyCancellable] = [:]

    // 与磁盘配置对账:新增的服务器建连接,删除的断开,endpoints/凭据变了重连
    func reload() {
        let config = ClientConfig.load()
        if config == nil, FileManager.default.fileExists(atPath: ClientConfig.path) { return }
        let servers = config?.servers ?? []
        var next: [Entry] = []
        var seen = Set<String>()
        for server in servers {
            seen.insert(server.id)
            if let existing = entries.first(where: { $0.id == server.id }) {
                // 只有影响连接的字段(入口/凭据)变了才重连;
                // deviceId 补写、改名等元数据变化不打断在线连接
                let needsReconnect = existing.server.endpoints != server.endpoints
                    || existing.server.token != server.token
                    || existing.server.pub != server.pub
                if needsReconnect {
                    existing.connection.connect(server: server)
                }
                next.append(Entry(server: server, connection: existing.connection))
                continue
            }
            let connection = RuntimeConnection()
            connection.connect(server: server)
            // Hub 只负责服务器目录和低频连接状态。workspace/session/focus 等内容
            // 由各服务器视图直接观察自己的 connection,避免一台服务器的标题或焦点
            // 变化让全部服务器和设置页一起重绘。
            cancellables[server.id] = connection.$state
                .dropFirst()
                .removeDuplicates()
                .sink { [weak self] _ in
                    self?.objectWillChange.send()
                }
            next.append(Entry(server: server, connection: connection))
        }
        for stale in entries where !seen.contains(stale.id) {
            stale.connection.disconnect()
            cancellables.removeValue(forKey: stale.id)
        }
        entries = next
    }

    func connection(for serverId: String?) -> RuntimeConnection? {
        guard let serverId else { return nil }
        return entries.first { $0.id == serverId }?.connection
    }

    func server(for serverId: String?) -> ServerEntry? {
        guard let serverId else { return nil }
        return entries.first { $0.id == serverId }?.server
    }
}

// 把子连接的失效限制在单台服务器的视图子树,Hub 只发布目录和连接状态。
struct RuntimeConnectionScope<Content: View>: View {
    @ObservedObject private var connection: RuntimeConnection
    private let content: (RuntimeConnection) -> Content

    init(
        connection: RuntimeConnection,
        @ViewBuilder content: @escaping (RuntimeConnection) -> Content
    ) {
        _connection = ObservedObject(wrappedValue: connection)
        self.content = content
    }

    var body: some View {
        content(connection)
    }
}
