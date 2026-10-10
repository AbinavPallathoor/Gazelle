import Foundation

/// What the user asked the selected element to do.
public enum ElementAction: String, Sendable, CaseIterable {
    case press
    case rightClick
    case doubleClick
    /// Give the element keyboard focus (or move the pointer onto it) without clicking.
    case focus
}

/// A keyboard command while Active.
public enum NavCommand: Equatable, Sendable {
    case move(Direction)
    case next
    case previous
    case act(ElementAction)
    case exit
}

/// Maps raw key events to commands. Pure, so the event tap's swallow decision is testable.
/// Only the keys listed here are swallowed; everything else passes through to the app.
public enum KeyMap {
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1)
        public static let control = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    // macOS virtual key codes (kVK_*).
    public static let leftArrow = 123, rightArrow = 124, downArrow = 125, upArrow = 126
    public static let tab = 48, returnKey = 36, keypadEnter = 76, escape = 53, kKey = 40

    /// The kill switch, recognised inside the event tap too (ADR 0003).
    public static func isKillSwitch(keyCode: Int, modifiers: Modifiers) -> Bool {
        keyCode == kKey && modifiers == [.control, .option]
    }

    public static func command(keyCode: Int, modifiers: Modifiers) -> NavCommand? {
        switch (keyCode, modifiers) {
        case (leftArrow, []): return .move(.left)
        case (rightArrow, []): return .move(.right)
        case (upArrow, []): return .move(.up)
        case (downArrow, []): return .move(.down)
        case (tab, []): return .next
        case (tab, [.shift]): return .previous
        case (returnKey, []), (keypadEnter, []): return .act(.press)
        case (returnKey, [.shift]), (keypadEnter, [.shift]): return .act(.rightClick)
        case (returnKey, [.option]), (keypadEnter, [.option]): return .act(.doubleClick)
        case (returnKey, [.command]), (keypadEnter, [.command]): return .act(.focus)
        case (escape, []): return .exit
        default: return nil
        }
    }
}

/// One step for carrying out an action; the performer tries steps in order until one works.
public enum ActionStep: Equatable, Sendable {
    /// Perform a named Accessibility action (no pointer movement).
    case ax(String)
    /// Set `AXFocused` on the element.
    case setFocused
    /// Synthesise a mouse click at the centre of the element's box.
    case click(right: Bool, count: Int)
    /// Move the pointer onto the element without clicking.
    case movePointer
}

public enum ActionPlanner {
    /// Ordered steps for `action` on an element of `kind` that advertises `axActions`.
    /// Accessibility actions come first because they do not move the pointer; a synthesised
    /// click at the box centre is the fallback.
    public static func plan(_ action: ElementAction, kind: ElementKind, axActions: [String]) -> [ActionStep] {
        switch action {
        case .press:
            if kind.isEditable {
                // Focus the field, then click so the caret lands and the app treats it as user input.
                return [.setFocused, .click(right: false, count: 1)]
            }
            let preferred = ["AXPress", "AXOpen", "AXPick", "AXConfirm"].filter(axActions.contains)
            return preferred.map(ActionStep.ax) + [.click(right: false, count: 1)]
        case .rightClick:
            return (axActions.contains("AXShowMenu") ? [.ax("AXShowMenu")] : []) + [.click(right: true, count: 1)]
        case .doubleClick:
            return [.click(right: false, count: 2)]
        case .focus:
            return [.setFocused, .movePointer]
        }
    }
}
