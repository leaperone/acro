// 可配置快捷键。范式取自 cmux 的 KeyboardShortcutSettings
// (GPL-3.0-or-later, Copyright (c) 2024-present Manaflow, Inc.):
// Action 全枚举 + 默认表 + 用户配置文件覆写,一处定义、菜单/终端拦截/设置窗口共用。
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
        case "\t": .tab
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
        case "\t": "Tab"
        default: key.uppercased()
        }
        return parts + keyLabel
    }

    var hasModifier: Bool { command || option || control }

    func matches(_ event: NSEvent) -> Bool {
        let flags = Self.normalizedModifiers(event)
        var expected: NSEvent.ModifierFlags = []
        if command { expected.insert(.command) }
        if shift { expected.insert(.shift) }
        if option { expected.insert(.option) }
        if control { expected.insert(.control) }
        guard flags == expected else { return false }
        return Self.eventKey(event) == key
    }

    static func eventKey(_ event: NSEvent) -> String {
        switch event.keyCode {
        case 48: "\t"
        case 18: "1"
        case 19: "2"
        case 20: "3"
        case 21: "4"
        case 23: "5"
        case 22: "6"
        case 26: "7"
        case 28: "8"
        case 25: "9"
        case 33: "["
        case 30: "]"
        case 123: "left"
        case 124: "right"
        case 125: "down"
        case 126: "up"
        default: (event.charactersIgnoringModifiers ?? "").lowercased()
        }
    }

    static func from(_ event: NSEvent) -> StoredShortcut {
        let flags = normalizedModifiers(event)
        return StoredShortcut(
            key: eventKey(event),
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control)
        )
    }

    static func normalizedModifiers(_ event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
    }
}

enum ShortcutAction: String, CaseIterable, Identifiable {
    case newTerminalTab
    case newWorkspace
    case newWorkspaceGroup
    case commandPalette
    case toggleSidebar
    case toggleInspector
    case splitRight
    case splitDown
    case equalizeSplits
    case focusPaneLeft
    case focusPaneDown
    case focusPaneUp
    case focusPaneRight
    case closeTab
    case previousTab
    case nextTab
    case previousWorkspace
    case nextWorkspace
    case focusTerminal
    case openSettings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newTerminalTab: "新建标签"
        case .newWorkspace: "新建工作区"
        case .newWorkspaceGroup: "新建分组"
        case .commandPalette: "命令面板"
        case .toggleSidebar: "显示 / 隐藏左侧栏"
        case .toggleInspector: "显示 / 隐藏右侧栏"
        case .splitRight: "向右分屏"
        case .splitDown: "向下分屏"
        case .equalizeSplits: "均分窗格"
        case .focusPaneLeft: "聚焦左侧窗格"
        case .focusPaneDown: "聚焦下方窗格"
        case .focusPaneUp: "聚焦上方窗格"
        case .focusPaneRight: "聚焦右侧窗格"
        case .closeTab: "关闭标签(终止终端)"
        case .previousTab: "上一个标签"
        case .nextTab: "下一个标签"
        case .previousWorkspace: "上一个工作区"
        case .nextWorkspace: "下一个工作区"
        case .focusTerminal: "聚焦终端"
        case .openSettings: "打开设置"
        }
    }
}

