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

    func testEqualizeSplitsDefaultMatchesCmux() throws {
        let shortcut = try XCTUnwrap(ShortcutStore.defaults[.equalizeSplits])

        XCTAssertTrue(shortcut.matches(keyEvent(
            modifiers: [.command, .control],
            charactersIgnoringModifiers: "=",
            keyCode: 24
        )))
        XCTAssertEqual(shortcut.displayString, "⌃⌘=")
    }

    func testRepeatedAppShortcutStaysReserved() {
        let repeatedControlTab = keyEvent(modifiers: [.control], isARepeat: true)

        XCTAssertTrue(repeatedControlTab.isARepeat)
        XCTAssertTrue(ShortcutSettings.isAppShortcut(repeatedControlTab))
    }

    func testPresentationAwareRoutingPreventsShortcutPassthrough() {
        let commandT = keyEvent(
            modifiers: [.command], charactersIgnoringModifiers: "t", keyCode: 17
        )
        let repeatedCommandT = keyEvent(
            modifiers: [.command], charactersIgnoringModifiers: "t", keyCode: 17,
            isARepeat: true
        )
        let commandW = keyEvent(
            modifiers: [.command], charactersIgnoringModifiers: "w", keyCode: 13
        )
        let commandOne = keyEvent(
            modifiers: [.command], charactersIgnoringModifiers: "1", keyCode: 18
        )
        let controlOne = keyEvent(
            modifiers: [.control], charactersIgnoringModifiers: "1", keyCode: 18
        )
        let plainA = keyEvent(modifiers: [], charactersIgnoringModifiers: "a", keyCode: 0)

        XCTAssertEqual(
            ShortcutSettings.routingDecision(for: commandT, presentation: .normal),
            .routeApp
        )
        XCTAssertEqual(
            ShortcutSettings.routingDecision(for: repeatedCommandT, presentation: .normal),
            .consumeWithoutAction
        )
        for event in [commandW, commandOne, controlOne] {
            XCTAssertEqual(
                ShortcutSettings.routingDecision(for: event, presentation: .commandPalette),
                .consumeWithoutAction
            )
        }
        XCTAssertEqual(
            ShortcutSettings.routingDecision(for: plainA, presentation: .commandPalette),
            .passToSystem
        )
        XCTAssertEqual(
            ShortcutSettings.routingDecision(for: commandW, presentation: .systemPresentation),
            .passToSystem
        )
    }

    func testCommandPaletteEditingEquivalentsStayWithTheTextField() {
        for (key, keyCode, flags) in [
            ("a", UInt16(0), NSEvent.ModifierFlags.command),
            ("c", UInt16(8), .command),
            ("v", UInt16(9), .command),
            ("x", UInt16(7), .command),
            ("z", UInt16(6), .command),
            ("z", UInt16(6), [.command, .shift]),
        ] {
            XCTAssertTrue(ShortcutSettings.isCommandPaletteEditingEquivalent(keyEvent(
                modifiers: flags,
                charactersIgnoringModifiers: key,
                keyCode: keyCode
            )))
        }
    }

    @MainActor
    func testSystemWindowsDeferShortcutsToAppKit() {
        let normalWindow = NSWindow()
        let settingsWindow = NSWindow()
        settingsWindow.title = AcroAppDelegate.settingsWindowTitle
        let panel = NSPanel()
        let sheetParent = NSWindow()
        let sheet = NSWindow()
        sheetParent.beginSheet(sheet)
        defer { sheetParent.endSheet(sheet) }

        XCTAssertFalse(AcroAppDelegate.hasSystemShortcutPresentation(
            eventWindow: normalWindow,
            keyWindow: normalWindow,
            modalWindow: nil
        ))
        XCTAssertTrue(AcroAppDelegate.hasSystemShortcutPresentation(
            eventWindow: settingsWindow,
            keyWindow: settingsWindow,
            modalWindow: nil
        ))
        XCTAssertTrue(AcroAppDelegate.hasSystemShortcutPresentation(
            eventWindow: panel,
            keyWindow: panel,
            modalWindow: nil
        ))
        XCTAssertTrue(AcroAppDelegate.hasSystemShortcutPresentation(
            eventWindow: normalWindow,
            keyWindow: normalWindow,
            modalWindow: NSWindow()
        ))
        XCTAssertTrue(AcroAppDelegate.hasSystemShortcutPresentation(
            eventWindow: sheetParent,
            keyWindow: sheetParent,
            modalWindow: nil
        ))
        XCTAssertTrue(AcroAppDelegate.hasSystemShortcutPresentation(
            eventWindow: sheet,
            keyWindow: sheet,
            modalWindow: nil
        ))
    }

    @MainActor
    func testModelRejectsMenuActionsWhileAPresentationIsActive() {
        let model = WorkbenchModel(hub: RuntimeHub())
        let initialInspectorVisibility = model.inspectorVisible

        model.showingCommandPalette = true
        model.perform(.toggleInspector)
        XCTAssertEqual(model.inspectorVisible, initialInspectorVisibility)

        model.showingCommandPalette = false
        model.showingWorkspaceEditor = true
        model.perform(.toggleInspector)
        XCTAssertEqual(model.inspectorVisible, initialInspectorVisibility)

        model.showingWorkspaceEditor = false
        model.perform(.toggleInspector)
        XCTAssertEqual(model.inspectorVisible, !initialInspectorVisibility)
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
