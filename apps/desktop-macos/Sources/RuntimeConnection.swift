// Runtime WS 连接:JSON RPC + 二进制帧。
// 类型与 packages/protocol 的 zod schema 对应;正式 codegen 之前只解 JSON 字典,
// 不手工镜像完整类型(工程规则:禁止手工镜像,codegen 落地前保持动态解析)。

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
    @Published var connected = false
    @Published var projects: [[String: Any]] = []
    @Published var workspaces: [[String: Any]] = []
    @Published var sessions: [[String: Any]] = []
    @Published var snapshotLoaded = false

    private var task: URLSessionWebSocketTask?
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]
    var onTerminalFrame: ((UInt32, UInt32, Data) -> Void)?

    func connect(config: ClientConfig) {
        guard let url = URL(string: "ws://\(config.host)/ws?token=\(config.token)") else { return }
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        snapshotLoaded = false
        task.resume()
        connected = true
        receiveLoop()
        Task { await refresh() }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case .failure:
                    self.connected = false
                case .success(let message):
                    self.handle(message)
                    self.receiveLoop()
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

    func refresh() async {
        if let list = try? await rpc("project.list") as? [[String: Any]] {
            projects = list
        }
        if let list = try? await rpc("workspace.list") as? [[String: Any]] {
            workspaces = list
        }
        if let list = try? await rpc("session.list") as? [[String: Any]] {
            sessions = list
        }
        snapshotLoaded = true
    }
}
