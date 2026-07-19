// libghostty 终端表面。surface command 跑 `acro attach`,把 Runtime 的 WS 会话桥到本地 PTY
// (cmux 验证过的模式)。事件转发与 NSTextInputClient 接入取自 muxy
// (MIT, Copyright (c) 2026 Muxy)的简化版。

import AppKit
import GhosttyKit
import SwiftUI

final class AcroTerminalNSView: NSView {
    private var surface: ghostty_surface_t?
    private var cStrings: [UnsafeMutablePointer<CChar>] = []
    private var requestedFocusRequest = 0
    private var appliedFocusRequest = 0
    let serverId: String
    let sessionId: String
    private let command: String
    private var markedText = ""
    private var _markedRange = NSRange(location: NSNotFound, length: 0)
    private var _selectedMarkedRange = NSRange(location: 0, length: 0)
    private var keyTextAccumulator: [String] = []
    private var currentKeyEvent: NSEvent?
    private var commandSelectorCalled = false
    private var leftMousePressed = false
    var onClose: (() -> Void)?
    var onFocus: (() -> Void)?

    init(serverId: String, sessionId: String, command: String) {
        self.serverId = serverId
        self.sessionId = sessionId
        self.command = command
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let surface { ghostty_surface_free(surface) }
        for ptr in cStrings { free(ptr) }
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // 窗口开了 isMovableByWindowBackground(紧凑模式空白处拖动);
    // 终端内的拖动属于文字选择,不参与窗口拖动
    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        createSurfaceIfNeeded()
        applyFocusRequest(requestedFocusRequest)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { releaseLeftMouseButton() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func layout() {
        super.layout()
        createSurfaceIfNeeded()
        syncSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface, let window else { return }
        let scale = window.backingScaleFactor
        ghostty_surface_set_content_scale(surface, scale, scale)
        syncSize()
    }

    private func createSurfaceIfNeeded() {
        guard surface == nil,
              let app = Ghostty.shared.app,
              let window,
              bounds.width > 1, bounds.height > 1
        else { return }

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque())
        )
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(window.backingScaleFactor)
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        config.wait_after_command = false
        if let cmd = strdup(command) {
            cStrings.append(cmd)
            config.command = UnsafePointer(cmd)
        }

        surface = ghostty_surface_new(app, &config)
        guard let surface else {
            NSLog("ghostty_surface_new failed")
            return
        }
        let scale = window.backingScaleFactor
        ghostty_surface_set_content_scale(surface, scale, scale)
        syncSize()
        ghostty_surface_set_focus(surface, window.firstResponder === self)
        if let screen = window.screen,
           let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
            ghostty_surface_set_display_id(surface, displayID)
        }
    }

    private func syncSize() {
        guard let surface, let window else { return }
        let backing = convertToBacking(bounds.size)
        guard backing.width > 0, backing.height > 0 else { return }
        _ = window
        ghostty_surface_set_size(surface, UInt32(backing.width), UInt32(backing.height))
    }

    func surfaceDidRequestClose() {
        leftMousePressed = false
        if let surface {
            ghostty_surface_free(surface)
            self.surface = nil
        }
        TerminalSurfaceCache.shared.evict(
            serverId: serverId,
            sessionId: sessionId,
            teardown: false
        )
        onClose?()
    }

    // 缓存逐出时显式释放;deinit 兜底
    func teardown() {
        leftMousePressed = false
        if let surface {
            ghostty_surface_free(surface)
            self.surface = nil
        }
        removeFromSuperview()
    }

    func applyFocusRequest(_ request: Int) {
        requestedFocusRequest = request
        guard request > 0, request != appliedFocusRequest, window != nil else { return }
        appliedFocusRequest = request
        focusTerminal()
    }

    private func focusTerminal() {
        NSApp.activate()
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        if window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            if window.firstResponder !== self {
                window.makeFirstResponder(self)
            }
        }
    }

    // ---- 焦点 ----

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            if let surface { ghostty_surface_set_focus(surface, true) }
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok, let surface { ghostty_surface_set_focus(surface, false) }
        return ok
    }

    // ---- 键盘 ----

    private func buildKeyEvent(from event: NSEvent, action: ghostty_input_action_e) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode) // ghostty 接受平台键码
        key.mods = Self.mods(from: event.modifierFlags)
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.composing = false
        key.text = nil
        if event.type == .keyDown || event.type == .keyUp,
           let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first {
            key.unshifted_codepoint = scalar.value
        }
        return key
    }

    private static func mods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            super.keyDown(with: event)
            return
        }
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.command) || flags.contains(.control) {
            if isAppShortcut(event) {
                super.keyDown(with: event)
                return
            }
            var key = buildKeyEvent(from: event, action: action)
            key.text = nil
            _ = ghostty_surface_key(surface, key)
            return
        }

        let hadMarkedText = hasMarkedText()
        currentKeyEvent = event
        keyTextAccumulator = []
        commandSelectorCalled = false
        let optionAsAlt = translatedOptionAsAlt(for: event)
        interpretKeyEvents([optionAsAlt ? eventStrippingOption(event) : event])
        currentKeyEvent = nil
        syncPreedit(clearIfNeeded: hadMarkedText)

        if !keyTextAccumulator.isEmpty {
            for text in keyTextAccumulator {
                var key = buildKeyEvent(from: event, action: action)
                key.consumed_mods = commandSelectorCalled
                    ? GHOSTTY_MODS_NONE
                    : consumedMods(from: flags, consumeOption: !optionAsAlt)
                text.withCString { ptr in
                    key.text = ptr
                    _ = ghostty_surface_key(surface, key)
                }
            }
            return
        }

        var key = buildKeyEvent(from: event, action: action)
        key.consumed_mods = commandSelectorCalled
            ? GHOSTTY_MODS_NONE
            : consumedMods(from: flags, consumeOption: !optionAsAlt)
        key.composing = hasMarkedText() || hadMarkedText
        let text = filterSpecialCharacters(event.characters ?? "")
        if !text.isEmpty, !key.composing {
            text.withCString { ptr in
                key.text = ptr
                _ = ghostty_surface_key(surface, key)
            }
        } else {
            key.consumed_mods = GHOSTTY_MODS_NONE
            key.text = nil
            _ = ghostty_surface_key(surface, key)
        }
    }

    override func doCommand(by selector: Selector) {
        commandSelectorCalled = true
    }

    override func insertText(_ insertString: Any) {
        insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isAppShortcut(event) { return false }
        guard window?.firstResponder === self,
              event.type == .keyDown,
              let surface
        else { return false }
        var key = buildKeyEvent(
            from: event,
            action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        )
        key.text = nil
        guard ghostty_surface_key_is_binding(surface, key, nil) else { return false }
        _ = ghostty_surface_key(surface, key)
        return true
    }

    // 应用快捷键统一定义在 ShortcutSettings,这里只做转发判断
    private func isAppShortcut(_ event: NSEvent) -> Bool {
        ShortcutSettings.isAppShortcut(event)
    }

    override func keyUp(with event: NSEvent) {
        if isAppShortcut(event) { return }
        guard let surface else { return }
        let key = buildKeyEvent(from: event, action: GHOSTTY_ACTION_RELEASE)
        _ = ghostty_surface_key(surface, key)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface else { return }
        if hasMarkedText() { return }
        let isPress: Bool = switch event.keyCode {
        case 56, 60: event.modifierFlags.contains(.shift)
        case 58, 61: event.modifierFlags.contains(.option)
        case 59, 62: event.modifierFlags.contains(.control)
        case 54, 55: event.modifierFlags.contains(.command)
        default: false
        }
        let key = buildKeyEvent(from: event, action: isPress ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE)
        _ = ghostty_surface_key(surface, key)
    }

    // ---- 鼠标 ----

    private func forwardMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, bounds.height - pos.y, Self.mods(from: event.modifierFlags))
    }

    @discardableResult
    private func forwardMouseButton(
        _ event: NSEvent,
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e
    ) -> Bool {
        guard let surface else { return false }
        forwardMousePos(event)
        _ = ghostty_surface_mouse_button(surface, state, button, Self.mods(from: event.modifierFlags))
        return true
    }

    private func releaseLeftMouseButton(_ event: NSEvent? = nil) {
        guard leftMousePressed else { return }
        leftMousePressed = false
        guard let surface else { return }
        if let event { forwardMousePos(event) }
        _ = ghostty_surface_mouse_button(
            surface,
            GHOSTTY_MOUSE_RELEASE,
            GHOSTTY_MOUSE_LEFT,
            event.map { Self.mods(from: $0.modifierFlags) } ?? GHOSTTY_MODS_NONE
        )
    }

    override func mouseDown(with event: NSEvent) {
        focusTerminal()
        leftMousePressed = forwardMouseButton(
            event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
        onFocus?()
    }

    override func mouseUp(with event: NSEvent) {
        releaseLeftMouseButton(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        forwardMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func rightMouseUp(with event: NSEvent) {
        forwardMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func mouseMoved(with event: NSEvent) { forwardMousePos(event) }
    override func mouseDragged(with event: NSEvent) { forwardMousePos(event) }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        let mods = ghostty_input_scroll_mods_t(event.hasPreciseScrollingDeltas ? 1 : 0)
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, mods)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    func completeClipboardRequest(_ text: String, state: UnsafeMutableRawPointer?, confirmed: Bool) {
        guard let surface else { return }
        text.withCString { ptr in
            ghostty_surface_complete_clipboard_request(surface, ptr, state, confirmed)
        }
    }

    private func consumedMods(
        from flags: NSEvent.ModifierFlags,
        consumeOption: Bool
    ) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if consumeOption, flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    private func translatedOptionAsAlt(for event: NSEvent) -> Bool {
        guard let surface, event.modifierFlags.contains(.option) else { return false }
        let translated = ghostty_surface_key_translation_mods(surface, Self.mods(from: event.modifierFlags))
        return translated.rawValue & GHOSTTY_MODS_ALT.rawValue == 0
    }

    private func eventStrippingOption(_ event: NSEvent) -> NSEvent {
        NSEvent.keyEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags.subtracting(.option),
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: event.charactersIgnoringModifiers ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) ?? event
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if hasMarkedText(), !markedText.isEmpty {
            markedText.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(markedText.utf8.count))
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    private func filterSpecialCharacters(_ text: String) -> String {
        guard let scalar = text.unicodeScalars.first else { return "" }
        let value = scalar.value
        return value < 0x20 || (0xF700 ... 0xF8FF).contains(value) ? "" : text
    }
}

extension AcroTerminalNSView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        unmarkText()
        guard !text.isEmpty else { return }
        if currentKeyEvent != nil {
            keyTextAccumulator.append(text)
        } else if let surface {
            text.withCString { ptr in
                var key = ghostty_input_key_s()
                key.action = GHOSTTY_ACTION_PRESS
                key.text = ptr
                _ = ghostty_surface_key(surface, key)
            }
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        _markedRange = markedText.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: markedText.utf16.count)
        let length = markedText.utf16.count
        let location = selectedRange.location == NSNotFound ? 0 : min(selectedRange.location, length)
        _selectedMarkedRange = NSRange(
            location: location,
            length: min(selectedRange.length, length - location)
        )
        if currentKeyEvent == nil { syncPreedit() }
    }

    func unmarkText() {
        guard hasMarkedText() else { return }
        markedText = ""
        _markedRange = NSRange(location: NSNotFound, length: 0)
        _selectedMarkedRange = NSRange(location: 0, length: 0)
        syncPreedit()
    }

    func selectedRange() -> NSRange { _selectedMarkedRange }
    func markedRange() -> NSRange { _markedRange }
    func hasMarkedText() -> Bool { _markedRange.location != NSNotFound }

    func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        guard hasMarkedText(), range.location != NSNotFound else { return nil }
        let start = max(range.location, _markedRange.location)
        let end = min(range.location + range.length, _markedRange.location + _markedRange.length)
        guard start <= end else { return nil }
        let safeRange = NSRange(location: start, length: end - start)
        actualRange?.pointee = safeRange
        return NSAttributedString(string: (markedText as NSString).substring(with: safeRange))
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        let viewPoint = NSPoint(x: x, y: bounds.height - y)
        let screenPoint = window?.convertPoint(toScreen: convert(viewPoint, to: nil)) ?? viewPoint
        actualRange?.pointee = range
        return NSRect(x: screenPoint.x, y: screenPoint.y - height, width: width, height: height)
    }
}

