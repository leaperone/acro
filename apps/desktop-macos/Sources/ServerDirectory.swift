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
        var config = try ClientConfig.loadForWrite()
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

    // 本机授权来自 ~/.acro/local-offer.txt。文件轮换后保留同一个 localId，
    // 让侧边栏、选中态和 attach 路由不会因为凭据更新而迁移。
    @discardableResult
    static func pairLocal(offerText: String, hub: RuntimeHub) throws -> ServerEntry {
        let offer = try PairingOffer.decode(
            offerText.trimmingCharacters(in: .whitespacesAndNewlines))
        var config = try ClientConfig.loadForWrite()
        let existing = config.servers.first(where: { $0.isLocal })
        if let existing,
           existing.token == offer.token,
           existing.pub == offer.pub,
           existing.endpoints == offer.endpoints {
            return existing
        }

        config.servers.removeAll { $0.isLocal }
        let entry = ServerEntry(
            localId: existing?.localId ?? UUID().uuidString,
            name: existing?.name ?? "本机",
            deviceId: "",
            token: offer.token,
            pub: offer.pub,
            endpoints: offer.endpoints)
        config.servers.append(entry)
        config.active = entry.id
        config.save()
        hub.reload()
        return entry
    }

    // 名称 + 连接方式一次事务保存:入口顺序即用户排序(连接时局域网优先、组内保序)
    static func update(
        _ serverId: String, name: String, endpoints: [String], hub: RuntimeHub
    ) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let cleaned = try endpoints.map { try validatePairingEndpoint(
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        ) }
        guard !trimmedName.isEmpty, !cleaned.isEmpty,
              var config = ClientConfig.load(),
              let index = config.servers.firstIndex(where: { $0.id == serverId })
        else { return }
        guard !config.servers.contains(where: { $0.name == trimmedName && $0.id != serverId })
        else { throw ServerDirectoryError.duplicateName(trimmedName) }
        config.servers[index].name = trimmedName
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
