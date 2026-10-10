import AppKit
import Combine
import GazeKit

/// The menu-bar icon and its menu. Rebuilt from `AppController` state each time it opens.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let controller: AppController
    private let showPermissions: () -> Void
    private var cancellables: Set<AnyCancellable> = []

    init(controller: AppController, showPermissions: @escaping () -> Void) {
        self.controller = controller
        self.showPermissions = showPermissions
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        controller.$activation
            .sink { [weak self] in self?.updateIcon($0) }
            .store(in: &cancellables)
    }

    private func updateIcon(_ s: ActivationState) {
        let (symbol, label): (String, String)
        if s.blocker == .killSwitchUnavailable {
            (symbol, label) = ("exclamationmark.triangle", "Gazelle: kill switch unavailable")
        } else if s.killed {
            (symbol, label) = ("eye.slash", "Gazelle: stopped by kill switch")
        } else if s.isActive {
            (symbol, label) = ("eye.fill", "Gazelle: Active")
        } else {
            (symbol, label) = ("eye", "Gazelle: inactive")
        }
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.button?.toolTip = label
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = controller.activation

        let active = NSMenuItem(title: "Active", action: #selector(toggleActive), keyEquivalent: "")
        active.target = self
        active.state = s.isActive ? .on : .off
        active.isEnabled = s.isActive || s.blocker == nil
        menu.addItem(active)
        menu.addItem(info(controller.toggleHotkeyRegistered
            ? "Toggle from any app: \(Hotkey.toggleActive.display)"
            : "Toggle hotkey \(Hotkey.toggleActive.display) unavailable (in use by another app)"))

        menu.addItem(.separator())
        switch s.blocker {
        case .killSwitchUnavailable:
            menu.addItem(info("Kill switch \(Hotkey.killSwitch.display) could not be registered."))
            menu.addItem(info("Gazelle will not activate without it."))
        case .killed:
            menu.addItem(info("Stopped by kill switch"))
            let rearm = NSMenuItem(title: "Re-arm Kill Switch", action: #selector(rearm), keyEquivalent: "")
            rearm.target = self
            menu.addItem(rearm)
        case nil:
            menu.addItem(info("Kill switch: \(Hotkey.killSwitch.display) (armed)"))
        }

        menu.addItem(.separator())
        let perms = NSMenuItem(
            title: controller.permissions.allRequiredGranted ? "Permissions…" : "Permissions… (action needed)",
            action: #selector(openPermissions), keyEquivalent: ",")
        perms.target = self
        menu.addItem(perms)
        menu.addItem(NSMenuItem(title: "Quit Gazelle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func info(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    @objc private func toggleActive() { controller.toggleActive() }
    @objc private func rearm() { controller.rearm() }
    @objc private func openPermissions() { showPermissions() }
}
