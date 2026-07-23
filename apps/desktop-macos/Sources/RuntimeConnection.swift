// Runtime WS 连接:E2EE 信道内 JSON RPC + 二进制帧 + 自动重连。
// 模型类型来自 Generated/ProtocolModels.swift(codegen,真源是 packages/protocol 的 zod)。
// 重连策略取自 orca(MIT, Copyright (c) stablyai)web-runtime-client:
// 指数退避 + 探针式心跳——只有"已发探针未获应答"才判死,避免误杀慢网络。
// 多入口:同一 token 依次尝试 endpoints(在家 LAN 直连,出门 FRP 公网),失败轮换下一个。

import Foundation

struct RpcError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct ClientConfigError: Error, LocalizedError {
    let path: String
    var errorDescription: String? { "客户端配置已损坏或不可读,请先修复或备份 \(path)" }
}

// 入口按可达路径分两类:局域网直连(私网地址)与公网入口(FRP 等映射的域名/公网 IP)。
// 分类由地址推断,不改协议;连接时局域网永远优先,公网只做回退。
enum EndpointKind {
    case lan
    case publicNet

    static func classify(_ endpoint: String) -> EndpointKind {
        let host = endpoint.split(separator: ":").first.map(String.init) ?? endpoint
        if host == "localhost" || host.hasPrefix("127.") || host.hasSuffix(".local") { return .lan }
        if host.hasPrefix("192.168.") || host.hasPrefix("10.") { return .lan }
        // 172.16.0.0/12
        let parts = host.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ Int($0) != nil }),
           parts[0] == "172", let second = Int(parts[1]), (16...31).contains(second) {
            return .lan
        }
        return .publicNet
    }
}

// 一个远程 Runtime = 一个 token + 多个入口。与 acro CLI 共用 ~/.acro/client.json。
// id 用配对时生成的 localId,永不变化——deviceId 在首次认证后才由服务端补写,
// 若用它当 id 会在认证瞬间迁移,拖垮 hub 缓存、选中态和 attach 路由的一致性。
struct ServerEntry: Codable, Identifiable, Equatable {
    var localId: String
    var name: String
    var deviceId: String
    var token: String
    var pub: String
    var endpoints: [String]
    var id: String { localId }

    init(
        localId: String = UUID().uuidString,
        name: String,
        deviceId: String,
        token: String,
        pub: String,
        endpoints: [String]
    ) {
        self.localId = localId
        self.name = name
        self.deviceId = deviceId
        self.token = token
        self.pub = pub
        self.endpoints = endpoints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        token = try container.decode(String.self, forKey: .token)
        pub = try container.decode(String.self, forKey: .pub)
        endpoints = try container.decode([String].self, forKey: .endpoints)
        // 旧配置无 localId:按当时的 id 语义兜底,下次保存后固定
        localId = try container.decodeIfPresent(String.self, forKey: .localId)
            ?? (deviceId.isEmpty ? name : deviceId)
    }

    // 本机条目 = 入口含回环地址。bootstrap 配对码(只在本机可读)总是带 127.0.0.1;
    // 远程 share 配对码只带 LAN/公网入口(share.ts),不会误判
    var isLocal: Bool {
        endpoints.contains { endpoint in
            let host = endpoint.split(separator: ":").first.map(String.init) ?? endpoint
            return host == "127.0.0.1" || host == "localhost" || host == "::1"
        }
    }

    var lanEndpoints: [String] { endpoints.filter { EndpointKind.classify($0) == .lan } }
    var publicEndpoints: [String] { endpoints.filter { EndpointKind.classify($0) == .publicNet } }
    // 连接尝试顺序:局域网直连优先,全部失败再落到公网入口
    var orderedEndpoints: [String] { lanEndpoints + publicEndpoints }
}

struct ClientConfig: Codable {
    var v: Int
    var servers: [ServerEntry]
    var active: String?

    static var path: String {
        ProcessInfo.processInfo.environment["ACRO_CLIENT_CONFIG"]
            ?? "\(NSHomeDirectory())/.acro/client.json"
    }

    static func load() -> ClientConfig? {
        guard let data = FileManager.default.contents(atPath: path),
              let config = try? JSONDecoder().decode(ClientConfig.self, from: data),
              config.v == 2
        else { return nil }
        return config
    }

