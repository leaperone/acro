// 命令面板:模糊匹配 + 命中高亮 + 键盘导航。
// 交互与视觉对标 cmux 的 CommandPaletteOverlay(GPL-3.0-or-later,
// Copyright (c) 2024-present Manaflow, Inc.);
// 排序与命中高亮走 Vendor/CmuxCommandPalette 的 CommandPaletteSearchEngine(cmux 原引擎)。

import CmuxCommandPalette
import SwiftUI

struct CommandPaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let symbol: String
    let kind: String
    let action: () -> Void
}

private struct RankedItem: Identifiable {
    let itemIndex: Int
    let itemId: String
    let matchedIndices: Set<Int>
    var id: String { itemId }
}

private struct CommandPaletteSearchKey: Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let kind: String
}

struct CommandPalette: View {
    let items: [CommandPaletteItem]
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var hoveredIndex: Int?
    @State private var searchEngine: CommandPaletteSearchEngine<Int>
    @State private var rankedItems: [RankedItem]
    @FocusState private var searchFocused: Bool

    init(items: [CommandPaletteItem], onDismiss: @escaping () -> Void) {
        self.items = items
        self.onDismiss = onDismiss
        let engine = Self.makeSearchEngine(items)
        _searchEngine = State(initialValue: engine)
        _rankedItems = State(initialValue: Self.rank(items, with: engine, query: ""))
    }

    private var searchKeys: [CommandPaletteSearchKey] {
        items.map {
            CommandPaletteSearchKey(
                id: $0.id,
                title: $0.title,
                subtitle: $0.subtitle,
                kind: $0.kind
            )
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.32)
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
                .frame(height: 52)

                Divider()

                if rankedItems.isEmpty {
                    Text("没有匹配结果")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(rankedItems.enumerated()), id: \.element.id) { index, entry in
                                    row(entry, index: index)
                                }
                            }
                            .padding(6)
                        }
                        .frame(height: min(430, CGFloat(rankedItems.count) * 40 + 12))
                        .onChange(of: selectedIndex) { _, index in
                            guard index < rankedItems.count else { return }
                            proxy.scrollTo(rankedItems[index].id)
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
                .frame(height: 34)
            }
            .frame(width: 620)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 28, y: 14)
            .padding(.top, 96)
        }
        .onExitCommand(perform: onDismiss)
        .onAppear {
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: query) { _, _ in
            rankedItems = Self.rank(items, with: searchEngine, query: query)
            selectedIndex = 0
            hoveredIndex = nil
        }
        .onChange(of: searchKeys) { _, _ in
            let engine = Self.makeSearchEngine(items)
            searchEngine = engine
            rankedItems = Self.rank(items, with: engine, query: query)
            selectedIndex = min(selectedIndex, max(rankedItems.count - 1, 0))
            hoveredIndex = nil
        }
    }

    @ViewBuilder
    private func row(_ entry: RankedItem, index: Int) -> some View {
        if let item = item(for: entry) {
            let isSelected = index == selectedIndex
            let isHovered = hoveredIndex == index
            let background: Color = isSelected
                ? Color.accentColor.opacity(0.16)
                : (isHovered ? Color.primary.opacity(0.07) : .clear)
            Button {
                perform(item)
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: item.symbol)
                        .frame(width: 18)
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        highlightedTitle(entry, title: item.title)
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
                    Text(item.kind)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                }
                .padding(.horizontal, 11)
                .frame(height: 40)
                .background(background, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .id(entry.id)
            .onHover { hovering in
                if hovering {
                    hoveredIndex = index
                } else if hoveredIndex == index {
                    hoveredIndex = nil
                }
            }
        }
    }

    // 命中字符加粗提色,对应 cmux 的 matchedIndices 渲染
    private func highlightedTitle(_ entry: RankedItem, title: String) -> Text {
        guard !entry.matchedIndices.isEmpty else {
            return Text(title)
        }
        var result = Text(verbatim: "")
        for (index, char) in title.enumerated() {
            let piece = Text(String(char))
            if entry.matchedIndices.contains(index) {
                result = result + piece.bold().foregroundColor(.accentColor)
            } else {
                result = result + piece
            }
        }
        return result
    }

    private func moveSelection(_ offset: Int) {
        let count = rankedItems.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + offset + count) % count
    }

    private func confirmSelection() {
        guard selectedIndex < rankedItems.count,
              let item = item(for: rankedItems[selectedIndex])
        else { return }
        perform(item)
    }

    private func perform(_ item: CommandPaletteItem) {
        onDismiss()
        item.action()
    }

    private func item(for ranked: RankedItem) -> CommandPaletteItem? {
        if items.indices.contains(ranked.itemIndex), items[ranked.itemIndex].id == ranked.itemId {
            return items[ranked.itemIndex]
        }
        return items.first { $0.id == ranked.itemId }
    }

    private static func makeSearchEngine(
        _ items: [CommandPaletteItem]
    ) -> CommandPaletteSearchEngine<Int> {
        CommandPaletteSearchEngine(
            entries: items.enumerated().map { index, item in
                CommandPaletteSearchCorpusEntry(
                    payload: index,
                    rank: index,
                    title: item.title,
                    searchableTexts: [item.subtitle, item.kind].compactMap { $0 }
                )
            }
        )
    }

    private static func rank(
        _ items: [CommandPaletteItem],
        with engine: CommandPaletteSearchEngine<Int>,
        query: String
    ) -> [RankedItem] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return items.prefix(100).enumerated().map { index, item in
                RankedItem(itemIndex: index, itemId: item.id, matchedIndices: [])
            }
        }
        return engine.search(
            query: value,
            resultLimit: 100,
            historyBoost: { _, _ in 0 }
        ).compactMap { result in
            guard items.indices.contains(result.payload) else { return nil }
            return RankedItem(
                itemIndex: result.payload,
                itemId: items[result.payload].id,
                matchedIndices: result.titleMatchIndices
            )
        }
    }
}

