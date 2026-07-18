// 服务器目录操作:侧边栏与设置页共用。
// 全部"重读磁盘 → 变更 → 保存 → hub.reload":配置由设置页、侧边栏、CLI、
// 连接层多方写入,任何 @State 快照直接 save 都会静默覆盖别处的修改。

import Foundation

enum ServerDirectoryError: LocalizedError {
    case duplicateName(String)

    var errorDescription: String? {
        switch self {
        case .duplicateName(let name):
            "名称「\(name)」已存在;换一个名称,或先删除旧服务器。"
        }
    }
}

@MainActor
enum ServerDirectory {
    // 粘贴配对码接入一台服务器;deviceId 认证后由连接层补写
    @discardableResult
    static func pair(offerText: String, name: String?, hub: RuntimeHub) throws -> ServerEntry {
        let offer = try PairingOffer.decode(
            offerText.trimmingCharacters(in: .whitespacesAndNewlines))
        var config = ClientConfig.load() ?? ClientConfig(v: 2, servers: [], active: nil)
        let trimmed = name?.trimmingCharacters(in: .whitespaces) ?? ""
        let finalName = trimmed.isEmpty ? (offer.endpoints.first ?? "Runtime") : trimmed
        // 名称重复直接拒绝,避免静默覆盖另一台服务器的凭据
        guard !config.servers.contains(where: { $0.name == finalName }) else {
            throw ServerDirectoryError.duplicateName(finalName)
        }
        let entry = ServerEntry(
            name: finalName, deviceId: "", token: offer.token,
            pub: offer.pub, endpoints: offer.endpoints)
        config.servers.append(entry)
        config.active = entry.id
        config.save()
        hub.reload()
        return entry
    }

    static func rename(_ serverId: String, to name: String, hub: RuntimeHub) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              var config = ClientConfig.load(),
              let index = config.servers.firstIndex(where: { $0.id == serverId }),
              !config.servers.contains(where: { $0.name == trimmed && $0.id != serverId })
        else { return }
        config.servers[index].name = trimmed
        config.save()
        hub.reload()
    }

    // 连接方式列表整体覆盖:顺序即用户排序(连接时仍按局域网优先分组内保序)
    static func setEndpoints(_ serverId: String, endpoints: [String], hub: RuntimeHub) {
        let cleaned = endpoints
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty,
              var config = ClientConfig.load(),
              let index = config.servers.firstIndex(where: { $0.id == serverId })
        else { return }
        config.servers[index].endpoints = cleaned
        config.save()
        hub.reload() // 入口变了,该服务器按新列表重连
    }

    static func remove(_ serverId: String, hub: RuntimeHub) {
        guard var config = ClientConfig.load() else { return }
        config.servers.removeAll { $0.id == serverId }
        if config.active == serverId { config.active = config.servers.first?.id }
        config.save()
        hub.reload()
    }
}
