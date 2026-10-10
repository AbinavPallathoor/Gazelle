import Testing
@testable import GazeKit

private func e(_ id: UInt64, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ kind: ElementKind = .button) -> Element {
    Element(id: id, kind: kind, frame: Rect2(x: x, y: y, width: w, height: h), pid: 1, source: .window)
}

/// 3×3 grid of 80×30 buttons with 20 pt gaps; ids are row*10 + column.
private let grid: [Element] = (0..<3).flatMap { r in
    (0..<3).map { c in e(UInt64(r * 10 + c), Double(c) * 100, Double(r) * 50, 80, 30) }
}

private func move(_ from: UInt64, _ d: Direction, _ items: [Element]) -> UInt64? {
    let cur = items.first { $0.id == from }!
    return SpatialNavigator.move(from: cur.frame, d, among: items, excluding: from)?.id
}

@Suite struct SpatialNavigationTests {
    @Test func gridMovesToAdjacentCells() {
        #expect(move(11, .right, grid) == 12)
        #expect(move(11, .left, grid) == 10)
        #expect(move(11, .up, grid) == 1)
        #expect(move(11, .down, grid) == 21)
    }

    @Test func edgesOfGridStayPut() {
        #expect(move(0, .left, grid) == nil)
        #expect(move(0, .up, grid) == nil)
        #expect(move(22, .right, grid) == nil)
        #expect(move(22, .down, grid) == nil)
    }

    @Test func raggedRowsPickTheOverlappingNeighbour() {
        // Row 1: three wide buttons. Row 2: four narrow ones, offset.
        let items = [
            e(1, 0, 0, 150, 30), e(2, 160, 0, 150, 30), e(3, 320, 0, 150, 30),
            e(11, 10, 60, 90, 30), e(12, 120, 60, 90, 30), e(13, 230, 60, 90, 30), e(14, 340, 60, 120, 30),
        ]
        #expect(move(3, .down, items) == 14)
        #expect(move(2, .down, items) == 13)   // most horizontal overlap / nearest centre
        #expect(move(12, .up, items) == 2)     // overlaps 2 by 50 pt, 1 by 30 pt
        #expect(move(14, .up, items) == 3)
    }

    @Test func doesNotJumpDiagonallyFarOffAxis() {
        // A toolbar on top and content far below and to the right: moving right from the last
        // toolbar button must not drop into content outside the cone.
        let items = [e(1, 0, 0, 30, 30), e(2, 40, 0, 30, 30), e(3, 100, 400, 200, 30)]
        #expect(move(2, .right, items) == nil)
        #expect(move(2, .down, items) == 3)
    }

    @Test func prefersAlignedOverCloserButOffAxis() {
        let items = [e(1, 0, 100, 50, 30), e(2, 300, 100, 50, 30), e(3, 80, 160, 50, 30)]
        #expect(move(1, .right, items) == 2)
    }

    @Test func containerAroundCurrentNeverWins() {
        // A row containing two buttons; moving right from the left button goes to the right button.
        let items = [e(100, 0, 0, 400, 40, .row), e(1, 10, 5, 60, 30), e(2, 300, 5, 60, 30)]
        #expect(move(1, .right, items) == 2)
        #expect(move(2, .left, items) == 1)
    }

    @Test func rightFromListItemDoesNotJumpToToolbar() {
        // Finder: a list item low in the window; a toolbar control up and to the right (~43°).
        let items = [e(1, 182, 900, 206, 27, .cell), e(2, 540, 588, 54, 38, .popUp), e(3, 712, 581, 40, 52)]
        #expect(move(1, .right, items) == nil)
        #expect(move(1, .up, items) == nil)   // too far off-axis for up as well
    }

    @Test func sameColumnDifferentWidthsIsNotSideways() {
        // A list of names left-aligned in one column: right/left find nothing, down goes down.
        let items = [e(1, 200, 0, 50, 20), e(2, 200, 26, 160, 20), e(3, 200, 52, 90, 20)]
        #expect(move(1, .right, items) == nil)
        #expect(move(2, .left, items) == nil)
        #expect(move(1, .down, items) == 2)
    }

    @Test func overlappingSiblingsAreReachable() {
        // Two overlapping boxes (e.g. a badge on an icon).
        let items = [e(1, 0, 0, 40, 40), e(2, 30, 0, 20, 20)]
        #expect(move(1, .right, items) == 2)
        #expect(move(2, .left, items) == 1)
    }
}

@Suite struct ReadingOrderTests {
    @Test func linesTopToBottomThenLeftToRight() {
        let items = [e(3, 200, 2, 50, 20), e(1, 0, 0, 50, 24), e(4, 0, 40, 50, 20), e(2, 100, 4, 50, 20)]
        #expect(SpatialNavigator.readingOrder(items).map(\.id) == [1, 2, 3, 4])
    }

