import ApplicationServices
import CoreGraphics
import Foundation
import GazeKit
import os

private let log = Logger(subsystem: "dev.gazelle.Gazelle", category: "actions")

/// Carries out an `ElementAction` on an element, following `ActionPlanner`'s steps until one
/// succeeds. Accessibility actions are tried first (no pointer movement); synthesised clicks
/// move the pointer to the box centre, click, and put the pointer back.
@MainActor
final class ActionPerformer {
    /// Returns a short description of the step that worked, or nil if every step failed.
    @discardableResult
    func perform(_ action: ElementAction, on element: Element, ref: AXUIElement?) -> String? {
        let steps = ActionPlanner.plan(action, kind: element.kind, axActions: ref.map(Self.actionNames) ?? [])
        for step in steps {
            if run(step, element: element, ref: ref) {
                log.info("\(action.rawValue, privacy: .public) \(element.kind.rawValue, privacy: .public) via \(String(describing: step), privacy: .public)")
                return String(describing: step)
            }
        }
        log.error("\(action.rawValue, privacy: .public) failed on \(element.kind.rawValue, privacy: .public)")
        return nil
    }

    private func run(_ step: ActionStep, element: Element, ref: AXUIElement?) -> Bool {
        let center = CGPoint(x: element.frame.center.x, y: element.frame.center.y)
        switch step {
        case .ax(let name):
            guard let ref else { return false }
            return AXUIElementPerformAction(ref, name as CFString) == .success
        case .setFocused:
            guard let ref else { return false }
            return AXUIElementSetAttributeValue(ref, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
        case .click(let right, let count):
            Self.click(at: center, right: right, count: count)
            return true
        case .movePointer:
            CGWarpMouseCursorPosition(center)
            CGAssociateMouseAndMouseCursorPosition(1)
            return true
        }
    }

    static func actionNames(_ ref: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(ref, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    /// Posts a real click (or double click) at `point` in global top-left coordinates.
    static func click(at point: CGPoint, right: Bool, count: Int) {
        let source = CGEventSource(stateID: .hidSystemState)
        let original = CGEvent(source: nil)?.location
        let (down, up, button): (CGEventType, CGEventType, CGMouseButton) =
            right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: button)?
            .post(tap: .cghidEventTap)
        for n in 1...max(1, count) {
            for type in [down, up] {
                let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
                e?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                e?.post(tap: .cghidEventTap)
            }
        }
        if let original {
            // Let the click land before moving the pointer back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                CGWarpMouseCursorPosition(original)
                CGAssociateMouseAndMouseCursorPosition(1)
            }
        }
    }
}