// 覆写的运行时真源。设置窗口写这里,落盘到 keybindings.json;
// 菜单快捷键在下次启动生效,终端拦截与提示即时生效。
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    @Published private(set) var overrides: [ShortcutAction: StoredShortcut]

    static let settingsFilePath = "\(NSHomeDirectory())/.config/acro/keybindings.json"

    static let defaults: [ShortcutAction: StoredShortcut] = [
        .newTerminalTab: StoredShortcut(key: "t", command: true),
        .newWorkspace: StoredShortcut(key: "n", command: true),
        .newWorkspaceGroup: StoredShortcut(key: "n", command: true, shift: true),
        .commandPalette: StoredShortcut(key: "p", command: true, shift: true),
        .toggleSidebar: StoredShortcut(key: "b", command: true),
        .toggleInspector: StoredShortcut(key: "l", command: true),
        .splitRight: StoredShortcut(key: "d", command: true),
        .splitDown: StoredShortcut(key: "d", command: true, shift: true),
        .equalizeSplits: StoredShortcut(key: "=", command: true, option: true),
        .focusPaneLeft: StoredShortcut(key: "h", command: true, shift: true),
        .focusPaneDown: StoredShortcut(key: "j", command: true, shift: true),
        .focusPaneUp: StoredShortcut(key: "k", command: true, shift: true),
        .focusPaneRight: StoredShortcut(key: "l", command: true, shift: true),
        .closeTab: StoredShortcut(key: "w", command: true),
        .previousTab: StoredShortcut(key: "\t", shift: true, control: true),
        .nextTab: StoredShortcut(key: "\t", control: true),
        .previousWorkspace: StoredShortcut(key: "[", command: true, control: true),
        .nextWorkspace: StoredShortcut(key: "]", command: true, control: true),
        .focusTerminal: StoredShortcut(key: "t", command: true, option: true),
        .openSettings: StoredShortcut(key: ",", command: true),
    ]

    private init() {
        overrides = Self.loadOverrides()
    }

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

    func stored(_ action: ShortcutAction) -> StoredShortcut {
        overrides[action] ?? Self.defaults[action]!
    }

    func isOverridden(_ action: ShortcutAction) -> Bool {
        overrides[action] != nil
    }

    // 与其他 action 的当前绑定冲突时返回冲突方(cmux ShortcutRecordingRejection.conflictsWithAction)
    func conflict(of shortcut: StoredShortcut, excluding action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != action && stored($0) == shortcut }
    }

    func set(_ shortcut: StoredShortcut, for action: ShortcutAction) {
        overrides[action] = shortcut == Self.defaults[action] ? nil : shortcut
        persist()
    }

    func reset(_ action: ShortcutAction) {
        overrides.removeValue(forKey: action)
        persist()
    }

    private func persist() {
        let raw = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(raw) else { return }
        let directory = (Self.settingsFilePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        try? data.write(to: URL(fileURLWithPath: Self.settingsFilePath))
    }
}

enum NumberedShortcutMapper {
    static func index(forDigit digit: Int, count: Int) -> Int? {
        guard count > 0, (1...9).contains(digit) else { return nil }
        if digit == 9 { return count - 1 }
        let index = digit - 1
        return index < count ? index : nil
    }

    static func digit(forIndex index: Int, count: Int) -> Int? {
        guard (0..<count).contains(index) else { return nil }
        return (1...9).first { self.index(forDigit: $0, count: count) == index }
    }
}

// 旧调用点的静态门面
enum ShortcutSettings {
    static func stored(_ action: ShortcutAction) -> StoredShortcut {
        ShortcutStore.shared.stored(action)
    }

    static func keyboardShortcut(_ action: ShortcutAction) -> KeyboardShortcut {
        stored(action).keyboardShortcut ?? ShortcutStore.defaults[action]!.keyboardShortcut!
    }

    // 数字族沿用 cmux 语义:1...8 固定位置,9 永远是最后一个。
    static func workspaceDigit(_ event: NSEvent) -> Int? {
        numberedDigit(event, modifiers: .command)
    }

    static func tabDigit(_ event: NSEvent) -> Int? {
        numberedDigit(event, modifiers: .control)
    }

    static func reservedShortcutDescription(_ shortcut: StoredShortcut) -> String? {
        if shortcut == StoredShortcut(key: "q", command: true) {
            return "⌘Q 固定用于退出 Acro"
        }
        guard let digit = Int(shortcut.key), (1...9).contains(digit),
              !shortcut.shift, !shortcut.option else { return nil }
        if shortcut.command && !shortcut.control { return "⌘1-9 固定用于切换工作区" }
        if shortcut.control && !shortcut.command { return "⌃1-9 固定用于切换焦点窗格标签" }
        return nil
    }

    // 终端 NSView 用它判断哪些按键属于应用而不能被终端吃掉
    static func isAppShortcut(_ event: NSEvent) -> Bool {
        if isSystemShortcut(event) { return true }
        if workspaceDigit(event) != nil || tabDigit(event) != nil { return true }
        return ShortcutAction.allCases.contains { stored($0).matches(event) }
    }

    // 事件 → 命中的 action(cmux AppDelegate 路由模式的 acro 版)
    static func action(for event: NSEvent) -> ShortcutAction? {
        if isSystemShortcut(event) { return nil }
        return ShortcutAction.allCases.first { stored($0).matches(event) }
    }

    private static func isSystemShortcut(_ event: NSEvent) -> Bool {
        StoredShortcut(key: "q", command: true).matches(event)
    }

    private static func numberedDigit(
        _ event: NSEvent,
        modifiers: NSEvent.ModifierFlags
    ) -> Int? {
        guard StoredShortcut.normalizedModifiers(event) == modifiers,
              let digit = Int(StoredShortcut.eventKey(event)),
              (1...9).contains(digit)
        else { return nil }
        return digit
    }
}
