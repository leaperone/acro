import SwiftUI

struct CommandPaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let symbol: String
    let action: () -> Void
}

struct CommandPalette: View {
    let items: [CommandPaletteItem]
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    private var filteredItems: [CommandPaletteItem] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return items }
        return items.filter {
            $0.title.localizedCaseInsensitiveContains(value)
                || ($0.subtitle?.localizedCaseInsensitiveContains(value) ?? false)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.38)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索工作区、项目、终端或命令", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onSubmit(confirmSelection)
                        .onKeyPress(.upArrow) {
                            moveSelection(-1)
                            return .handled
                        }
                        .onKeyPress(.downArrow) {
                            moveSelection(1)
                            return .handled
                        }
                        .onKeyPress(.escape) {
                            onDismiss()
                            return .handled
                        }
                }
                .font(.system(size: 16))
                .padding(.horizontal, 18)
                .frame(height: 54)

                Divider()

                if filteredItems.isEmpty {
                    ContentUnavailableView("没有匹配结果", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                                    Button {
                                        perform(item)
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: item.symbol)
                                                .frame(width: 20)
                                                .foregroundStyle(.secondary)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(item.title)
                                                    .foregroundStyle(.primary)
                                                    .lineLimit(1)
                                                if let subtitle = item.subtitle, !subtitle.isEmpty {
                                                    Text(subtitle)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(1)
                                                        .truncationMode(.middle)
                                                }
                                            }
                                            Spacer(minLength: 8)
                                        }
                                        .padding(.horizontal, 14)
                                        .frame(height: 44)
                                        .background(
                                            index == selectedIndex
                                                ? Color.accentColor.opacity(0.18)
                                                : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 6)
                                        )
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .id(item.id)
                                }
                            }
                            .padding(8)
                        }
                        .onChange(of: selectedIndex) { _, index in
                            guard index < filteredItems.count else { return }
                            proxy.scrollTo(filteredItems[index].id)
                        }
                    }
                }

                Divider()

                HStack(spacing: 16) {
                    Label("打开", systemImage: "return")
                    Label("选择", systemImage: "arrow.up.arrow.down")
                    Text("Esc 关闭")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .frame(height: 36)
            }
            .frame(width: 640, height: 430)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 1))
            .shadow(radius: 24, y: 12)
            .padding(.top, 72)
        }
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
    }

    private func moveSelection(_ offset: Int) {
        guard !filteredItems.isEmpty else { return }
        selectedIndex = (selectedIndex + offset + filteredItems.count) % filteredItems.count
    }

    private func confirmSelection() {
        guard selectedIndex < filteredItems.count else { return }
        perform(filteredItems[selectedIndex])
    }

    private func perform(_ item: CommandPaletteItem) {
        onDismiss()
        item.action()
    }
}
