import AppKit
import Bonsplit
import CmuxPanes
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class TerminalPaneController: BonsplitDelegate {
    let key: ScopedResourceID
    private(set) var controller: BonsplitController

    @ObservationIgnored private weak var model: WorkbenchModel?
    @ObservationIgnored private var representedLayout: WorkspaceTerminalLayout
    @ObservationIgnored private var sessionIdsByTabId: [TabID: String] = [:]
    @ObservationIgnored private var tabIdsBySessionId: [String: TabID] = [:]
    @ObservationIgnored private var lastAgentEventBySessionId: [String: AgentAttentionSignal] = [:]
    @ObservationIgnored private var unreadAgentSessionIds: Set<String> = []
    @ObservationIgnored private var forcedCloseTabIds: Set<TabID> = []
    @ObservationIgnored private var trafficLightClearance: Bool
    @ObservationIgnored private var terminalChromeAppearance: TerminalChromeAppearance
    @ObservationIgnored private let fileDropHandler: @MainActor (ScopedResourceID, [URL]) -> Bool

    init(
        model: WorkbenchModel,
        key: ScopedResourceID,
        layout: WorkspaceTerminalLayout,
        trafficLightClearance: Bool,
        terminalChromeAppearance: TerminalChromeAppearance = .fallback,
        fileDropHandler: @escaping @MainActor (ScopedResourceID, [URL]) -> Bool
    ) {
        self.model = model
        self.key = key
        self.representedLayout = layout
        self.trafficLightClearance = trafficLightClearance
        self.terminalChromeAppearance = terminalChromeAppearance
        self.fileDropHandler = fileDropHandler
        self.controller = BonsplitController(
            configuration: Self.configuration(
                trafficLightClearance: trafficLightClearance,
                terminalChromeAppearance: terminalChromeAppearance
            )
        )
        restore(layout)
    }

    var focusedSessionId: String? {
        guard let pane = controller.focusedPaneId,
              let tabId = controller.selectedTabId(inPane: pane)
        else { return nil }
        return sessionIdsByTabId[tabId]
    }

    func sessionId(for tabId: TabID) -> String? {
        sessionIdsByTabId[tabId]
    }

    func update(layout: WorkspaceTerminalLayout, trafficLightClearance: Bool) {
        self.trafficLightClearance = trafficLightClearance
        controller.configuration.appearance.tabBarLeadingInset = trafficLightClearance ? 80 : 0
        if representedLayout.root != layout.root
            || representedLayout.focusedPaneId != layout.focusedPaneId {
            representedLayout = layout
            restore(layout)
        } else {
            representedLayout = layout
            refreshTabMetadata()
        }
    }

    func applyTerminalChromeAppearance(_ appearance: TerminalChromeAppearance) {
        guard terminalChromeAppearance != appearance else { return }
        terminalChromeAppearance = appearance
        Self.applyTerminalChromeAppearance(appearance, to: &controller.configuration.appearance)
    }

    func deactivate() {
        controller.isInteractive = false
        controller.delegate = nil
        controller.onTabCloseRequest = nil
        controller.onFileDrop = nil
    }

    func refreshTabMetadata() {
        guard let model else { return }
        let attentionSignals = model.hub.connection(for: key.serverId)?.agentAttentionSignals ?? [:]
        let representedSessionIds = Set(sessionIdsByTabId.values)
        lastAgentEventBySessionId = lastAgentEventBySessionId.filter {
            representedSessionIds.contains($0.key)
        }
        unreadAgentSessionIds.formIntersection(representedSessionIds)
        let workspaceIsVisible = model.selectedServerId == key.serverId
            && model.selectedWorkspaceId == key.resourceId

        for (tabId, sessionId) in sessionIdsByTabId {
            let event = attentionSignals[sessionId]
            let isSelected = workspaceIsVisible && (
                controller.paneId(containing: tabId).map {
                    controller.selectedTabId(inPane: $0) == tabId
                } ?? false
            )
            updateAgentAttention(
                event,
                for: sessionId,
                isSelected: isSelected
            )
            controller.updateTab(
                tabId,
                title: model.terminalTabTitle(sessionId, for: key),
                icon: .some("terminal.fill"),
                kind: .some("terminal"),
                hasCustomTitle: representedLayout.customTitlesBySessionId[sessionId] != nil,
                showsNotificationBadge: unreadAgentSessionIds.contains(sessionId)
            )
        }
    }

    func select(sessionId: String) -> Bool {
        guard let tabId = tabIdsBySessionId[sessionId] else { return false }
        controller.selectTab(tabId)
        return true
    }

    func adopt(sessionId: String) -> Bool {
        if select(sessionId: sessionId) { return true }
        guard let model,
              let pane = controller.focusedPaneId ?? controller.allPaneIds.first,
              let tabId = controller.createTab(
                  title: model.terminalTabTitle(sessionId, for: key),
                  icon: "terminal.fill",
                  kind: "terminal",
                  inPane: pane
              )
        else { return false }
        register(tabId: tabId, sessionId: sessionId)
        controller.selectTab(tabId)
        persist(markDirty: false)
        return true
    }

    func selectTab(number: Int) -> Bool {
        guard let pane = controller.focusedPaneId else { return false }
        let tabs = controller.tabs(inPane: pane).compactMap { tab -> (TabID, String)? in
            guard let sessionId = sessionIdsByTabId[tab.id] else { return nil }
            return (tab.id, sessionId)
        }
        guard let index = NumberedShortcutMapper.index(forDigit: number, count: tabs.count) else {
            return false
        }
        controller.selectTab(tabs[index].0)
        return true
    }

    func selectAdjacentTab(offset: Int) -> Bool {
        let tabs = controller.allPaneIds.flatMap { pane in
            controller.tabs(inPane: pane).compactMap { tab in
                sessionIdsByTabId[tab.id].map { (tab.id, $0) }
            }
        }
        guard tabs.count > 1,
              let focusedSessionId,
              let index = tabs.firstIndex(where: { $0.1 == focusedSessionId })
        else { return false }
        controller.selectTab(tabs[(index + offset + tabs.count) % tabs.count].0)
        return true
    }

    func focusPane(toward direction: PaneDirection) {
        let navigationDirection: NavigationDirection = switch direction {
        case .left: .left
        case .right: .right
        case .up: .up
        case .down: .down
        }
        controller.navigateFocus(direction: navigationDirection)
    }

    func split(_ direction: TerminalSplitDirection) {
        let orientation: SplitOrientation = direction == .horizontal ? .horizontal : .vertical
        _ = controller.splitPane(orientation: orientation)
    }

    func equalizeSplits() {
        let result = PaneLayoutService().equalizeSplits(
            in: controller.treeSnapshot(),
            controller: controller
        )
        if result.foundSplit {
            persist(markDirty: true)
        }
    }

    func createTerminal(in pane: PaneID? = nil, inheritFrom explicit: String? = nil) {
        guard let targetPane = pane ?? controller.focusedPaneId else { return }
        let inheritFrom = explicit ?? controller.selectedTabId(inPane: targetPane)
            .flatMap { sessionIdsByTabId[$0] }
        createTerminal(in: targetPane, inheritFrom: inheritFrom)
    }

    func removeSession(_ sessionId: String, markDirty: Bool = true) -> Bool {
        guard let tabId = tabIdsBySessionId[sessionId] else { return false }
        forcedCloseTabIds.insert(tabId)
        let closed = controller.closeTab(tabId)
        forcedCloseTabIds.remove(tabId)
        if closed {
            sessionIdsByTabId.removeValue(forKey: tabId)
            tabIdsBySessionId.removeValue(forKey: sessionId)
            clearAgentAttention(for: sessionId)
            persist(markDirty: markDirty)
        }
        return closed
    }

    func splitTabBar(
        _ controller: BonsplitController,
        shouldCloseTab tab: Bonsplit.Tab,
        inPane pane: PaneID
    ) -> Bool {
        sessionIdsByTabId[tab.id] == nil || forcedCloseTabIds.contains(tab.id)
    }

    func splitTabBar(
        _ controller: BonsplitController,
        didCloseTab tabId: TabID,
        fromPane pane: PaneID
    ) {
        if let sessionId = sessionIdsByTabId.removeValue(forKey: tabId) {
            tabIdsBySessionId.removeValue(forKey: sessionId)
            clearAgentAttention(for: sessionId)
        }
    }

    func splitTabBar(
        _ controller: BonsplitController,
        didSelectTab tab: Bonsplit.Tab,
        inPane pane: PaneID
    ) {
        guard let sessionId = sessionIdsByTabId[tab.id] else { return }
        markAgentAttentionRead(for: sessionId, tabId: tab.id)
        model?.applyTerminalPaneSelection(sessionId, for: key)
        persist(markDirty: true)
    }

    func splitTabBar(
        _ controller: BonsplitController,
        didMoveTab tab: Bonsplit.Tab,
        fromPane source: PaneID,
        toPane destination: PaneID
    ) {
        guard let sessionId = sessionIdsByTabId[tab.id] else { return }
        markAgentAttentionRead(for: sessionId, tabId: tab.id)
        model?.applyTerminalPaneSelection(sessionId, for: key)
        persist(markDirty: true)
    }

    func splitTabBar(
        _ controller: BonsplitController,
        didReorderTabsInPane pane: PaneID,
        orderedTabIds: [TabID]
    ) {
        persist(markDirty: true)
    }

    func splitTabBar(
        _ controller: BonsplitController,
        didSplitPane originalPane: PaneID,
        newPane: PaneID,
        orientation: SplitOrientation
    ) {
        if controller.tabs(inPane: newPane).contains(where: { sessionIdsByTabId[$0.id] != nil }) {
            repairPlaceholderPaneIfNeeded(originalPane, inheritFrom: focusedSessionId)
            if let sessionId = controller.selectedTabId(inPane: newPane)
                .flatMap({ sessionIdsByTabId[$0] }) {
                model?.applyTerminalPaneSelection(sessionId, for: key)
            }
            persist(markDirty: true)
        } else {
            let inheritFrom = controller.selectedTabId(inPane: originalPane)
                .flatMap { sessionIdsByTabId[$0] }
            createTerminal(in: newPane, inheritFrom: inheritFrom)
        }
    }

    func splitTabBar(_ controller: BonsplitController, didClosePane paneId: PaneID) {
        persist(markDirty: true)
    }

    func splitTabBar(_ controller: BonsplitController, didFocusPane pane: PaneID) {
        guard let tabId = controller.selectedTabId(inPane: pane),
              let sessionId = sessionIdsByTabId[tabId]
        else { return }
        markAgentAttentionRead(for: sessionId, tabId: tabId)
        model?.applyTerminalPaneSelection(sessionId, for: key)
        persist(markDirty: true)
    }

    func splitTabBar(
        _ controller: BonsplitController,
        didRequestNewTab kind: String,
        inPane pane: PaneID
    ) {
        createTerminal(in: pane)
    }

    func splitTabBar(
        _ controller: BonsplitController,
        didRequestTabContextAction action: TabContextAction,
        for tab: Bonsplit.Tab,
        inPane pane: PaneID
    ) {
        switch action {
        case .rename:
            guard let sessionId = sessionIdsByTabId[tab.id],
                  let model,
                  let title = promptForTabTitle(
                      currentTitle: model.terminalTabTitle(sessionId, for: key)
                  )
            else { return }
            _ = model.setTerminalTabCustomTitle(title, for: sessionId, in: key)
        case .clearName:
            guard let sessionId = sessionIdsByTabId[tab.id] else { return }
            _ = model?.setTerminalTabCustomTitle(nil, for: sessionId, in: key)
        case .closeToLeft, .closeToRight, .closeOthers:
            let tabs = controller.tabs(inPane: pane)
            guard let anchor = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
            let targets: [Bonsplit.Tab] = switch action {
            case .closeToLeft:
                Array(tabs[..<anchor])
            case .closeToRight:
                Array(tabs.dropFirst(anchor + 1))
            case .closeOthers:
                tabs.filter { $0.id != tab.id }
            default:
                []
            }
            model?.requestKillTabs(targets.compactMap { sessionIdsByTabId[$0.id] }, for: key)
        case .moveToLeftPane, .moveToRightPane:
            let direction: NavigationDirection = action == .moveToLeftPane ? .left : .right
            guard let destination = controller.adjacentPane(to: pane, direction: direction) else {
                return
            }
            _ = controller.moveTab(tab.id, toPane: destination, atIndex: nil)
        case .toggleZoom:
            _ = controller.requestTabZoomToggle(for: tab.id, inPane: pane)
        default:
            break
        }
    }

    func splitTabBar(_ controller: BonsplitController, didChangeGeometry snapshot: LayoutSnapshot) {
        persist(markDirty: true)
    }

    func splitTabBar(
        _ controller: BonsplitController,
        shouldNotifyDuringDrag: Bool
    ) -> Bool {
        false
    }

    private static func configuration(
        trafficLightClearance: Bool,
        terminalChromeAppearance: TerminalChromeAppearance
    ) -> BonsplitConfiguration {
        var appearance = BonsplitConfiguration.Appearance(
            tabBarHeight: 28,
            dividerHitExpansion: 5,
            showSplitButtons: true,
            splitButtons: [.newTerminal, .splitRight, .splitDown],
            splitButtonBackdropEffect: .init(
                fadeWidth: 99.75,
                contentFadeWidth: 28.875,
                solidWidth: 23.875,
                solidSurfaceWidthAdjustment: -80,
                separatorFadeWidth: 99.75,
                fadeRampStartFraction: 0.60,
                trailingOpacity: 0.8625,
                contentOcclusionFraction: 0.6875
            ),
            tabBarLeadingInset: trafficLightClearance ? 80 : 0,
            splitButtonTooltips: .init(
                newTerminal: "新建终端",
                newBrowser: "新建浏览器",
                splitRight: "向右分屏",
                splitDown: "向下分屏"
            ),
            enableAnimations: false
        )
        applyTerminalChromeAppearance(terminalChromeAppearance, to: &appearance)
        return BonsplitConfiguration(
            allowSplits: true,
            allowCloseTabs: true,
            allowCloseLastPane: false,
            allowTabReordering: true,
            allowCrossPaneTabMove: true,
            allowsTabContextMenu: true,
            allowedTabContextActions: [
                .rename,
                .clearName,
                .closeToLeft,
                .closeToRight,
                .closeOthers,
                .moveToLeftPane,
                .moveToRightPane,
                .toggleZoom,
                .toggleFullWidthTab,
            ],
            autoCloseEmptyPanes: true,
            contentViewLifecycle: .keepAllAlive,
            newTabPosition: .current,
            tabBarVisibility: .always,
            dividerPositionRange: 0.1...0.9,
            appearance: appearance
        )
    }

    private static func applyTerminalChromeAppearance(
        _ terminal: TerminalChromeAppearance,
        to appearance: inout BonsplitConfiguration.Appearance
    ) {
        let surfaceHex = terminal.backgroundHex
        appearance.chromeColors = terminal.usesSharedBackdrop
            ? .init(
                backgroundHex: surfaceHex,
                tabBarBackgroundHex: "#00000000",
                splitButtonBackdropHex: "#00000000",
                paneBackgroundHex: "#00000000",
                borderHex: terminal.borderHex
            )
            : .init(
                backgroundHex: surfaceHex,
                tabBarBackgroundHex: surfaceHex,
                splitButtonBackdropHex: surfaceHex,
                paneBackgroundHex: "#00000000",
                borderHex: terminal.borderHex
            )
        appearance.usesSharedBackdrop = terminal.usesSharedBackdrop
    }

    private func restore(_ layout: WorkspaceTerminalLayout) {
        controller.isInteractive = false
        controller.delegate = nil
        controller.onTabCloseRequest = nil
        controller.onFileDrop = nil
        let restoredController = BonsplitController(
            configuration: Self.configuration(
                trafficLightClearance: trafficLightClearance,
                terminalChromeAppearance: terminalChromeAppearance
            )
        )
        controller = restoredController
        sessionIdsByTabId.removeAll()
        tabIdsBySessionId.removeAll()

        for tabId in restoredController.allTabIds {
            _ = restoredController.closeTab(tabId)
        }

        guard let root = layout.root,
              let rootPane = restoredController.allPaneIds.first
        else {
            configureCallbacks()
            return
        }

        var restoredPaneIds: [String: PaneID] = [:]
        restoreTopology(root, in: rootPane, paneIds: &restoredPaneIds)
        applyDividerPositions(snapshotNode: root, liveNode: restoredController.treeSnapshot())
        if let focusedPaneId = layout.focusedPaneId,
           let focusedPane = restoredPaneIds[focusedPaneId] {
            restoredController.focusPane(focusedPane)
        }
        configureCallbacks()
        refreshTabMetadata()
    }

    private func restoreTopology(
        _ node: TerminalLayoutNode,
        in paneId: PaneID,
        paneIds: inout [String: PaneID]
    ) {
        switch node {
        case .pane(let pane):
            paneIds[pane.id] = paneId
            for sessionId in pane.sessionIds {
                guard let tabId = controller.createTab(
                    title: model?.terminalTabTitle(sessionId, for: key) ?? "终端",
                    hasCustomTitle: representedLayout.customTitlesBySessionId[sessionId] != nil,
                    icon: "terminal.fill",
                    kind: "terminal",
                    inPane: paneId
                ) else { continue }
                register(tabId: tabId, sessionId: sessionId)
            }
            if let selectedSessionId = pane.selectedSessionId,
               let selectedTabId = tabIdsBySessionId[selectedSessionId] {
                controller.selectTab(selectedTabId)
            }
        case .split(let split):
            let orientation: SplitOrientation = split.direction == .horizontal
                ? .horizontal
                : .vertical
            guard let secondPaneId = controller.splitPane(paneId, orientation: orientation) else {
                restoreTopology(split.first, in: paneId, paneIds: &paneIds)
                return
            }
            restoreTopology(split.first, in: paneId, paneIds: &paneIds)
            restoreTopology(split.second, in: secondPaneId, paneIds: &paneIds)
        }
    }

    private func applyDividerPositions(snapshotNode: TerminalLayoutNode, liveNode: ExternalTreeNode) {
        guard case .split(let snapshotSplit) = snapshotNode,
              case .split(let liveSplit) = liveNode,
              let splitId = UUID(uuidString: liveSplit.id)
        else { return }
        _ = controller.setDividerPosition(
            CGFloat(snapshotSplit.ratio),
            forSplit: splitId,
            fromExternal: true
        )
        applyDividerPositions(snapshotNode: snapshotSplit.first, liveNode: liveSplit.first)
        applyDividerPositions(snapshotNode: snapshotSplit.second, liveNode: liveSplit.second)
    }

    private func configureCallbacks() {
        controller.delegate = self
        controller.onTabCloseRequest = { [weak self] tabId, _, _ in
            guard let self, let sessionId = self.sessionIdsByTabId[tabId] else { return }
            self.model?.requestKillTab(sessionId, for: self.key)
        }
        controller.onFileDrop = { [weak self] urls, paneId in
            guard let self,
                  let tabId = self.controller.selectedTabId(inPane: paneId),
                  let sessionId = self.sessionIdsByTabId[tabId]
            else { return false }
            return self.fileDropHandler(
                ScopedResourceID(serverId: self.key.serverId, resourceId: sessionId),
                urls
            )
        }
    }

    private func register(tabId: TabID, sessionId: String) {
        sessionIdsByTabId[tabId] = sessionId
        tabIdsBySessionId[sessionId] = tabId
    }

    private func updateAgentAttention(
        _ event: AgentAttentionSignal?,
        for sessionId: String,
        isSelected: Bool
    ) {
        guard let event else {
            clearAgentAttention(for: sessionId)
            return
        }
        let previous = lastAgentEventBySessionId.updateValue(event, forKey: sessionId)
        if isSelected {
            unreadAgentSessionIds.remove(sessionId)
        } else if previous != event {
            unreadAgentSessionIds.insert(sessionId)
        }
    }

    private func markAgentAttentionRead(for sessionId: String, tabId: TabID) {
        guard unreadAgentSessionIds.remove(sessionId) != nil else { return }
        controller.updateTab(tabId, showsNotificationBadge: false)
    }

    private func clearAgentAttention(for sessionId: String) {
        lastAgentEventBySessionId.removeValue(forKey: sessionId)
        unreadAgentSessionIds.remove(sessionId)
    }

    private func promptForTabTitle(currentTitle: String) -> String? {
        let alert = NSAlert()
        alert.messageText = String(localized:
            "tab.rename.title",
            defaultValue: "Rename Tab"
        )
        alert.informativeText = String(localized:
            "tab.rename.message",
            defaultValue: "Enter a custom name for this tab."
        )
        let input = NSTextField(string: currentTitle)
        input.placeholderString = String(localized:
            "tab.rename.placeholder",
            defaultValue: "Tab name"
        )
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "common.rename", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        alert.window.initialFirstResponder = input
        if NSApp.activationPolicy() == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
        let hostWindow = NSApp.keyWindow ?? NSApp.mainWindow
        let response: NSApplication.ModalResponse
        if let hostWindow, hostWindow.isVisible, hostWindow.attachedSheet == nil {
            alert.beginSheetModal(for: hostWindow) { result in
                NSApp.stopModal(withCode: result)
            }
            alert.window.makeFirstResponder(input)
            input.selectText(nil)
            response = NSApp.runModal(for: alert.window)
        } else {
            alert.window.makeFirstResponder(input)
            input.selectText(nil)
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return nil }
        return input.stringValue
    }

    private func createTerminal(in pane: PaneID, inheritFrom: String?) {
        Task { [weak self] in
            guard let self, let model = self.model else { return }
            guard let session = await model.createTerminalForPaneController(
                key: self.key,
                inheritFrom: inheritFrom
            ) else {
                self.removeEmptyPaneIfPossible(pane)
                return
            }
            let targetPane = self.controller.allPaneIds.contains(pane)
                ? pane
                : self.controller.focusedPaneId
            if let targetPane,
               self.placeExistingTab(session.id, in: targetPane) {
                await model.refreshRuntime(for: self.key)
                model.applyTerminalPaneSelection(session.id, for: self.key)
                return
            }
            guard let targetPane,
                  let tabId = self.controller.createTab(
                    title: model.sessionDisplayName(session),
                    icon: "terminal.fill",
                    kind: "terminal",
                    inPane: targetPane
                  )
            else {
                await model.refreshRuntime(for: self.key)
                return
            }
            self.register(tabId: tabId, sessionId: session.id)
            self.controller.selectTab(tabId)
            self.persist(markDirty: true)
            await model.refreshRuntime(for: self.key)
            model.applyTerminalPaneSelection(session.id, for: self.key)
        }
    }

    private func repairPlaceholderPaneIfNeeded(_ pane: PaneID, inheritFrom: String?) {
        let placeholders = controller.tabs(inPane: pane).filter { sessionIdsByTabId[$0.id] == nil }
        guard let placeholder = placeholders.first else { return }
        Task { [weak self] in
            guard let self, let model = self.model else { return }
            guard let session = await model.createTerminalForPaneController(
                key: self.key,
                inheritFrom: inheritFrom
            ) else {
                if self.controller.allPaneIds.contains(pane) {
                    _ = self.controller.closePane(pane)
                    self.persist(markDirty: true)
                }
                return
            }
            if self.placeExistingTab(session.id, in: pane) {
                await model.refreshRuntime(for: self.key)
                model.applyTerminalPaneSelection(session.id, for: self.key)
                return
            }
            guard self.controller.tabs(inPane: pane).contains(where: { $0.id == placeholder.id }) else {
                await model.refreshRuntime(for: self.key)
                return
            }
            self.register(tabId: placeholder.id, sessionId: session.id)
            self.controller.updateTab(
                placeholder.id,
                title: model.sessionDisplayName(session),
                icon: .some("terminal.fill"),
                kind: .some("terminal")
            )
            for extra in placeholders.dropFirst() {
                _ = self.controller.closeTab(extra.id)
            }
            self.persist(markDirty: true)
            await model.refreshRuntime(for: self.key)
            model.applyTerminalPaneSelection(session.id, for: self.key)
        }
    }

    private func removeEmptyPaneIfPossible(_ pane: PaneID) {
        guard controller.allPaneIds.count > 1,
              controller.tabs(inPane: pane).isEmpty
        else { return }
        _ = controller.closePane(pane)
        persist(markDirty: true)
    }

    private func placeExistingTab(_ sessionId: String, in pane: PaneID) -> Bool {
        guard let tabId = tabIdsBySessionId[sessionId],
              controller.allPaneIds.contains(pane)
        else { return false }
        if controller.paneId(containing: tabId) != pane {
            guard controller.moveTab(tabId, toPane: pane, atIndex: nil) else { return false }
        }
        for placeholder in controller.tabs(inPane: pane)
        where placeholder.id != tabId && sessionIdsByTabId[placeholder.id] == nil {
            _ = controller.closeTab(placeholder.id)
        }
        controller.selectTab(tabId)
        persist(markDirty: true)
        return true
    }

    private func persist(markDirty: Bool) {
        if sessionIdsByTabId.isEmpty {
            let layout = WorkspaceTerminalLayout()
            representedLayout = layout
            model?.applyTerminalPaneLayout(layout, for: key, markDirty: markDirty)
            return
        }
        guard controller.allPaneIds.allSatisfy({ pane in
                  controller.tabs(inPane: pane).contains { sessionIdsByTabId[$0.id] != nil }
              })
        else { return }
        let layout = WorkspaceTerminalLayout(
            root: layoutNode(from: controller.treeSnapshot()),
            focusedPaneId: controller.focusedPaneId?.id.uuidString,
            customTitlesBySessionId: representedLayout.customTitlesBySessionId.filter {
                sessionIdsByTabId.values.contains($0.key)
            }
        )
        representedLayout = layout
        model?.applyTerminalPaneLayout(layout, for: key, markDirty: markDirty)
    }

    private func layoutNode(from node: ExternalTreeNode) -> TerminalLayoutNode {
        switch node {
        case .pane(let pane):
            let paneId = UUID(uuidString: pane.id).map(PaneID.init(id:))
            let tabs = paneId.map { controller.tabs(inPane: $0) } ?? []
            let sessionIds = tabs.compactMap { sessionIdsByTabId[$0.id] }
            let selectedSessionId = paneId
                .flatMap { controller.selectedTabId(inPane: $0) }
                .flatMap { sessionIdsByTabId[$0] }
            return .pane(PaneTabGroup(
                id: pane.id,
                sessionIds: sessionIds,
                selectedSessionId: selectedSessionId
            ))
        case .split(let split):
            return .split(SplitNode(
                id: split.id,
                direction: split.orientation == "horizontal" ? .horizontal : .vertical,
                ratio: split.dividerPosition,
                first: layoutNode(from: split.first),
                second: layoutNode(from: split.second)
            ))
        }
    }
}
