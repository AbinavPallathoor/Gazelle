import AppKit
import ApplicationServices
import Combine
import GazeKit
import os

private let log = Logger(subsystem: "dev.gazelle.Gazelle", category: "navigation")

/// Keyboard navigation while Active: keeps a `SelectionModel` in sync with the element map,
/// draws the outline, and carries out commands from the keyboard tap.
@MainActor
final class NavigationController {
    /// Called when a command ends Active mode (Esc, or after activating a text field).
    var onExitRequested: ((_ reason: String) -> Void)?

    private let store: ElementStore
    private let outline = OutlineOverlay()
    private let performer = ActionPerformer()
    private var selection = SelectionModel()
    // M6: gaze-driven selection.
    private var selector = GazeSelector()
    private var engagement = EngagementState()
    private var windowCache: (time: Double, windows: [WindowInfo]) = (-1, [])
    /// Gaze error σ in points (from calibration validation; M8 will keep it current).
    var gazeSigma: Double = 80
    /// False while the face is lost: the selection is frozen.
    var faceTracking = true
    private var cancellable: AnyCancellable?
    private(set) var isActive = false
    /// Set when activation happened before the first scan arrived.
    private var awaitingFirstScan = false

    init(store: ElementStore) {
        self.store = store
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            outline.show()
            awaitingFirstScan = true
            cancellable = store.$elements.sink { [weak self] in self?.elementsChanged($0) }
            store.refreshSoon()
        } else {
            cancellable = nil
            selection.clear()
            outline.hide()
            selector = GazeSelector()
            engagement = EngagementState()
        }
    }

    private func elementsChanged(_ elements: [Element]) {
        guard isActive else { return }
        if awaitingFirstScan {
            guard !elements.isEmpty else { return }
            awaitingFirstScan = false
            let focused = Self.focusedElement()
            let pointer = CGEvent(source: nil)?.location
            selection.begin(elements: elements,
                            focusedID: focused.map { UInt64(CFHash($0)) },
                            focusedFrame: focused.flatMap(Self.frame),
                            pointer: pointer.map { Point2(Double($0.x), Double($0.y)) })
            logSelection("begin")
        } else {
            selection.update(elements: elements)
        }
        outline.highlight(selection.selected?.frame)
    }

    private func logSelection(_ what: String) {
        let s = selection.selected
        log.info("\(what, privacy: .public): \(s?.kind.rawValue ?? "none", privacy: .public) \(s?.title ?? "", privacy: .public) at \(s.map { "\(Int($0.frame.x)),\(Int($0.frame.y)) \(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "-", privacy: .public) of \(self.selection.elements.count)")
    }

    /// A filtered gaze sample (global top-left points). Gaze moves the selection only while it
    /// drives (not keyboard-locked), the face is tracked, and a fixation is in progress.
    func gaze(_ p: Point2, fixating: Bool, at t: Double) {
        guard isActive, faceTracking, !selection.elements.isEmpty else { return }
        if !engagement.gazeDrives {
            guard engagement.gaze(p, fixating: fixating, sigma: gazeSigma, lockedFrame: selection.selected?.frame, at: t) else { return }
            selector.adopt(selection.selected?.id)
            log.info("gaze takes over again")
        }
        if windowCache.time < 0 || t - windowCache.time > 0.5 { windowCache = (t, ElementScanner.windowList()) }
        let gazedPID = Occlusion.topmostWindow(at: p, in: windowCache.windows.filter { $0.pid != getpid() })?.pid
        if let e = selector.update(gaze: p, fixating: fixating, sigma: gazeSigma, elements: selection.elements,
                                   at: t, gazedPID: gazedPID, recentIDs: recentIDs),
           selection.select(e.id) {
            logSelection("gaze")
            outline.highlight(selection.selected?.frame)
        }
    }

    private var recentIDs = Set<UInt64>()
    private var lastWasGaze: Bool { engagement.gazeDrives }

    func handle(_ command: NavCommand) {
        guard isActive else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let fromGaze = lastWasGaze
        if case .act = command {} else if command != .exit { engagement.keyPressed(at: now) }
        switch command {
        case .move(let d):
            // Right after a gaze pick, an arrow towards a close runner-up goes to it (M6).
            if fromGaze, let alt = selector.runnerUp, let cur = selection.selected,
               Self.lies(alt.frame, d, of: cur.frame), selection.select(alt.id) {
                break
            }
            if !selection.move(d) { NSSound.beep() }
        case .next:
            selection.step(forward: true)
        case .previous:
            selection.step(forward: false)
        case .exit:
            onExitRequested?("Esc")
            return
        case .act(let action):
            act(action)
            return
        }
        logSelection("\(command)")
        selector.adopt(selection.selected?.id)
        outline.highlight(selection.selected?.frame)
    }

    private static func lies(_ r: Rect2, _ d: Direction, of cur: Rect2) -> Bool {
        let a = r.center, c = cur.center
        switch d {
        case .left: return a.x < c.x && abs(a.y - c.y) < abs(a.x - c.x)
        case .right: return a.x > c.x && abs(a.y - c.y) < abs(a.x - c.x)
        case .up: return a.y < c.y && abs(a.x - c.x) < abs(a.y - c.y)
        case .down: return a.y > c.y && abs(a.x - c.x) < abs(a.y - c.y)
        }
    }

    private func act(_ action: ElementAction) {
        guard let target = selection.selected else { NSSound.beep(); return }
        let done = performer.perform(action, on: target, ref: store.refs[target.id])
        if done != nil {
            recentIDs.insert(target.id)
            if recentIDs.count > 20 { recentIDs.removeFirst() }
        }
        if done == nil { NSSound.beep() }
        // Typing into a field needs the keys Gazelle would otherwise swallow.
        if action == .press && target.kind.isEditable && done != nil {
            onExitRequested?("Typing in a text field")
            return
        }
        store.refreshSoon()
    }

    // MARK: Accessibility helpers

    private static func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func frame(_ e: AXUIElement) -> Rect2? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &size) == .success else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        return Rect2(x: p.x, y: p.y, width: s.width, height: s.height)
    }
}
