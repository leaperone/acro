import XCTest
@testable import AcroDesktop

final class WorkbenchLayoutStateTests: XCTestCase {
    func testTabAdoptSelectCloseAndSplit() throws {
        var layout = WorkspaceTerminalLayout()

        // adopt 建窗格,后续 adopt 变标签
        layout.adopt("one")
        layout.adopt("two")
        XCTAssertEqual(layout.root?.panes.count, 1)
        XCTAssertEqual(layout.root?.sessionIds, ["one", "two"])
        XCTAssertEqual(layout.focusedSessionId, "two")

        // 已存在的会话 adopt 只切选中
        layout.adopt("one")
        XCTAssertEqual(layout.focusedSessionId, "one")
        XCTAssertEqual(layout.root?.sessionIds, ["one", "two"])

        // 分屏出第二个窗格
        let firstPaneId = layout.focusedPane!.id
        layout.split(fromPane: firstPaneId, direction: .horizontal, newSessionId: "three")
        XCTAssertEqual(layout.root?.panes.count, 2)
        XCTAssertEqual(layout.focusedSessionId, "three")

        // 关标签:窗格空了会被摘除,焦点回退
        layout.removeTab("three")
        XCTAssertEqual(layout.root?.panes.count, 1)
        XCTAssertEqual(layout.focusedSessionId, "one")
    }

    func testMoveTabBetweenPanesAndToSplit() throws {
        var layout = WorkspaceTerminalLayout()
        layout.adopt("one")
        layout.adopt("two")
        let sourcePaneId = layout.focusedPane!.id
        layout.split(fromPane: sourcePaneId, direction: .horizontal, newSessionId: "three")
        let targetPaneId = layout.focusedPane!.id

        // 移动标签到另一窗格的指定位置
        layout.moveTab("one", toPane: targetPaneId, at: 0)
        XCTAssertEqual(layout.root?.pane(withId: targetPaneId)?.sessionIds, ["one", "three"])
        XCTAssertEqual(layout.root?.pane(withId: sourcePaneId)?.sessionIds, ["two"])
        XCTAssertEqual(layout.focusedSessionId, "one")

        // 拖到边缘生成新分屏,新窗格在前半
        layout.moveTabToSplit("three", ofPane: sourcePaneId, direction: .vertical, newPaneFirst: true)
        XCTAssertEqual(layout.root?.panes.count, 3)
        XCTAssertEqual(layout.focusedSessionId, "three")

        // 源窗格因搬空被摘除
        layout.moveTab("two", toPane: layout.focusedPane!.id, at: nil)
        XCTAssertEqual(layout.root?.panes.count, 2)
        XCTAssertEqual(layout.root?.pane(withId: sourcePaneId), nil)
    }

    func testDirectionalPaneNavigation() throws {
        // 左 | (右上 / 右下) 的布局
        var layout = WorkspaceTerminalLayout()
        layout.adopt("left")
        let leftPaneId = layout.focusedPane!.id
        layout.split(fromPane: leftPaneId, direction: .horizontal, newSessionId: "rightTop")
        let rightTopPaneId = layout.focusedPane!.id
        layout.split(fromPane: rightTopPaneId, direction: .vertical, newSessionId: "rightBottom")
        let rightBottomPaneId = layout.focusedPane!.id

        // 从右下:向上 → 右上;向左 → 左
        XCTAssertEqual(layout.paneId(toward: .up), rightTopPaneId)
        XCTAssertEqual(layout.paneId(toward: .left), leftPaneId)
        XCTAssertNil(layout.paneId(toward: .right))
        XCTAssertNil(layout.paneId(toward: .down))

        // 从左:向右 → 投影重叠相同时距离近者;右上/右下与左均全高重叠?
        // 左窗格全高,右上/右下各半高,重叠各为自身高度,取重叠更大者之一(相等取先者)
        layout.focusedPaneId = leftPaneId
        let right = layout.paneId(toward: .right)
        XCTAssertTrue(right == rightTopPaneId || right == rightBottomPaneId)

        // 从右上:向下 → 右下
        layout.focusedPaneId = rightTopPaneId
        XCTAssertEqual(layout.paneId(toward: .down), rightBottomPaneId)
    }

    func testSamePaneReorder() throws {
        var layout = WorkspaceTerminalLayout()
        layout.adopt("a")
        layout.adopt("b")
        layout.adopt("c")
        let paneId = layout.focusedPane!.id

        // 向后拖:a 落到 c 的插入指示器处(index 2),应插到 c 前面
        layout.moveTab("a", toPane: paneId, at: 2)
        XCTAssertEqual(layout.root?.pane(withId: paneId)?.sessionIds, ["b", "a", "c"])

        // 向前拖:c 落到 b 的位置(index 0),插到 b 前面
        layout.moveTab("c", toPane: paneId, at: 0)
        XCTAssertEqual(layout.root?.pane(withId: paneId)?.sessionIds, ["c", "b", "a"])

        // 落回本窗格空白处(index nil):不改顺序,只选中
        layout.selectTab("b", inPane: paneId)
        layout.moveTab("c", toPane: paneId, at: nil)
        XCTAssertEqual(layout.root?.pane(withId: paneId)?.sessionIds, ["c", "b", "a"])
        XCTAssertEqual(layout.focusedSessionId, "c")
    }

    func testPruneAndRoundTrip() throws {
        var layout = WorkspaceTerminalLayout()
        layout.adopt("one")
        layout.adopt("two")
        layout.split(fromPane: layout.focusedPane!.id, direction: .vertical, newSessionId: "three")

        // 失效会话被剪掉,空窗格塌缩,焦点自愈
        layout.prune(validSessionIds: ["one", "two"])
        XCTAssertEqual(layout.root?.panes.count, 1)
        XCTAssertEqual(layout.root?.sessionIds, ["one", "two"])
        XCTAssertNotNil(layout.focusedSessionId)

        let snapshot = WorkbenchLayoutSnapshot(
            selectedWorkspaceId: "workspace",
            workspaceLayouts: ["workspace": layout],
            leftSidebarVisible: true,
            inspectorVisible: false
        )
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(WorkbenchLayoutSnapshot.self, from: data), snapshot)
    }
}