// 会话级 surface 缓存(cmux TerminalWindowPortal 的精简版):
// SwiftUI 布局树重建(分屏/移动标签)时直接复用同一个 NSView,
// ghostty surface 与 attach 进程全程存活,旧窗格不再闪空白重载。
@MainActor
final class TerminalSurfaceCache {
    static let shared = TerminalSurfaceCache()

    private var views: [ScopedResourceID: AcroTerminalNSView] = [:]

    func view(serverId: String, sessionId: String, command: String) -> AcroTerminalNSView {
        let key = ScopedResourceID(serverId: serverId, resourceId: sessionId)
        if let view = views[key] { return view }
        let view = AcroTerminalNSView(serverId: serverId, sessionId: sessionId, command: command)
        views[key] = view
        return view
    }

    func evict(serverId: String, sessionId: String, teardown: Bool = true) {
        let key = ScopedResourceID(serverId: serverId, resourceId: sessionId)
        guard let view = views.removeValue(forKey: key) else { return }
        if teardown { view.teardown() }
    }

    // 对账:只保留仍然存活的会话
    func retainOnly(_ sessionIds: Set<ScopedResourceID>) {
        for key in views.keys where !sessionIds.contains(key) {
            evict(serverId: key.serverId, sessionId: key.resourceId)
        }
    }
}

struct AcroTerminalView: NSViewRepresentable {
    let serverId: String
    let sessionId: String
    let command: String
    let focusRequest: Int
    var onClose: (() -> Void)? = nil
    var onFocus: (() -> Void)? = nil

    func makeNSView(context: Context) -> AcroTerminalNSView {
        let view = TerminalSurfaceCache.shared.view(
            serverId: serverId,
            sessionId: sessionId,
            command: command
        )
        view.onClose = onClose
        view.onFocus = onFocus
        view.applyFocusRequest(focusRequest)
        return view
    }

    func updateNSView(_ nsView: AcroTerminalNSView, context: Context) {
        nsView.onClose = onClose
        nsView.onFocus = onFocus
        nsView.applyFocusRequest(focusRequest)
    }
}
