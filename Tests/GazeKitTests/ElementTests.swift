import Testing
@testable import GazeKit

/// In-memory accessibility tree for walker tests.
final class FakeNode: ElementNode {
    let snap: NodeSnapshot?
    var kids: [FakeNode]
    var visibleKids: [FakeNode]?
    var acts: [String]
    var snapshotCalls = 0
    nonisolated(unsafe) static var nextID: UInt64 = 1

    init(_ role: String, _ frame: Rect2?, subrole: String? = nil, hidden: Bool = false, selected: Bool = false,
         actions: [String] = [], kids: [FakeNode] = [], visibleKids: [FakeNode]? = nil, answers: Bool = true) {
        FakeNode.nextID += 1
        snap = answers ? NodeSnapshot(role: role, subrole: subrole, frame: frame, title: role,
                                      identity: FakeNode.nextID, isHidden: hidden, isSelected: selected) : nil
        self.kids = kids
        self.visibleKids = visibleKids
        acts = actions
    }

    func snapshot() -> NodeSnapshot? { snapshotCalls += 1; return snap }
    func children(visibleOnly: Bool) -> [FakeNode] { visibleOnly ? (visibleKids ?? kids) : kids }
    func actions() -> [String] { acts }
}

func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Rect2 { Rect2(x: x, y: y, width: w, height: h) }
let screen = r(0, 0, 1000, 800)

@Suite struct TreeWalkerTests {
    func walk(_ root: FakeNode, source: ElementSource = .window, limits: WalkLimits = WalkLimits()) -> WalkResult {
        TreeWalker.walk(roots: [(root, source)], pid: 42, clip: screen, limits: limits)
    }

    @Test func keepsInteractiveRolesAndSkipsLabels() {
        let window = FakeNode("AXWindow", r(100, 100, 400, 300), kids: [
            FakeNode("AXButton", r(110, 110, 80, 24)),
            FakeNode("AXStaticText", r(110, 140, 80, 20)),
            FakeNode("AXGroup", nil, kids: [
                FakeNode("AXTextField", r(110, 170, 200, 24)),
                FakeNode("AXRadioButton", r(110, 200, 60, 24), subrole: "AXTabButton"),
                FakeNode("AXImage", r(300, 200, 32, 32), actions: ["AXPress"]),
                FakeNode("AXImage", r(340, 200, 32, 32)),
            ]),
        ])
        let kinds = walk(window).elements.map(\.kind)
        #expect(kinds == [.button, .textField, .tab, .pressable])
    }

    @Test func clipsToWindowAndScrollAreaAndPrunesOffscreenSubtrees() {
        let hiddenSubtreeChild = FakeNode("AXButton", r(120, 900, 50, 20))
        let scroll = FakeNode("AXScrollArea", r(100, 100, 300, 200), kids: [
            FakeNode("AXButton", r(110, 110, 50, 20)),          // inside
            FakeNode("AXButton", r(380, 110, 50, 20)),          // straddles the right edge → clipped
            FakeNode("AXButton", r(110, 500, 50, 20)),          // scrolled out of view
            FakeNode("AXGroup", r(100, 850, 300, 100), kids: [hiddenSubtreeChild]),
        ])
        let window = FakeNode("AXWindow", r(100, 100, 600, 600), kids: [scroll])
        let res = walk(window)
        #expect(res.elements.map(\.frame) == [r(110, 110, 50, 20), r(380, 110, 20, 20)])
        #expect(hiddenSubtreeChild.snapshotCalls == 0)
    }

    @Test func dropsTinyHiddenAndUnansweringNodes() {
        let window = FakeNode("AXWindow", r(0, 0, 500, 500), kids: [
            FakeNode("AXButton", r(10, 10, 3, 30)),
            FakeNode("AXButton", r(10, 50, 40, 30), hidden: true),
            FakeNode("AXButton", r(10, 90, 40, 30), answers: false),
            FakeNode("AXButton", r(10, 130, 40, 30)),
        ])
        #expect(walk(window).elements.count == 1)
    }