    @Test func stepWrapsAround() {
        #expect(SpatialNavigator.step(from: 22, forward: true, among: grid)?.id == 0)
        #expect(SpatialNavigator.step(from: 0, forward: false, among: grid)?.id == 22)
        #expect(SpatialNavigator.step(from: nil, forward: true, among: grid)?.id == 0)
    }

    @Test func nearestPrefersSmallestContainingBox() {
        let items = [e(100, 0, 0, 400, 40, .row), e(1, 10, 5, 60, 30)]
        #expect(SpatialNavigator.nearest(to: Point2(20, 20), among: items)?.id == 1)
        #expect(SpatialNavigator.nearest(to: Point2(300, 20), among: items)?.id == 100)
    }
}

@Suite struct SelectionModelTests {
    @Test func beginPrefersFocusedThenPointer() {
        var s = SelectionModel()
        s.begin(elements: grid, focusedID: 12, focusedFrame: nil, pointer: Point2(0, 0))
        #expect(s.selected?.id == 12)
        s.begin(elements: grid, focusedID: 999, focusedFrame: nil, pointer: Point2(210, 110))
        #expect(s.selected?.id == 22)
    }

    @Test func followsElementAcrossRefreshAndFallsBackToNearest() {
        var s = SelectionModel()
        s.begin(elements: grid, focusedID: 11, focusedFrame: nil, pointer: nil)
        var moved = grid
        moved[4].frame.x += 5                       // same id, new frame
        s.update(elements: moved)
        #expect(s.selected?.frame.x == 105)
        s.update(elements: grid.filter { $0.id != 11 })
        #expect(s.selected != nil && s.selected?.id != 11)
    }

    @Test func moveAndStep() {
        var s = SelectionModel()
        s.begin(elements: grid, focusedID: 0, focusedFrame: nil, pointer: nil)
        let movedRight = s.move(.right)
        #expect(movedRight)
        #expect(s.selected?.id == 1)
        let movedUp = s.move(.up)
        #expect(!movedUp)
        #expect(s.selected?.id == 1)
        s.step(forward: true)
        #expect(s.selected?.id == 2)
    }
}

@Suite struct KeyMapTests {
    @Test func mapsOnlyTheNavigationKeys() {
        #expect(KeyMap.command(keyCode: KeyMap.leftArrow, modifiers: []) == .move(.left))
        #expect(KeyMap.command(keyCode: KeyMap.tab, modifiers: [.shift]) == .previous)
        #expect(KeyMap.command(keyCode: KeyMap.returnKey, modifiers: [.option]) == .act(.doubleClick))
        #expect(KeyMap.command(keyCode: KeyMap.escape, modifiers: []) == .exit)
        // Modified arrows, letters and shortcuts pass through.
        #expect(KeyMap.command(keyCode: KeyMap.leftArrow, modifiers: [.command]) == nil)
        #expect(KeyMap.command(keyCode: 0, modifiers: []) == nil)
        #expect(KeyMap.command(keyCode: KeyMap.tab, modifiers: [.command]) == nil)
    }

    @Test func killSwitchIsRecognised() {
        #expect(KeyMap.isKillSwitch(keyCode: KeyMap.kKey, modifiers: [.control, .option]))
        #expect(!KeyMap.isKillSwitch(keyCode: KeyMap.kKey, modifiers: [.control]))
    }
}

@Suite struct ActionPlannerTests {
    @Test func pressPrefersAXActionsThenClick() {
        #expect(ActionPlanner.plan(.press, kind: .button, axActions: ["AXShowMenu", "AXPress"])
                == [.ax("AXPress"), .click(right: false, count: 1)])
        #expect(ActionPlanner.plan(.press, kind: .cell, axActions: [])
                == [.click(right: false, count: 1)])
    }

    @Test func textFieldsAreFocusedAndClicked() {
        #expect(ActionPlanner.plan(.press, kind: .textField, axActions: ["AXConfirm"])
                == [.setFocused, .click(right: false, count: 1)])
    }

    @Test func rightClickUsesShowMenuWhenAvailable() {
        #expect(ActionPlanner.plan(.rightClick, kind: .row, axActions: ["AXShowMenu"])
                == [.ax("AXShowMenu"), .click(right: true, count: 1)])
        #expect(ActionPlanner.plan(.rightClick, kind: .row, axActions: []) == [.click(right: true, count: 1)])
        #expect(ActionPlanner.plan(.doubleClick, kind: .cell, axActions: ["AXOpen"]) == [.click(right: false, count: 2)])
        #expect(ActionPlanner.plan(.focus, kind: .button, axActions: []) == [.setFocused, .movePointer])
    }
}
