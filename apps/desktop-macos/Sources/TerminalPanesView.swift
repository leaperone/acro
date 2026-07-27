import Bonsplit
import SwiftUI

struct TerminalPanesView: View {
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var runtime: RuntimeConnection

    var body: some View {
        if let paneController = model.currentTerminalPaneController,
           model.currentLayout?.root != nil {
            let tabMetadata = tabMetadata(for: paneController)
            BonsplitView(controller: paneController.controller) { tab, paneId in
                TerminalPaneContent(
                    model: model,
                    paneController: paneController,
                    tab: tab,
                    paneId: paneId
                )
            } emptyPane: { _ in
                ContentUnavailableView("终端已结束", systemImage: "terminal")
            }
            .onChange(of: tabMetadata, initial: true) { _, _ in
                paneController.refreshTabMetadata()
            }
        } else if let selectedWorkspace = model.selectedWorkspace {
            ContentUnavailableView {
                Label("没有终端", systemImage: "terminal")
            } actions: {
                Button("新建终端") {
                    model.requestNewTerminal(in: selectedWorkspace)
                }
            }
        } else if runtime.connected {
            ContentUnavailableView("选择工作区", systemImage: "square.stack.3d.up")
        } else {
            VStack(spacing: 8) {
                Text("未连接 Runtime")
                Text("在设置(⌘,)里粘贴配对码,或在 Runtime 本机运行 acro pair")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tabMetadata(
        for paneController: TerminalPaneController
    ) -> TerminalTabMetadataSnapshot {
        let key = paneController.key
        guard model.hub.connection(for: key.serverId) === runtime else {
            return TerminalTabMetadataSnapshot(key: key, tabs: [])
        }
        let sessionsById = Dictionary(
            runtime.sessions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let tabs = paneController.controller.allPaneIds.flatMap { paneId in
            paneController.controller.tabs(inPane: paneId).compactMap {
                paneController.sessionId(for: $0.id)
            }
        }.compactMap { sessionId in
            sessionsById[sessionId].map {
                TerminalTabMetadata(
                    sessionId: sessionId,
                    cwd: $0.cwd,
                    title: $0.title,
                    agentState: $0.agent?.state,
                    agentUpdatedAt: $0.agent?.updatedAt
                )
            }
        }
        return TerminalTabMetadataSnapshot(key: key, tabs: tabs)
    }
}

private struct TerminalTabMetadataSnapshot: Equatable {
    let key: ScopedResourceID
    let tabs: [TerminalTabMetadata]
}

private struct TerminalTabMetadata: Equatable {
    let sessionId: String
    let cwd: String
    let title: String?
    let agentState: String?
    let agentUpdatedAt: String?
}

private struct TerminalPaneContent: View {
    @ObservedObject var model: WorkbenchModel
    let paneController: TerminalPaneController
    let tab: Bonsplit.Tab
    let paneId: Bonsplit.PaneID

    var body: some View {
        if let sessionId = paneController.sessionId(for: tab.id),
           let connection = model.hub.connection(for: paneController.key.serverId),
           connection.sessions.contains(where: { $0.id == sessionId && $0.alive }) {
            let selected = paneController.controller.selectedTabId(inPane: paneId) == tab.id
            let focused = paneController.controller.focusedPaneId == paneId

            ZStack {
                AcroTerminalView(
                    serverId: paneController.key.serverId,
                    sessionId: sessionId,
                    command: AttachCommand.resolve(
                        sessionId: sessionId,
                        serverId: paneController.key.serverId
                    ),
                    focusRequest: selected && focused ? model.terminalFocusRequest : 0,
                    isActive: selected,
                    onClose: {
                        model.closeTab(
                            sessionId,
                            workspaceId: paneController.key.resourceId,
                            serverId: paneController.key.serverId
                        )
                    },
                    onFocus: {
                        paneController.controller.focusPane(paneId)
                    },
                    onFileDrop: { urls in
                        model.handleTerminalFileDrop(
                            urls,
                            sessionKey: ScopedResourceID(
                                serverId: paneController.key.serverId,
                                resourceId: sessionId
                            ),
                            workspaceId: paneController.key.resourceId
                        )
                    }
                )
                .id(ScopedResourceID(
                    serverId: paneController.key.serverId,
                    resourceId: sessionId
                ))

                if let occupant = model.focusOccupant(sessionId, on: connection) {
                    FocusLockOverlay(
                        deviceName: occupant.deviceName,
                        takeOver: {
                            model.claimFocus(sessionId, force: true)
                        }
                    )
                }
            }
            .attentionFlash(
                token: model.flashToken,
                active: model.flashSessionId == sessionId
            )
        } else {
            ContentUnavailableView("终端已结束", systemImage: "terminal")
        }
    }
}