// ---- 面板条目由工作台状态推导 ----

extension WorkbenchModel {
    var commandPaletteItems: [CommandPaletteItem] {
        var items: [CommandPaletteItem] = [
            CommandPaletteItem(
                id: "command:new-workspace-group",
                title: "新建分组",
                subtitle: "组织相关工作区",
                symbol: "folder.badge.plus",
                kind: "命令",
                action: { self.presentWorkspaceGroupEditor(workspaceGroupId: nil, name: "") }
            ),
            CommandPaletteItem(
                id: "command:new-workspace",
                title: "新建工作区",
                subtitle: "创建新的工作上下文",
                symbol: "square.stack.3d.up.badge.plus",
                kind: "命令",
                action: { self.requestCreateWorkspace() }
            ),
            CommandPaletteItem(
                id: "command:toggle-sidebar",
                title: "切换到下一种左侧栏模式",
                subtitle: "完整 → 紧凑 → 隐藏",
                symbol: "sidebar.left",
                kind: "命令",
                action: { self.cycleLeftSidebarPresentation() }
            ),
            CommandPaletteItem(
                id: "command:toggle-inspector",
                title: inspectorVisible ? "隐藏右侧栏" : "显示右侧栏",
                subtitle: nil,
                symbol: "sidebar.right",
                kind: "命令",
                action: { self.inspectorVisible.toggle() }
            ),
        ]

        if let selectedWorkspace {
            items.append(CommandPaletteItem(
                id: "command:new-terminal",
                title: "新建终端",
                subtitle: selectedWorkspace.name,
                symbol: "terminal",
                kind: "命令",
                action: { self.requestNewTerminal(in: selectedWorkspace) }
            ))
            if selectedSession != nil {
                items.append(contentsOf: [
                    CommandPaletteItem(
                        id: "command:split-right",
                        title: "向右分屏",
                        subtitle: "沿用当前终端的路径",
                        symbol: "rectangle.split.2x1",
                        kind: "命令",
                        action: { self.splitTerminal(.horizontal) }
                    ),
                    CommandPaletteItem(
                        id: "command:split-down",
                        title: "向下分屏",
                        subtitle: "沿用当前终端的路径",
                        symbol: "rectangle.split.1x2",
                        kind: "命令",
                        action: { self.splitTerminal(.vertical) }
                    ),
                    CommandPaletteItem(
                        id: "command:equalize-splits",
                        title: "均分窗格",
                        subtitle: "所有窗格平均分配空间",
                        symbol: "rectangle.split.3x1",
                        kind: "命令",
                        action: { self.equalizeSplits() }
                    ),
                ])
            }
        }

        for workspace in runtime.workspaces {
            items.append(CommandPaletteItem(
                id: "workspace:\(workspace.id)",
                title: workspace.name,
                subtitle: "\(activeSessionCount(in: workspace)) 个运行终端",
                symbol: "square.stack.3d.up",
                kind: "工作区",
                action: { self.selectWorkspace(workspace) }
            ))
            for session in sessions(in: workspace) {
                items.append(CommandPaletteItem(
                    id: "session:\(session.id)",
                    title: sessionDisplayName(session),
                    subtitle: "\(workspace.name) · \(session.cwd)",
                    symbol: "terminal",
                    kind: "终端",
                    action: { self.showSession(session) }
                ))
            }
        }
        return items
    }
}
