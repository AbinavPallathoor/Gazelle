import AppKit
import Combine
import GazeKit

/// A user-visible outcome of a hotkey or menu action.
enum ActivationFeedback: Equatable {
    case activated
    /// With a reason when Gazelle left Active by itself (Esc, typing into a field).
    case deactivated(String?)
    case refused(ActivationBlocker)
    case killed
    case rearmed
}

/// Owns engagement state and wires hotkeys to it. Contains no UI so it can be tested with mocks.
@MainActor
final class AppController: ObservableObject {
    /// Called after every toggle, kill or re-arm so the app can show feedback.
    var onFeedback: ((ActivationFeedback) -> Void)?

    @Published private(set) var activation = ActivationState()
    /// Set when the toggle hotkey could not be registered (activation still works from the menu).
    @Published private(set) var toggleHotkeyRegistered = false
    /// The last refusal, shown in the menu until the next successful change.
    @Published private(set) var lastRefusal: ActivationBlocker?

    let permissions: PermissionsModel
    private let hotkeys: HotkeyRegistering
    private let interceptor: InputInterceptor

    init(hotkeys: HotkeyRegistering, permissions: PermissionsModel, interceptor: InputInterceptor) {
        self.hotkeys = hotkeys
        self.permissions = permissions
        self.interceptor = interceptor
    }

    /// Registers the kill switch first: if it fails, the app never becomes Active.
    func start() {
        let killOK = hotkeys.register(.killSwitch) { [weak self] in self?.kill() }
        activation.setKillSwitchRegistered(killOK)
        toggleHotkeyRegistered = hotkeys.register(.toggleActive) { [weak self] in self?.toggleActive() }
        apply()
    }

    func stop() {
        activation.deactivate()
        apply()
        hotkeys.unregisterAll()
    }

    func toggleActive() {
        lastRefusal = activation.toggleActive()
        if let refusal = lastRefusal {
            NSSound.beep()
            onFeedback?(.refused(refusal))
        } else {
            onFeedback?(activation.isActive ? .activated : .deactivated(nil))
        }
        apply()
    }

    /// Leaves Active (Esc, or a text field took the keyboard).
    func deactivate(reason: String) {
        guard activation.isActive else { return }
        activation.deactivate()
        apply()
        onFeedback?(.deactivated(reason))
    }

    /// Kill switch: force Inactive and disable all interception, regardless of state.
    func kill() {
        activation.kill()
        lastRefusal = nil
        apply()
        onFeedback?(.killed)
    }

    func rearm() {
        activation.rearm()
        lastRefusal = nil
        apply()
        onFeedback?(.rearmed)
    }

    private func apply() {
        let allowed = activation.interceptionAllowed
        if interceptor.isEnabled != allowed { interceptor.setEnabled(allowed) }
    }
}