    @Test func usesVisibleRowsForTables() {
        let rows = (0..<1000).map { FakeNode("AXRow", r(0, Double($0) * 20, 400, 20)) }
        let table = FakeNode("AXTable", r(0, 0, 400, 200), kids: rows, visibleKids: Array(rows.prefix(10)))
        let res = walk(FakeNode("AXWindow", r(0, 0, 400, 200), kids: [table]))
        #expect(res.elements.count == 10)
        #expect(res.visitedNodes == 12)
    }

    @Test func doesNotDescendIntoTextOrImages() {
        let inlineBox = FakeNode("AXButton", r(10, 10, 50, 20))
        let window = FakeNode("AXWindow", r(0, 0, 500, 500), kids: [
            FakeNode("AXStaticText", r(10, 10, 100, 20), actions: ["AXPress"], kids: [inlineBox]),
            FakeNode("AXImage", r(10, 40, 32, 32), actions: ["AXPress"], kids: [FakeNode("AXButton", r(10, 40, 20, 20))]),
        ])
        let res = walk(window)
        #expect(res.elements.map(\.kind) == [.pressable])  // the pressable image itself, not its children
        #expect(inlineBox.snapshotCalls == 0)
    }

    @Test func textFieldsInsideRowsAreLabelsNotTargets() {
        let row = FakeNode("AXRow", r(0, 0, 400, 20), kids: [
            FakeNode("AXCell", r(0, 0, 400, 20), kids: [FakeNode("AXTextField", r(20, 0, 100, 20))]),
        ])
        let form = FakeNode("AXTextField", r(0, 100, 200, 24))
        let res = walk(FakeNode("AXWindow", r(0, 0, 500, 500), kids: [row, form]))
        #expect(res.elements.map(\.kind) == [.row, .textField])
        #expect(res.elements.last?.frame.y == 100)
    }

    @Test func nativeListGroupsAreItemsButWebListGroupsAreNot() {
        let finderList = FakeNode("AXList", r(0, 0, 300, 100), kids: [
            FakeNode("AXGroup", r(10, 0, 200, 27), kids: [FakeNode("AXTextField", r(30, 3, 60, 21))]),
        ])
        let webList = FakeNode("AXList", r(0, 200, 300, 100), subrole: "AXContentList", kids: [
            FakeNode("AXGroup", r(10, 200, 200, 30), kids: [FakeNode("AXLink", r(10, 200, 200, 30))]),
        ])
        let res = walk(FakeNode("AXWindow", r(0, 0, 500, 500), kids: [finderList, webList]))
        #expect(res.elements.map(\.kind) == [.cell, .link])
    }

    @Test func walksOpenMenusOnly() {
        let closed = FakeNode("AXMenuBarItem", r(10, 0, 40, 24), kids: [
            FakeNode("AXMenu", r(10, 24, 200, 300), kids: [FakeNode("AXMenuItem", r(10, 30, 200, 20))]),
        ])
        let open = FakeNode("AXMenuBarItem", r(60, 0, 40, 24), selected: true, kids: [
            FakeNode("AXMenu", r(60, 24, 200, 300), kids: [FakeNode("AXMenuItem", r(60, 30, 200, 20))]),
        ])
        let res = walk(FakeNode("AXMenuBar", r(0, 0, 1000, 24), kids: [closed, open]), source: .menuBar)
        #expect(res.elements.map(\.kind) == [.menuBarItem, .menuBarItem, .menuItem])
    }

    @Test func nodeCapTruncatesBreadthFirst() {
        let window = FakeNode("AXWindow", r(0, 0, 1000, 800),
                              kids: (0..<50).map { FakeNode("AXButton", r(Double($0) * 10, 0, 8, 8)) })
        let res = walk(window, limits: WalkLimits(maxNodes: 21))
        #expect(res.truncated)
        #expect(res.elements.count == 20)
    }

    @Test func menuExtrasBecomeStatusItems() {
        let res = walk(FakeNode("AXMenuBar", r(0, 0, 1000, 24), kids: [FakeNode("AXMenuBarItem", r(900, 0, 24, 24))]),
                       source: .menuExtras)
        #expect(res.elements.map(\.kind) == [.statusItem])
    }
}

