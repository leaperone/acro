// 可配置快捷键。范式取自 cmux 的 KeyboardShortcutSettings
// (GPL-3.0-or-later, Copyright (c) 2024-present Manaflow, Inc.):
// Action 全枚举 + 默认表 + 用户配置文件覆写,一处定义、菜单/终端拦截/提示共用。
// 覆写文件:~/.config/acro/keybindings.json,形如 {"newTerminalTab": {"key": "t", "command": true}}

import AppKit
import SwiftUI

struct StoredShortcut: Codable, Equatable {
    var key: String
    var command = false
    var shift = false
    var option = false
    var control = false

    var keyEquivalent: KeyEquivalent? {
        switch key {
        case "left": .leftArrow
        case "right": .rightArrow
        case "up": .upArrow
        case "down": .downArrow
        default: key.count == 1 ? KeyEquivalent(Character(key)) : nil
        }
    }

    var eventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if command { modifiers.insert(.command) }
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }
        return modifiers
    }

    var keyboardShortcut: KeyboardShortcut? {
        keyEquivalent.map { KeyboardShortcut($0, modifiers: eventModifiers) }
    }

    var displayString: String {
        var parts = ""
        if control { parts += "⌃" }
        if option { parts += "⌥" }
        if shift { parts += "⇧" }
        if command { parts += "⌘" }
        let keyLabel = switch key {
        case "left": "←"
        case "right": "→"
        case "up": "↑"
        case "down": "↓"
        default: key.uppercased()
        }
        return parts + keyLabel
    }

    func matches(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var expected: NSEvent.ModifierFlags = []
        if command { expected.insert(.command) }
        if shift { expected.insert(.shift) }
        if option { expected.insert(.option) }
        if control { expected.insert(.control) }
        guard flags == expected else { return false }
        let eventKey = switch event.keyCode {
        case 123: "left"
        case 124: "right"
        case 125: "down"
        case 126: "up"
        default: (event.charactersIgnoringModifiers ?? "").lowercased()
        }
        return eventKey == key
    }
}

enum ShortcutAction: String, CaseIterable {
    case newTerminalTab
    case newWorkspace
    case newWorkspaceGroup
    case commandPalette
    case toggleSidebar
    case toggleInspector
    case splitRight
    case splitDown
    case previousPane
    case nextPane
    case closeTab
    case previousTab
    case nextTab
    case focusTerminal
    case killSession
}

enum ShortcutSettings {
    static let settingsFilePath = "\(NSHomeDirectory())/.config/acro/keybindings.json"

    static let defaults: [ShortcutAction: StoredShortcut] = [
        .newTerminalTab: StoredShortcut(key: "t", command: true),
        .newWorkspace: StoredShortcut(key: "n", command: true),
        .newWorkspaceGroup: StoredShortcut(key: "n", command: true, shift: true),
        .commandPalette: StoredShortcut(key: "p", command: true, shift: true),
        .toggleSidebar: StoredShortcut(key: "b", command: true, option: true),
        .toggleInspector: StoredShortcut(key: "i", command: true, option: true),
        .splitRight: StoredShortcut(key: "d", command: true),
        .splitDown: StoredShortcut(key: "d", command: true, shift: true),
        .previousPane: StoredShortcut(key: "left", command: true, option: true),
        .nextPane: StoredShortcut(key: "right", command: true, option: true),
        .closeTab: StoredShortcut(key: "w", command: true),
        .previousTab: StoredShortcut(key: "[", command: true, shift: true),
        .nextTab: StoredShortcut(key: "]", command: true, shift: true),
        .focusTerminal: StoredShortcut(key: "t", command: true, option: true),
        .killSession: StoredShortcut(key: "w", command: true, shift: true),
    ]

    private static let overrides: [ShortcutAction: StoredShortcut] = loadOverrides()

    private static func loadOverrides() -> [ShortcutAction: StoredShortcut] {
        guard let data = FileManager.default.contents(atPath: settingsFilePath),
              let raw = try? JSONDecoder().decode([String: StoredShortcut].self, from: data)
        else { return [:] }
        var result: [ShortcutAction: StoredShortcut] = [:]
        for (name, shortcut) in raw {
            guard let action = ShortcutAction(rawValue: name) else { continue }
            result[action] = shortcut
        }
        return result
    }

    static func stored(_ action: ShortcutAction) -> StoredShortcut {
        overrides[action] ?? defaults[action]!
    }

    static func keyboardShortcut(_ action: ShortcutAction) -> KeyboardShortcut {
        stored(action).keyboardShortcut ?? defaults[action]!.keyboardShortcut!
    }

    // ⌘1-9 固定切换工作区(cmux selectWorkspaceByNumber)
    static func workspaceDigit(_ event: NSEvent) -> Int? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command,
              let digit = Int(event.charactersIgnoringModifiers ?? ""),
              (1...9).contains(digit)
        else { return nil }
        return digit
    }

    // 终端 NSView 用它判断哪些按键属于应用而不能被终端吃掉
    static func isAppShortcut(_ event: NSEvent) -> Bool {
        if workspaceDigit(event) != nil { return true }
        return ShortcutAction.allCases.contains { stored($0).matches(event) }
    }
}