    static func loadForWrite() throws -> ClientConfig {
        let files = FileManager.default
        guard files.fileExists(atPath: path) else {
            return ClientConfig(v: 2, servers: [], active: nil)
        }
        guard let data = files.contents(atPath: path) else { throw ClientConfigError(path: path) }
        guard let config = try? JSONDecoder().decode(ClientConfig.self, from: data), config.v == 2
        else { throw ClientConfigError(path: path) }
        return config
    }

    func save() {
        let dir = (Self.path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: dir)
        } catch {
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: URL(fileURLWithPath: Self.path), options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: Self.path)
        }
    }

    // active 存 ServerEntry.id(未认证时是 name,认证后是 deviceId),
    // 统一走 id 匹配,避免多个未认证条目的空 deviceId 相互混淆
    var activeServer: ServerEntry? {
        servers.first { $0.id == active } ?? servers.first
    }
}

@MainActor
final class RuntimeConnection: ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
    }

    struct RefreshSnapshot {
        let workspaceGroups: [WorkspaceGroup]
        let workspaces: [Workspace]
        let sessions: [Session]
        let focus: [SessionFocus]
    }

    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var workspaceGroups: [WorkspaceGroup] = []
    @Published private(set) var workspaces: [Workspace] = []
    @Published private(set) var sessions: [Session] = []
    // 终端占用:sessionId -> 占用设备(含自己;是否显示蒙版由调用方比对 deviceId)
    @Published private(set) var focusOwners: [String: SessionFocus] = [:]
    @Published private(set) var snapshotLoaded = false
    @Published private(set) var snapshotRevision = 0
    @Published private(set) var reconnectAttempt = 0
    // 当前实际连上的入口(设置页展示用)
    @Published private(set) var connectedEndpoint: String?

    // 本连接的设备身份(authed 后可用;用于占用锁的"是不是我"判定)
    var deviceId: String { server?.deviceId ?? "" }

    var connected: Bool { state == .connected }

    private var server: ServerEntry?
    private var task: URLSessionWebSocketTask?
    private var session: E2eeSession?
    private var handshake: E2eeClientHandshake?
    private var endpointIndex = 0
    private var generation = 0
    private var nextId = 1
    private struct PendingRpc {
        let continuation: CheckedContinuation<Any, Error>
        let timeoutTask: Task<Void, Never>
    }

    private struct RefreshJob {
        let id: Int
        let generation: Int
        let task: Task<Bool, Never>
    }

    private enum InitialRefreshResult {
        case complete
        case retry(after: TimeInterval)
    }

    private var pending: [Int: PendingRpc] = [:]
    private let refreshSnapshotProvider: (@MainActor () async throws -> RefreshSnapshot)?
    private var currentRefreshJob: RefreshJob?
    private var nextRefreshJob: RefreshJob?
    private var nextRefreshJobId = 0
    private var probeTimer: Timer?
    private var probeOutstanding = false
    private var reconnectTask: Task<Void, Never>?
    private var initialRefreshTask: Task<Void, Never>?
    private let initialRefreshDelays: [TimeInterval]
    var onTerminalFrame: ((UInt32, UInt32, Data) -> Void)?

    // orca RECONNECT_DELAYS_MS 的等价物,尾项为稳态重试间隔
    private static let reconnectDelays: [TimeInterval] = [0.5, 1, 2, 3, 5, 8]

    init(
        refreshSnapshotProvider: (@MainActor () async throws -> RefreshSnapshot)? = nil,
        initialRefreshDelays: [TimeInterval]? = nil
    ) {
        self.refreshSnapshotProvider = refreshSnapshotProvider
        self.initialRefreshDelays = initialRefreshDelays ?? Self.reconnectDelays
    }

    func connect(server: ServerEntry) {
        cancelInitialRefresh()
        cancelRefreshJobs()
        reconnectTask?.cancel()
        reconnectTask = nil
        generation += 1
        failPending(RpcError(message: "reconnecting"))
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session = nil
        handshake = nil
        state = .disconnected
        connectedEndpoint = nil
        probeTimer?.invalidate()
        probeTimer = nil
        probeOutstanding = false
        self.server = server
        endpointIndex = 0
        reconnectAttempt = 0
        openSocket()
    }

    func disconnect() {
        cancelInitialRefresh()
        reconnectTask?.cancel()
        reconnectTask = nil
        server = nil
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session = nil
        handshake = nil
        state = .disconnected
        reconnectAttempt = 0
        connectedEndpoint = nil
        probeTimer?.invalidate()
        probeTimer = nil
        probeOutstanding = false
        cancelRefreshJobs()
        failPending(RpcError(message: "disconnected"))
    }

    private func openSocket() {
        guard let server, !server.endpoints.isEmpty else { return }
        let ordered = server.orderedEndpoints
        let endpoint = ordered[endpointIndex % ordered.count]
        guard let url = pairingWebSocketURL(endpoint: endpoint, token: server.token),
              let handshake = try? E2eeClientHandshake(expectedServerPubB64: server.pub)
        else { return }
        generation += 1
        let generation = generation
        failPending(RpcError(message: "reconnecting"))
        task?.cancel(with: .goingAway, reason: nil)
        session = nil
        self.handshake = handshake

        state = .connecting
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        // 明文 hello 开启握手;之后的一切都在加密信道内
        task.send(.string(handshake.helloJSON())) { [weak self] error in
            if error != nil {
                Task { @MainActor in self?.handleDisconnect(generation: generation) }
            }
        }
        receiveLoop(generation: generation)
        startProbe(generation: generation)
    }

    // ---- 断线检测与重连 ----

    private func startProbe(generation: Int) {
        probeTimer?.invalidate()
        probeOutstanding = false
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.probeTick(generation: generation) }
        }
        RunLoop.main.add(timer, forMode: .common)
        probeTimer = timer
    }

    private func probeTick(generation: Int) {
        guard self.generation == generation, let task else { return }
        if probeOutstanding {
            // 上一发 ping 未在整个间隔内得到 pong:半开连接,主动断开重连
            task.cancel(with: .abnormalClosure, reason: nil)
            handleDisconnect(generation: generation)
            return
        }
        probeOutstanding = true
        task.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                if error == nil { self.probeOutstanding = false }
            }
        }
    }

    private func handleDisconnect(generation: Int) {
        guard self.generation == generation, state != .disconnected else { return }
        cancelInitialRefresh()
        cancelRefreshJobs()
        self.generation += 1
        state = .disconnected
        connectedEndpoint = nil
        session = nil
        handshake = nil
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        probeTimer?.invalidate()
        probeTimer = nil
        probeOutstanding = false
        failPending(RpcError(message: "disconnected"))
        // 换下一个入口再试(LAN 不通就轮到公网入口)
        endpointIndex += 1
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard server != nil, reconnectTask == nil else { return }
        let delay = Self.reconnectDelays[min(reconnectAttempt, Self.reconnectDelays.count - 1)]
        reconnectAttempt += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.reconnectTask = nil
            guard self.server != nil, self.state != .connected else { return }
            self.openSocket()
        }
    }

    private func failPending(_ error: Error) {
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func completePending(_ id: Int, _ result: Result<Any, Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask.cancel()
        switch result {
        case .success(let value): request.continuation.resume(returning: value)
        case .failure(let error): request.continuation.resume(throwing: error)
        }
    }

    // ---- 收发 ----

    private func receiveLoop(generation: Int) {
        task?.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                guard self.generation == generation else { return }
                switch result {
                case .failure:
                    self.handleDisconnect(generation: generation)
                case .success(let message):
                    self.handle(message, generation: generation)
                    self.receiveLoop(generation: generation)
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message, generation: Int) {
        switch message {
        case .string(let text):
            // 唯一合法的明文消息:握手 ready
            guard session == nil, let handshake, let server,
                  let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  obj["t"] as? String == "ready", let pub = obj["pub"] as? String,
                  let eph = obj["eph"] as? String,
                  let newSession = try? handshake.onReady(pubB64: pub, ephB64: eph),
                  let auth = try? newSession.sealText(#"{"t":"auth","token":"\#(server.token)"}"#)
            else {
                task?.cancel(with: .policyViolation, reason: nil)
                handleDisconnect(generation: generation)
                return
            }
            session = newSession
            task?.send(.data(auth)) { [weak self] error in
                if error != nil {
                    Task { @MainActor in self?.handleDisconnect(generation: generation) }
                }
            }
        case .data(let data):
            guard let session, let opened = try? session.open(data) else {
                // 解密失败说明信道状态不同步,断开走重连
                task?.cancel(with: .policyViolation, reason: nil)
                handleDisconnect(generation: generation)
                return
            }
            switch opened {
            case .text(let text):
                handleControl(text)
            case .binary(let frame):
                // FRAME_OUT = 0x01: u8 type | u32 channel | u32 seq | payload
                guard frame.count >= 9, frame[frame.startIndex] == 0x01 else { return }
                let channel = frame.subdata(in: 1..<5).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                let seq = frame.subdata(in: 5..<9).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                onTerminalFrame?(channel, seq, frame.subdata(in: 9..<frame.count))
            }
        @unknown default:
            break
        }
    }

    private func handleControl(_ text: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return }
        switch obj["t"] as? String {
        case "authed":
            // 认证完成:补写 deviceId(首次配对)。按 token 定位条目(token 每授权唯一,
            // 名称可改);active 只在缺省时设置,不抢已有默认
            if var server, let deviceId = obj["deviceId"] as? String, server.deviceId != deviceId {
                if var config = ClientConfig.load(),
                   let idx = config.servers.firstIndex(where: { $0.token == server.token }) {
                    config.servers[idx].deviceId = deviceId
                    if config.active == nil { config.active = config.servers[idx].id }
                    config.save()
                }
                server.deviceId = deviceId
                self.server = server
            }
            connectedEndpoint = server.map { $0.orderedEndpoints[endpointIndex % $0.orderedEndpoints.count] }
            startInitialRefresh()
        case "res":
            guard let id = obj["id"] as? Int else { return }
            if obj["ok"] as? Bool == true {
                completePending(id, .success(obj["result"] ?? [:]))
            } else {
                let err = (obj["error"] as? [String: Any])?["message"] as? String ?? "rpc error"
                completePending(id, .failure(RpcError(message: err)))
            }
        case "evt":
            if currentRefreshJob == nil,
               let event = obj["event"] as? String,
               applyIncrementalEvent(event, payload: obj["payload"])
            {
                return
            }
            scheduleRefresh()
        default:
            break
        }
    }

    @discardableResult
    func applyIncrementalEvent(_ event: String, payload: Any?) -> Bool {
        guard event == "session.title",
              let payload = payload as? [String: Any],
              let sessionId = payload["sessionId"] as? String,
              let index = sessions.firstIndex(where: { $0.id == sessionId })
        else { return false }

        let title: String?
        switch payload["title"] {
        case let value as String:
            title = value
        case is NSNull:
            title = nil
        default:
            return false
        }

        let current = sessions[index]
        guard current.title != title else { return true }
        var updated = sessions
        updated[index] = Session(
            id: current.id,
            cwd: current.cwd,
            command: current.command,
            cols: current.cols,
            rows: current.rows,
            createdAt: current.createdAt,
            alive: current.alive,
            exitCode: current.exitCode,
            title: title,
            agent: current.agent
        )
        sessions = updated
        return true
    }

    func rpc(_ method: String, _ params: [String: Any] = [:]) async throws -> Any {
        guard let task, let session else { throw RpcError(message: "not connected") }
        let id = nextId
        nextId += 1
        let payload: [String: Any] = ["t": "req", "id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let sealed = try session.sealText(String(decoding: data, as: UTF8.self))
        return try await withCheckedThrowingContinuation { cont in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.completePending(id, .failure(RpcError(message: "rpc timeout: \(method)")))
            }
            pending[id] = PendingRpc(continuation: cont, timeoutTask: timeoutTask)
            Task {
                do {
                    try await task.send(.data(sealed))
                } catch {
                    completePending(id, .failure(error))
                }
            }
        }
    }

    // JSON 结果解码成 codegen 模型;协议由服务端 zod 校验,这里只做形状匹配
    func rpc<T: Decodable>(_ method: String, _ params: [String: Any] = [:], as type: T.Type) async throws -> T {
        let result = try await rpc(method, params)
        let data = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // 终端输入等二进制帧走加密信道
    func sendBinary(_ frame: Data) {
        guard let task, let session, let sealed = try? session.sealBinary(frame) else { return }
        task.send(.data(sealed)) { _ in }
    }

    @discardableResult
    func refresh() async -> Bool {
        await refresh(generation: generation)
    }

    func startInitialRefresh() {
        cancelInitialRefresh()
        let connectionGeneration = generation
        initialRefreshTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let result = await self?.runInitialRefreshAttempt(
                    generation: connectionGeneration,
                    attempt: attempt
                ) else { return }
                guard case .retry(let delay) = result else { return }
                attempt += 1
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func cancelInitialRefresh() {
        initialRefreshTask?.cancel()
        initialRefreshTask = nil
    }

    private func runInitialRefreshAttempt(
        generation: Int,
        attempt: Int
    ) async -> InitialRefreshResult {
        guard !Task.isCancelled,
              self.generation == generation,
              server != nil,
              state != .connected
        else { return .complete }
        if await refresh(generation: generation) { return .complete }
        guard !Task.isCancelled,
              self.generation == generation,
              server != nil,
              state != .connected
        else { return .complete }
        let delay = initialRefreshDelays.isEmpty
            ? 0.5
            : initialRefreshDelays[min(attempt, initialRefreshDelays.count - 1)]
        return .retry(after: delay)
    }

    private func cancelRefreshJobs() {
        currentRefreshJob?.task.cancel()
        nextRefreshJob?.task.cancel()
        currentRefreshJob = nil
        nextRefreshJob = nil
    }

    private func scheduleRefresh() {
        _ = enqueueRefresh(generation: generation)
    }

    private func refresh(generation: Int) async -> Bool {
        await enqueueRefresh(generation: generation).task.value
    }

    private func enqueueRefresh(generation: Int) -> RefreshJob {
        if let currentRefreshJob {
            if currentRefreshJob.generation != generation {
                cancelRefreshJobs()
                return enqueueRefresh(generation: generation)
            }
            if let nextRefreshJob { return nextRefreshJob }
            let job = makeRefreshJob(after: currentRefreshJob.task, generation: generation)
            nextRefreshJob = job
            return job
        }
        let job = makeRefreshJob(after: nil, generation: generation)
        currentRefreshJob = job
        return job
    }

    private func makeRefreshJob(
        after predecessor: Task<Bool, Never>?,
        generation: Int
    ) -> RefreshJob {
        nextRefreshJobId &+= 1
        let id = nextRefreshJobId
        let task = Task { [weak self] in
            if let predecessor { _ = await predecessor.value }
            guard !Task.isCancelled else { return false }
            guard let self else { return false }
            guard self.generation == generation else { return false }
            let result = await performRefresh(connectionGeneration: generation)
            completeRefreshJob(id: id)
            return result
        }
        return RefreshJob(id: id, generation: generation, task: task)
    }

    private func completeRefreshJob(id: Int) {
        guard currentRefreshJob?.id == id else { return }
        if let nextRefreshJob {
            currentRefreshJob = nextRefreshJob
            self.nextRefreshJob = nil
        } else {
            currentRefreshJob = nil
        }
    }

    private func performRefresh(connectionGeneration: Int) async -> Bool {
        do {
            let snapshot = try await loadRefreshSnapshot()
            guard connectionGeneration == generation else { return false }
            commitRefreshSnapshot(
                workspaceGroups: snapshot.workspaceGroups,
                workspaces: snapshot.workspaces,
                sessions: snapshot.sessions,
                focus: snapshot.focus
            )
            return true
        } catch {
            // 保留上一份完整快照;断线由 receiveLoop / probe 处理,恢复后会再刷新
            return false
        }
    }

    private func loadRefreshSnapshot() async throws -> RefreshSnapshot {
        if let refreshSnapshotProvider { return try await refreshSnapshotProvider() }
        let workspaceGroups = try await rpc("workspaceGroup.list", as: [WorkspaceGroup].self)
        let workspaces = try await rpc("workspace.list", as: [Workspace].self)
        let sessions = try await rpc("session.list", as: [Session].self)
        let focus = try await rpc("session.focusList", as: [SessionFocus].self)
        return RefreshSnapshot(
            workspaceGroups: workspaceGroups,
            workspaces: workspaces,
            sessions: sessions,
            focus: focus
        )
    }

    func commitRefreshSnapshot(
        workspaceGroups: [WorkspaceGroup],
        workspaces: [Workspace],
        sessions: [Session],
        focus: [SessionFocus]
    ) {
        self.workspaceGroups = workspaceGroups
        self.workspaces = workspaces
        self.sessions = sessions
        focusOwners = Dictionary(uniqueKeysWithValues: focus.map { ($0.sessionId, $0) })
        snapshotLoaded = true
        snapshotRevision &+= 1
        if state == .connecting {
            state = .connected
            reconnectAttempt = 0
            endpointIndex = 0
        }
    }
}