@Suite struct OcclusionTests {
    func el(_ frame: Rect2, pid: Int32 = 1, source: ElementSource = .window) -> Element {
        Element(id: 0, kind: .button, frame: frame, pid: pid, source: source)
    }

    @Test func dropsElementsCoveredByAnotherAppsWindow() {
        let windows = [
            WindowInfo(pid: 2, layer: 0, frame: r(0, 0, 300, 300)),   // front: other app
            WindowInfo(pid: 1, layer: 0, frame: r(0, 0, 800, 600)),   // back: our target app
        ]
        let covered = el(r(10, 10, 50, 20))
        let partly = el(r(280, 10, 100, 20))   // mostly outside the covering window
        let visible = el(r(400, 400, 50, 20))
        let out = Occlusion.visibleElements([covered, partly, visible], windows: windows, screens: [screen], ignoringPID: 99)
        var trimmedPartly = partly
        trimmedPartly.frame = r(300, 10, 80, 20)  // the left 20 pt sit under the other app's window
        #expect(out == [trimmedPartly, visible])
    }

    @Test func trimOnlyCutsWhenASideIsFullyCovered() {
        let row = r(100, 100, 400, 40)
        #expect(Occlusion.trim(row, by: r(400, 0, 500, 500)) == r(100, 100, 300, 40))   // right side
        #expect(Occlusion.trim(row, by: r(0, 0, 150, 500)) == r(150, 100, 350, 40))     // left side
        #expect(Occlusion.trim(row, by: r(0, 120, 1000, 500)) == r(100, 100, 400, 20))  // bottom
        #expect(Occlusion.trim(row, by: r(200, 110, 50, 10)) == row)                     // hole: unchanged
        #expect(Occlusion.trim(row, by: r(600, 0, 10, 10)) == row)                       // disjoint
    }

    @Test func ignoresOwnOverlayAndKeepsMenuBarAndDock() {
        let windows = [
            WindowInfo(pid: 99, layer: 1000, frame: screen),           // our overlay
            WindowInfo(pid: 2, layer: 20, frame: r(0, 700, 1000, 100)), // Dock
            WindowInfo(pid: 1, layer: 0, frame: r(0, 0, 1000, 800)),
        ]
        let underOverlay = el(r(10, 10, 50, 20))
        let underDock = el(r(10, 720, 50, 20))
        let dockItem = el(r(10, 720, 50, 50), pid: 2, source: .dock)
        let menu = el(r(10, 0, 30, 24), pid: 3, source: .menuBar)
        let offscreen = el(r(2000, 0, 30, 24), pid: 3, source: .menuExtras)
        let out = Occlusion.visibleElements([underOverlay, underDock, dockItem, menu, offscreen],
                                            windows: windows, screens: [screen], ignoringPID: 99)
        #expect(out == [underOverlay, dockItem, menu])
    }
}

@Suite struct GeometryTests {
    @Test func intersectionAndContainment() {
        #expect(r(0, 0, 10, 10).intersection(r(5, 5, 10, 10)) == r(5, 5, 5, 5))
        #expect(r(0, 0, 10, 10).intersection(r(10, 0, 5, 5)) == nil)
        #expect(r(0, 0, 10, 10).contains(Point2(0, 0)))
        #expect(!r(0, 0, 10, 10).contains(Point2(10, 5)))
        #expect(r(0, 0, 10, 10).union(r(20, 20, 5, 5)) == r(0, 0, 25, 25))
    }

    @Test func topLeftToAppKitAcrossDisplays() {
        // Primary 1440×900. A second display above it has negative top-left y.
        let h = 900.0
        #expect(ScreenSpace.appKitRect(fromTopLeft: r(10, 0, 100, 20), primaryHeight: h) == r(10, 880, 100, 20))
        #expect(ScreenSpace.appKitRect(fromTopLeft: r(0, -1080, 1920, 1080), primaryHeight: h) == r(0, 900, 1920, 1080))
        let round = ScreenSpace.topLeftRect(fromAppKit: ScreenSpace.appKitRect(fromTopLeft: r(5, 6, 7, 8), primaryHeight: h),
                                            primaryHeight: h)
        #expect(round == r(5, 6, 7, 8))
    }
}
