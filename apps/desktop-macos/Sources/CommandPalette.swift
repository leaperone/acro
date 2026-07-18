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
    let item: CommandPaletteItem
    let matchedIndices: Set<Int>
    var id: String { item.id }
}

struct CommandPalette: View {
    let items: [CommandPaletteItem]
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var hoveredIndex: Int?
    @FocusState private var searchFocused: Bool

    // ponytail: 每次 body 求值重建 corpus,条目上千时再缓存到 State
    private var rankedItems: [RankedItem] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return items.map { RankedItem(item: $0, matchedIndices: []) }
        }
        let engine = CommandPaletteSearchEngine(
            entries: items.enumerated().map { index, item in
                CommandPaletteSearchCorpusEntry(
                    payload: index,
                    rank: index,
                    title: item.title,
                    searchableTexts: [item.subtitle, item.kind].compactMap { $0 }
                )
            }
        )
        return engine.search(query: value, historyBoost: { _, _ in 0 }).map { result in
            RankedItem(item: items[result.payload], matchedIndices: result.titleMatchIndices)
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

                let ranked = rankedItems
                if ranked.isEmpty {
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
                                ForEach(Array(ranked.enumerated()), id: \.element.id) { index, entry in
                                    row(entry, index: index)
                                }
                            }
                            .padding(6)
                        }
                        .frame(height: min(430, CGFloat(ranked.count) * 40 + 12))
                        .onChange(of: selectedIndex) { _, index in
                            guard index < ranked.count else { return }
                            proxy.scrollTo(ranked[index].id)
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
            selectedIndex = 0
            hoveredIndex = nil
        }
    }

    private func row(_ entry: RankedItem, index: Int) -> some View {
        let isSelected = index == selectedIndex
        let isHovered = hoveredIndex == index
        let background: Color = isSelected
            ? Color.accentColor.opacity(0.16)
            : (isHovered ? Color.primary.opacity(0.07) : .clear)
        return Button {
            perform(entry.item)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: entry.item.symbol)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    highlightedTitle(entry)
                        .lineLimit(1)
                    if let subtitle = entry.item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                Text(entry.item.kind)
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

    // 命中字符加粗提色,对应 cmux 的 matchedIndices 渲染
    private func highlightedTitle(_ entry: RankedItem) -> Text {
        guard !entry.matchedIndices.isEmpty else {
            return Text(entry.item.title)
        }
        var result = Text(verbatim: "")
        for (index, char) in entry.item.title.enumerated() {
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
        let ranked = rankedItems
        guard selectedIndex < ranked.count else { return }
        perform(ranked[selectedIndex].item)
    }

    private func perform(_ item: CommandPaletteItem) {
        onDismiss()
        item.action()
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
                action: { Task { await self.createWorkspace() } }
            ),
            CommandPaletteItem(
                id: "command:toggle-sidebar",
                title: leftSidebarVisible ? "隐藏左侧栏" : "显示左侧栏",
                subtitle: nil,
                symbol: "sidebar.left",
                kind: "命令",
                action: { self.leftSidebarVisible.toggle() }
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
            if !projects(in: selectedWorkspace).isEmpty {
                items.append(CommandPaletteItem(
                    id: "command:new-terminal",
                    title: "新建终端",
                    subtitle: selectedWorkspace.name,
                    symbol: "terminal",
                    kind: "命令",
                    action: { self.requestNewTerminal(in: selectedWorkspace) }
                ))
            }
            if selectedSession != nil, selectedProject != nil {
                items.append(contentsOf: [
                    CommandPaletteItem(
                        id: "command:split-right",
                        title: "向右分屏",
                        subtitle: "在同一项目中创建终端",
                        symbol: "rectangle.split.2x1",
                        kind: "命令",
                        action: { self.splitTerminal(.horizontal) }
                    ),
                    CommandPaletteItem(
                        id: "command:split-down",
                        title: "向下分屏",
                        subtitle: "在同一项目中创建终端",
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
            for project in projects(in: workspace) {
                items.append(CommandPaletteItem(
                    id: "project:\(workspace.id):\(project.id)",
                    title: project.name,
                    subtitle: "\(workspace.name) · \(project.path)",
                    symbol: "folder",
                    kind: "项目",
                    action: { Task { _ = await self.openTerminal(project: project, workspace: workspace) } }
                ))
            }
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
