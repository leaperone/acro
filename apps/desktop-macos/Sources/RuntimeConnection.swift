// Runtime WS 连接:JSON RPC + 二进制帧 + 自动重连。
// 模型类型来自 Generated/ProtocolModels.swift(codegen,真源是 packages/protocol 的 zod)。
// 重连策略取自 orca(MIT, Copyright (c) stablyai)web-runtime-client:
// 指数退避 + 探针式心跳——只有"已发探针未获应答"才判死,避免误杀慢网络。

import Foundation

struct RpcError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct ClientConfig: Codable {
    let host: String
    let token: String
    let deviceId: String

    // 与 acro CLI 共用 ~/.acro/client.json,CLI 配对后桌面端直接可用
    static func load() -> ClientConfig? {
        let path = ProcessInfo.processInfo.environment["ACRO_CLIENT_CONFIG"]
            ?? "\(NSHomeDirectory())/.acro/client.json"
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(ClientConfig.self, from: data)
    }
}

@MainActor
final class RuntimeConnection: ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
    }

    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var projects: [Project] = []
    @Published private(set) var workspaceGroups: [WorkspaceGroup] = []
    @Published private(set) var workspaces: [Workspace] = []
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var snapshotLoaded = false
    @Published private(set) var snapshotRevision = 0
    @Published private(set) var reconnectAttempt = 0

    var connected: Bool { state == .connected }

    private var config: ClientConfig?
    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]
    private var refreshGeneration = 0
    private var probeTimer: Timer?
    private var probeOutstanding = false
    private var reconnectScheduled = false
    var onTerminalFrame: ((UInt32, UInt32, Data) -> Void)?

    // orca RECONNECT_DELAYS_MS 的等价物,尾项为稳态重试间隔
    private static let reconnectDelays: [TimeInterval] = [0.5, 1, 2, 3, 5, 8]

    func connect(config: ClientConfig) {
        self.config = config
        reconnectAttempt = 0
        openSocket()
    }

    private func openSocket() {
        guard let config,
              let url = URL(string: "ws://\(config.host)/ws?token=\(config.token)")
        else { return }
        generation += 1
        let generation = generation
        failPending(RpcError(message: "reconnecting"))
        task?.cancel(with: .goingAway, reason: nil)

        state = .connecting
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveLoop(generation: generation)
        startProbe(generation: generation)
        Task {
            let ok = await refresh()
            guard self.generation == generation else { return }
            if ok {
                state = .connected
                reconnectAttempt = 0
            }
            // refresh 失败时 receiveLoop 会随 socket 错误触发重连,这里不重复调度
        }
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
        guard self.generation == generation else { return }
        state = .disconnected
        probeTimer?.invalidate()
        probeTimer = nil
        failPending(RpcError(message: "disconnected"))
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard config != nil, !reconnectScheduled else { return }
        reconnectScheduled = true
        let delay = Self.reconnectDelays[min(reconnectAttempt, Self.reconnectDelays.count - 1)]
        reconnectAttempt += 1
        Task {
            try? await Task.sleep(for: .seconds(delay))
            reconnectScheduled = false
            guard state != .connected else { return }
            openSocket()
        }
    }

    private func failPending(_ error: Error) {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
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
                    self.handle(message)
                    self.receiveLoop(generation: generation)
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            else { return }
            if obj["t"] as? String == "res", let id = obj["id"] as? Int {
                guard let cont = pending.removeValue(forKey: id) else { return }
                if obj["ok"] as? Bool == true {
                    cont.resume(returning: obj["result"] ?? [:])
                } else {
                    let err = (obj["error"] as? [String: Any])?["message"] as? String ?? "rpc error"
                    cont.resume(throwing: RpcError(message: err))
                }
            } else if obj["t"] as? String == "evt" {
                Task { await refresh() }
            }
        case .data(let data):
            // FRAME_OUT = 0x01: u8 type | u32 channel | u32 seq | payload
            guard data.count >= 9, data[data.startIndex] == 0x01 else { return }
            let channel = data.subdata(in: 1..<5).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let seq = data.subdata(in: 5..<9).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            onTerminalFrame?(channel, seq, data.subdata(in: 9..<data.count))
        @unknown default:
            break
        }
    }

    func rpc(_ method: String, _ params: [String: Any] = [:]) async throws -> Any {
        guard let task else { throw RpcError(message: "not connected") }
        let id = nextId
        nextId += 1
        let payload: [String: Any] = ["t": "req", "id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            Task {
                do {
                    try await task.send(.string(String(decoding: data, as: UTF8.self)))
                } catch {
                    pending.removeValue(forKey: id)?.resume(throwing: error)
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

    @discardableResult
    func refresh() async -> Bool {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        do {
            let nextProjects = try await rpc("project.list", as: [Project].self)
            let nextWorkspaceGroups = try await rpc("workspaceGroup.list", as: [WorkspaceGroup].self)
            let nextWorkspaces = try await rpc("workspace.list", as: [Workspace].self)
            let nextSessions = try await rpc("session.list", as: [Session].self)
            guard generation == refreshGeneration else { return false }
            projects = nextProjects
            workspaceGroups = nextWorkspaceGroups
            workspaces = nextWorkspaces
            sessions = nextSessions
            snapshotLoaded = true
            snapshotRevision &+= 1
            return true
        } catch {
            // 保留上一份完整快照;断线由 receiveLoop / probe 处理,恢复后会再刷新
            return false
        }
    }
}
