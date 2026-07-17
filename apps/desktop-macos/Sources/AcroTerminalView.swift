// libghostty 终端表面。surface command 跑 `acro attach`,把 Runtime 的 WS 会话桥到本地 PTY
// (cmux 验证过的模式)。事件转发取自 muxy(MIT, Copyright (c) 2026 Muxy)的简化版:
// ponytail: 无 IME/marked text/option-as-alt,中文输入法组合输入接 NSTextInputClient 时再补。

import AppKit
import GhosttyKit
import SwiftUI

final class AcroTerminalNSView: NSView {
    private var surface: ghostty_surface_t?
    private var cStrings: [UnsafeMutablePointer<CChar>] = []
    private var appliedFocusRequest = 0
    private let command: String
    var onClose: (() -> Void)?

    init(command: String) {
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        createSurfaceIfNeeded()
        focusTerminal()
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
        ghostty_surface_set_focus(surface, true)
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
        if let surface {
            ghostty_surface_free(surface)
            self.surface = nil
        }
        onClose?()
    }

    func applyFocusRequest(_ request: Int) {
        guard request != appliedFocusRequest else { return }
        appliedFocusRequest = request
        focusTerminal()
    }

    private func focusTerminal() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
    }

    // ---- 焦点 ----

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let surface { ghostty_surface_set_focus(surface, true) }
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
        guard let surface else { return }
        var key = buildKeyEvent(
            from: event,
            action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        )
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let text = event.characters ?? ""
        let printable = !text.isEmpty && !flags.contains(.command)
            && !(text.unicodeScalars.first.map { $0.value < 0x20 || ($0.value >= 0xF700 && $0.value <= 0xF8FF) } ?? true)
        if printable, !flags.contains(.control) {
            key.consumed_mods = ghostty_input_mods_e(
                rawValue: Self.mods(from: flags).rawValue
                    & (GHOSTTY_MODS_SHIFT.rawValue | GHOSTTY_MODS_ALT.rawValue)
            )
            text.withCString { ptr in
                key.text = ptr
                _ = ghostty_surface_key(surface, key)
            }
        } else {
            _ = ghostty_surface_key(surface, key)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let surface else { return }
        let key = buildKeyEvent(from: event, action: GHOSTTY_ACTION_RELEASE)
        _ = ghostty_surface_key(surface, key)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface else { return }
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

    private func forwardMouseButton(_ event: NSEvent, state: ghostty_input_mouse_state_e, button: ghostty_input_mouse_button_e) {
        guard let surface else { return }
        forwardMousePos(event)
        _ = ghostty_surface_mouse_button(surface, state, button, Self.mods(from: event.modifierFlags))
    }

    override func mouseDown(with event: NSEvent) {
        focusTerminal()
        forwardMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
    }

    override func mouseUp(with event: NSEvent) {
        forwardMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
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
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            x *= 2
            y *= 2
        }
        ghostty_surface_mouse_scroll(surface, x, y, ghostty_input_scroll_mods_t(0))
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
}

struct AcroTerminalView: NSViewRepresentable {
    let command: String
    let focusRequest: Int
    var onClose: (() -> Void)? = nil

    func makeNSView(context: Context) -> AcroTerminalNSView {
        let view = AcroTerminalNSView(command: command)
        view.onClose = onClose
        view.applyFocusRequest(focusRequest)
        return view
    }

    func updateNSView(_ nsView: AcroTerminalNSView, context: Context) {
        nsView.onClose = onClose
        nsView.applyFocusRequest(focusRequest)
    }
}
