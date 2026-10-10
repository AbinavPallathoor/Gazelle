import Foundation

/// Why the app may not become Active.
public enum ActivationBlocker: Equatable, Sendable, CustomStringConvertible {
    /// The kill-switch hotkey could not be registered, so there would be no guaranteed way out.
    case killSwitchUnavailable
    /// The kill switch was pressed; it must be re-armed explicitly from the menu.
    case killed

    public var description: String {
        switch self {
        case .killSwitchUnavailable: return "The kill-switch hotkey could not be registered."
        case .killed: return "The kill switch was used. Re-arm it from the menu."
        }
    }
}

/// Engagement state: whether gaze/keyboard interception is Active, and whether it may become so.
///
/// Rules (PLAN.md §1, M1):
/// - The app refuses to become Active unless the kill switch is registered.
/// - The kill switch always forces Inactive and disables interception, and stays tripped until re-armed.
/// - The Active hotkey toggles Active when nothing blocks it.
public struct ActivationState: Equatable, Sendable {
    public private(set) var isActive = false
    public private(set) var killSwitchRegistered = false
    public private(set) var killed = false

    public init() {}

    public var blocker: ActivationBlocker? {
        if !killSwitchRegistered { return .killSwitchUnavailable }
        if killed { return .killed }
        return nil
    }

    /// Whether input interception (event taps) may run at all.
    public var interceptionAllowed: Bool { isActive && blocker == nil }

    public mutating func setKillSwitchRegistered(_ ok: Bool) {
        killSwitchRegistered = ok
        if !ok { isActive = false }
    }

    /// Returns the blocker if activation was refused.
    @discardableResult
    public mutating func toggleActive() -> ActivationBlocker? {
        if isActive {
            isActive = false
            return nil
        }
        if let b = blocker { return b }
        isActive = true
        return nil
    }

    public mutating func deactivate() { isActive = false }

    public mutating func kill() {
        isActive = false
        killed = true
    }

    public mutating func rearm() { killed = false }
}
