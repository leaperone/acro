import AppKit
import XCTest
@testable import AcroDesktop

final class ShortcutSettingsTests: XCTestCase {
    func testControlTabDefaultsSwitchTabs() throws {
        let next = try XCTUnwrap(ShortcutStore.defaults[.nextTab])
        let previous = try XCTUnwrap(ShortcutStore.defaults[.previousTab])

        XCTAssertTrue(next.matches(keyEvent(modifiers: [.control])))
        XCTAssertTrue(previous.matches(keyEvent(
            modifiers: [.control, .shift], charactersIgnoringModifiers: "\u{19}"
        )))
        XCTAssertEqual(next.displayString, "⌃Tab")
        XCTAssertEqual(previous.displayString, "⌃⇧Tab")
    }

    func testWorkspaceNavigationDefaultsMatchCmux() throws {
        let previous = try XCTUnwrap(ShortcutStore.defaults[.previousWorkspace])
        let next = try XCTUnwrap(ShortcutStore.defaults[.nextWorkspace])

        XCTAssertTrue(previous.matches(keyEvent(
            modifiers: [.command, .control],
            charactersIgnoringModifiers: "*",
            keyCode: 33
        )))
        XCTAssertTrue(next.matches(keyEvent(
            modifiers: [.command, .control],
            charactersIgnoringModifiers: "*",
            keyCode: 30
        )))
    }

    func testRepeatedAppShortcutStaysReserved() {
        let repeatedControlTab = keyEvent(modifiers: [.control], isARepeat: true)

        XCTAssertTrue(repeatedControlTab.isARepeat)
        XCTAssertTrue(ShortcutSettings.isAppShortcut(repeatedControlTab))
    }

    func testNumberedShortcutsUsePhysicalDigitsAndNineMeansLast() {
        let controlTwo = keyEvent(
            modifiers: [.control, .capsLock], charactersIgnoringModifiers: "@", keyCode: 19
        )
        let commandTwo = keyEvent(
            modifiers: [.command], charactersIgnoringModifiers: "@", keyCode: 19
        )

        XCTAssertEqual(ShortcutSettings.tabDigit(controlTwo), 2)
        XCTAssertNil(ShortcutSettings.workspaceDigit(controlTwo))
        XCTAssertEqual(ShortcutSettings.workspaceDigit(commandTwo), 2)
        XCTAssertEqual(NumberedShortcutMapper.index(forDigit: 2, count: 10), 1)
        XCTAssertEqual(NumberedShortcutMapper.index(forDigit: 9, count: 10), 9)
        XCTAssertEqual(NumberedShortcutMapper.digit(forIndex: 9, count: 10), 9)
        XCTAssertNil(NumberedShortcutMapper.digit(forIndex: 8, count: 10))
        XCTAssertEqual(
            ShortcutSettings.reservedShortcutDescription(
                StoredShortcut(key: "5", control: true)
            ),
            "⌃1-9 固定用于切换焦点窗格标签"
        )
    }

    private func keyEvent(
        modifiers: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String = "\t",
        keyCode: UInt16 = 48,
        isARepeat: Bool = false
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: charactersIgnoringModifiers,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: isARepeat,
            keyCode: keyCode
        )!
    }
}
