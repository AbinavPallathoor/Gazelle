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

    func handle(_ command: NavCommand) {
        guard isActive else { return }
        switch command {
        case .move(let d):
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
        outline.highlight(selection.selected?.frame)
    }

    private func act(_ action: ElementAction) {
        guard let target = selection.selected else { NSSound.beep(); return }
        let done = performer.perform(action, on: target, ref: store.refs[target.id])
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
