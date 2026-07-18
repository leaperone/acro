// 侧边栏的服务器接入与编辑弹层。
// "把本机共享为服务器"(生成配对码)仍在设置 → 远程;这里只管连接与编辑。

import SwiftUI

// sheet(item:) 需要 Identifiable;服务器 id 就是字符串本身
struct EditingServerId: Identifiable, Equatable {
    let id: String
}

// 粘贴配对码接入服务器
struct ConnectServerSheet: View {
    let hub: RuntimeHub
    @Environment(\.dismiss) private var dismiss
    @State private var offerText = ""
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("连接服务器")
                .font(.headline)
            Text("在目标服务器的「设置 → 远程 → 共享」里生成配对码,粘贴到这里。")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("配对码(acro://pair?…)", text: $offerText, axis: .vertical)
                .lineLimit(3...5)
                .font(.caption.monospaced())
            TextField("名称(可选,默认用入口地址)", text: $name)
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("连接") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(offerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func connect() {
        do {
            _ = try ServerDirectory.pair(offerText: offerText, name: name, hub: hub)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// 编辑服务器:名称 + 连接方式列表(增删、上下排序)
struct EditServerSheet: View {
    let serverId: String
    let hub: RuntimeHub
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var endpoints: [String] = []
    @State private var newEndpoint = ""
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑服务器")
                .font(.headline)
            TextField("名称", text: $name)

            Text("连接方式(host:port,自动局域网优先;组内按此顺序尝试)")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(endpoints.enumerated()), id: \.offset) { index, endpoint in
                HStack(spacing: 6) {
                    Text(EndpointKind.classify(endpoint) == .lan ? "局域网" : "公网")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)
                    Text(endpoint)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        endpoints.swapAt(index, index - 1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(index == 0)
                    Button {
                        endpoints.swapAt(index, index + 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(index == endpoints.count - 1)
                    Button(role: .destructive) {
                        endpoints.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .disabled(endpoints.count <= 1)
                }
                .buttonStyle(.plain)
            }
            HStack {
                TextField("新增入口 host:port", text: $newEndpoint)
                    .font(.caption.monospaced())
                Button("添加") {
                    let trimmed = newEndpoint.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty, !endpoints.contains(trimmed) else { return }
                    endpoints.append(trimmed)
                    newEndpoint = ""
                }
                .disabled(newEndpoint.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(endpoints.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            // 打开时从磁盘取当前值,不用视图层可能过期的快照
            if let server = ClientConfig.load()?.servers.first(where: { $0.id == serverId }) {
                name = server.name
                endpoints = server.endpoints
            }
        }
    }

    private func save() {
        do {
            try ServerDirectory.update(serverId, name: name, endpoints: endpoints, hub: hub)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
