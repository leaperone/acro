import AppKit
import XCTest
@testable import AcroDesktop

final class TerminalFileDropTests: XCTestCase {
    func testEscapesAndSeparatesPaths() {
        let urls = [
            URL(fileURLWithPath: "/tmp/Acro Drop/photo's draft.png"),
            URL(fileURLWithPath: "/tmp/report[1].pdf"),
        ]

        XCTAssertEqual(
            TerminalFileDrop.insertedText(for: urls),
            "/tmp/Acro\\ Drop/photo\\'s\\ draft.png /tmp/report\\[1\\].pdf"
        )
    }

    func testReadsAndDeduplicatesModernAndLegacyURLs() {
        let first = URL(fileURLWithPath: "/tmp/Acro Drop/image.png").standardizedFileURL
        let second = URL(fileURLWithPath: "/tmp/Acro Drop/document.pdf").standardizedFileURL
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("acro-terminal-file-drop-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        pasteboard.writeObjects([first as NSURL])
        pasteboard.setPropertyList(
            [first.path, second.path],
            forType: TerminalFileDrop.legacyFilenamesPasteboardType
        )

        XCTAssertTrue(TerminalFileDrop.canReadFileURLs(from: pasteboard))
        XCTAssertEqual(
            TerminalFileDrop.fileURLs(from: pasteboard).map(\.path),
            [first.path, second.path]
        )
    }

    func testRejectsNonFileURLsAndDoesNotAppendNewline() {
        XCTAssertEqual(
            TerminalFileDrop.insertedText(for: [URL(string: "https://example.com/image.png")!]),
            ""
        )
        XCTAssertEqual(
            TerminalFileDrop.insertedText(for: [URL(fileURLWithPath: "/tmp/image.png")]),
            "/tmp/image.png"
        )
    }

    func testRejectsControlCharactersBeforeTheyReachTerminalInput() {
        let unsafePaths = [
            "/tmp/line\nbreak",
            "/tmp/line\r\nbreak",
            "/tmp/escape-\u{1B}-key",
            "/tmp/control-o-\u{0F}-key",
            "/tmp/delete-\u{7F}-key",
        ]

        for path in unsafePaths {
            XCTAssertEqual(
                TerminalFileDrop.insertedText(for: [URL(fileURLWithPath: path)]),
                "",
                "Expected unsafe terminal control in path to reject the entire drop"
            )
        }
    }
}
