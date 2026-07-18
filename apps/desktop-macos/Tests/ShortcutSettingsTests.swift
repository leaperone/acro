import AppKit
import XCTest
@testable import AcroDesktop

final class ShortcutSettingsTests: XCTestCase {
    func testControlTabDefaultsSwitchTabs() throws {
        let next = try XCTUnwrap(ShortcutStore.defaults[.nextTab])
        let previous = try XCTUnwrap(ShortcutStore.defaults[.previousTab])

        XCTAssertTrue(next.matches(keyEvent(modifiers: [.control])))
        XCTAssertTrue(previous.matches(keyEvent(modifiers: [.control, .shift])))
        XCTAssertEqual(next.displayString, "⌃Tab")
        XCTAssertEqual(previous.displayString, "⌃⇧Tab")
    }

    private func keyEvent(modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            isARepeat: false,
            keyCode: 48
        )!
    }
}
