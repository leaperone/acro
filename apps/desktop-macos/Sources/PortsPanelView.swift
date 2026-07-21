// 右侧栏端口面板:Mac mini 上正在 LISTEN 的 TCP 端口 + 进程(只读)。
// 只读展示——不 kill 进程、不改端口。数据经 ports.list RPC 取。

import SwiftUI

@MainActor
final class PortsPanelModel: ObservableObject {
    @Published private(set) var listeners: [PortListener]?
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    private weak var runtime: RuntimeConnection?

    func loadIfNeeded(runtime: RuntimeConnection) {
        self.runtime = runtime
        if listeners == nil, !isLoading { reload() }
    }

    func reload() {
        guard let runtime else { return }
        isLoading = true
        loadError = nil
        Task {
            do {
                listeners = try await runtime.rpc("ports.list", as: [PortListener].self)
                isLoading = false
            } catch {
                loadError = (error as? RpcError)?.message ?? error.localizedDescription
                listeners = nil
                isLoading = false
            }
        }
    }
}

struct PortsPanelView: View {
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var runtime: RuntimeConnection
    @StateObject private var ports = PortsPanelModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text("监听端口").font(.caption.weight(.semibold))
                if let listeners = ports.listeners, !listeners.isEmpty {
                    Text("\(listeners.count)").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button { ports.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("刷新")
                    .accessibilityLabel("刷新端口")
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            Divider()
            content
        }
        .onAppear { ports.loadIfNeeded(runtime: runtime) }
    }

    @ViewBuilder
    private var content: some View {
        if ports.isLoading {
            centered { ProgressView().controlSize(.small) }
        } else if let error = ports.loadError {
            centered {
                VStack(spacing: 8) {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Button("重试") { ports.reload() }.controlSize(.small)
                }
            }
        } else if let listeners = ports.listeners {
            if listeners.isEmpty {
                centered { Text("没有监听中的端口").font(.caption).foregroundStyle(.secondary) }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(listeners.enumerated()), id: \.offset) { _, listener in
                            PortRow(listener: listener)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        } else {
            centered { Text("未连接").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func centered<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PortRow: View {
    let listener: PortListener

    var body: some View {
        HStack(spacing: 8) {
            Text("\(listener.port)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.accentColor)
                .frame(minWidth: 46, alignment: .leading)
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 1) {
                Text(listener.process)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text("\(listener.address) · pid \(listener.pid)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .contentShape(Rectangle())
        .help("\(listener.process) 监听 \(listener.address):\(listener.port)(pid \(listener.pid))")
    }
}
