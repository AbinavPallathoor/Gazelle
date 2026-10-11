import Testing
@testable import GazeKit

private func btn(_ id: UInt64, _ x: Double, _ y: Double, _ w: Double = 80, _ h: Double = 30, pid: Int32 = 1) -> Element {
    Element(id: id, kind: .button, frame: Rect2(x: x, y: y, width: w, height: h), pid: pid, source: .window)
}

@Suite struct SnapScorerTests {
    @Test func insideBoxWinsAndLargeSigmaSpreadsProbability() {
        let items = [btn(1, 0, 0), btn(2, 100, 0), btn(3, 200, 0)]
        let sharp = SnapScorer.rank(gaze: Point2(140, 15), sigma: 20, elements: items)
        #expect(sharp.first?.element.id == 2)
        #expect(sharp.first!.probability > 0.9)
        let blurry = SnapScorer.rank(gaze: Point2(140, 15), sigma: 200, elements: items)
        #expect(blurry.first?.element.id == 2)
        #expect(blurry.first!.probability < 0.5)
    }

    @Test func prefersButtonOverContainingRowAndSameWindow() {
        let row = Element(id: 9, kind: .row, frame: Rect2(x: 0, y: 0, width: 600, height: 40), pid: 1, source: .window)
        let r1 = SnapScorer.rank(gaze: Point2(20, 20), sigma: 40, elements: [row, btn(1, 5, 5, 60, 30)])
        #expect(r1.first?.element.id == 1)
        let other = btn(2, 120, 0, pid: 2)
        let r2 = SnapScorer.rank(gaze: Point2(100, 15), sigma: 40, elements: [btn(1, 0, 0), other], gazedPID: 2)
        #expect(r2.first?.element.id == 2)
    }

    @Test func nothingWithinThreeSigma() {
        #expect(SnapScorer.rank(gaze: Point2(1000, 1000), sigma: 30, elements: [btn(1, 0, 0)]).isEmpty)
    }
}

@Suite struct GazeSelectorTests {
    var rng = SplitMix64(seed: 21)

    @Test mutating func noFlickerBetweenNeighboursUnderNoise() {
        // Two adjacent buttons; gaze noise straddles the boundary but mostly sits on button 1.
        let items = [btn(1, 0, 0, 100, 40), btn(2, 100, 0, 100, 40)]
        var sel = GazeSelector()
        var changes = 0
        var t = 0.0
        for _ in 0..<300 {
            t += 1 / 30
            let g = Point2(80 + rng.uniform(-30, 30), 20 + rng.uniform(-10, 10))
            if sel.update(gaze: g, fixating: true, sigma: 40, elements: items, at: t) != nil { changes += 1 }
        }
        #expect(sel.selectedID == 1)
        #expect(changes == 1)   // the initial pick only
    }

    @Test func movesAfterSustainedFixationOnAnotherElement() {
        let items = [btn(1, 0, 0), btn(2, 400, 0)]
        var sel = GazeSelector()
        var t = 0.0
        for _ in 0..<10 { t += 1 / 30; sel.update(gaze: Point2(40, 15), fixating: true, sigma: 40, elements: items, at: t) }
        #expect(sel.selectedID == 1)
        // A saccade sample (not fixating) never switches.
        t += 1 / 30
        #expect(sel.update(gaze: Point2(440, 15), fixating: false, sigma: 40, elements: items, at: t) == nil)
        var switchedAt: Double?
        for _ in 0..<15 {
            t += 1 / 30
            if sel.update(gaze: Point2(440, 15), fixating: true, sigma: 40, elements: items, at: t) != nil { switchedAt = t }
        }
        #expect(sel.selectedID == 2)
        #expect(switchedAt != nil)
    }

    @Test func runnerUpReportedWhenClose() {
        let items = [btn(1, 0, 0, 100, 40), btn(2, 104, 0, 100, 40)]
        var sel = GazeSelector()
        _ = sel.update(gaze: Point2(101, 20), fixating: true, sigma: 60, elements: items, at: 0)
        #expect(sel.runnerUp != nil)
    }
}

@Suite struct EngagementStateTests {
    let locked = Rect2(x: 0, y: 0, width: 80, height: 30)

    @Test func keyLocksAndIdleReleases() {
        var s = EngagementState()
        s.keyPressed(at: 0)
        #expect(!s.gazeDrives)
        s.gaze(Point2(40, 15), fixating: true, sigma: 40, lockedFrame: locked, at: 1.0)
        #expect(!s.gazeDrives)
        s.gaze(Point2(40, 15), fixating: true, sigma: 40, lockedFrame: locked, at: 2.1)
        #expect(s.gazeDrives)
    }

    @Test func deliberateLookAwayReleasesButSmallOrBriefDoesNot() {
        var s = EngagementState()
        s.keyPressed(at: 0)
        // Close by: no release.
        for i in 0..<20 { s.gaze(Point2(120, 15), fixating: true, sigma: 40, lockedFrame: locked, at: 0.1 + Double(i) * 0.03) }
        #expect(!s.gazeDrives)
        // Far but only one frame, then back: no release.
        s.gaze(Point2(900, 500), fixating: true, sigma: 40, lockedFrame: locked, at: 0.8)
        s.gaze(Point2(40, 15), fixating: true, sigma: 40, lockedFrame: locked, at: 0.83)
        #expect(!s.gazeDrives)
        // Far and held: release.
        var t = 0.9
        while t < 1.4 { s.gaze(Point2(900, 500), fixating: true, sigma: 40, lockedFrame: locked, at: t); t += 0.033 }
        #expect(s.gazeDrives)
    }

    @Test func anotherKeyRelocks() {
        var s = EngagementState()
        s.keyPressed(at: 0)
        s.gaze(Point2(0, 0), fixating: false, sigma: 40, lockedFrame: locked, at: 3)
        #expect(s.gazeDrives)
        s.keyPressed(at: 3.1)
        #expect(!s.gazeDrives)
    }
}
