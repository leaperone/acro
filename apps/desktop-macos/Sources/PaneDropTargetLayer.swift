// 窗格拖拽落点层:真正的 AppKit NSDraggingDestination,盖在内嵌 ghostty 终端 NSView 之上。
//
// 为什么不用 SwiftUI .onDrop:内嵌的终端是 AppKit NSView,SwiftUI 的 .onDrop 叠在其上时
// 命中树里常被终端 NSView 抢先,拖拽回调静默不触发,拖到窗格身上的分屏就"没反应"。
// 做法取自 cmux Bonsplit(GPL-3.0-or-later, Copyright (c) 2024-present Manaflow, Inc.):
// 用一个 registerForDraggedTypes 的 NSView 承接拖拽,并且只在拖拽进行中经 hitTest 接管,
// 平时返回 nil 让鼠标/键盘直接落到终端上,不影响输入和打字延迟。

import AppKit
import SwiftUI

final class AcroPaneDropTargetView: NSView {
    var isDragActive = false
    var canAccept: () -> Bool = { false }
    var onZone: (PaneDropZone?) -> Void = { _ in }
    var perform: (PaneDropZone) -> Bool = { _ in false }

    // 用左上原点(与 SwiftUI 一致),直接复用 PaneDropZone.zone 的边缘算法
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([acroTabTransferPasteboardType])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // 只在本进程的标签拖拽进行中接管命中;否则穿透,普通鼠标/键盘照常落到终端
    override func hitTest(_ point: NSPoint) -> NSView? {
        isDragActive ? super.hitTest(point) : nil
    }

    private func zone(for sender: NSDraggingInfo) -> PaneDropZone {
        let local = convert(sender.draggingLocation, from: nil)
        return PaneDropZone.zone(at: CGPoint(x: local.x, y: local.y), in: bounds.size)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canAccept() else { return [] }
        onZone(zone(for: sender))
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canAccept() else {
            onZone(nil)
            return []
        }
        onZone(zone(for: sender))
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onZone(nil)
    }

    // 兜底:某些取消场景 AppKit 只发 draggingEnded 而不发 draggingExited,清掉残留高亮
    override func draggingEnded(_ sender: NSDraggingInfo) {
        onZone(nil)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let target = zone(for: sender)
        onZone(nil)
        guard canAccept() else { return false }
        return perform(target)
    }
}

struct PaneDropTargetLayer: NSViewRepresentable {
    var isDragActive: Bool
    var canAccept: () -> Bool
    var onZone: (PaneDropZone?) -> Void
    var perform: (PaneDropZone) -> Bool

    func makeNSView(context: Context) -> AcroPaneDropTargetView {
        let view = AcroPaneDropTargetView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: AcroPaneDropTargetView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: AcroPaneDropTargetView) {
        view.isDragActive = isDragActive
        view.canAccept = canAccept
        view.onZone = onZone
        view.perform = perform
    }
}
