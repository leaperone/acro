import XCTest
@testable import AcroDesktop

// Acro 的 ghostty 叠加层配置行生成:字体覆盖语义 + CJK 回退。
final class TerminalAppearanceTests: XCTestCase {
    // 用户没在 Acro 选字体:不重置基底,主字体兜到 Menlo,让原生 ghostty config 的字体仍能作主字体。
    func testEmptyFontDoesNotResetBaseChain() {
        let lines = TerminalAppearance.confLines(fontFamily: "", fontSize: 0, theme: "")
        XCTAssertFalse(lines.contains(#"font-family = """#), "空字体不应 reset,否则会清掉用户原生 config 的字体")
        XCTAssertTrue(lines.contains("font-family = Menlo"))
        // CJK 回退在最后,主字体在前
        XCTAssertTrue(lines.contains("font-family = PingFang SC"))
        XCTAssertLessThan(
            lines.firstIndex(of: "font-family = Menlo")!,
            lines.firstIndex(of: "font-family = PingFang SC")!
        )
    }

    // 用户在 Acro 选了字体:先 reset 再设,覆盖原生 config 的字体;所选字体排在 CJK 回退之前。
    func testExplicitFontResetsBaseThenOverrides() {
        let lines = TerminalAppearance.confLines(fontFamily: "Fira Code", fontSize: 14, theme: "")
        let resetIdx = lines.firstIndex(of: #"font-family = """#)
        let famIdx = lines.firstIndex(of: "font-family = Fira Code")
        let cjkIdx = lines.firstIndex(of: "font-family = Hiragino Sans GB")
        XCTAssertNotNil(resetIdx, "选了字体应先用空串 reset 基底")
        XCTAssertNotNil(famIdx)
        XCTAssertLessThan(resetIdx!, famIdx!, "reset 必须在所选字体之前")
        XCTAssertLessThan(famIdx!, cjkIdx!, "所选主字体必须排在 CJK 回退之前")
        XCTAssertFalse(lines.contains("font-family = Menlo"), "选了字体就不再兜 Menlo")
        XCTAssertTrue(lines.contains("font-size = 14"))
    }

    // 字号/主题为默认(0 / 空)时不写行,交给原生 config 或 ghostty 默认。
    func testDefaultSizeAndThemeAreOmitted() {
        let lines = TerminalAppearance.confLines(fontFamily: "", fontSize: 0, theme: "")
        XCTAssertFalse(lines.contains { $0.hasPrefix("font-size") })
        XCTAssertFalse(lines.contains { $0.hasPrefix("theme") })
    }
}
