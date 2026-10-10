import AppKit
import Combine

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController!
    private var statusItem: StatusItemController!
    private var onboarding: OnboardingWindowController!
    private let hud = FeedbackHUD()
    private let elementStore = ElementStore()
    private let elementBoxes = ElementBoxesOverlay()
    private var cancellables: Set<AnyCancellable> = []

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu-bar only, also set by LSUIElement
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run inside this app as their host; keep it inert there.
        if NSClassFromString("XCTestCase") != nil { return }

        let permissions = PermissionsModel(checker: SystemPermissions())
        let hotkeys = CarbonHotkeys()
        controller = AppController(hotkeys: hotkeys, permissions: permissions, interceptor: NoInputInterceptor())
        onboarding = OnboardingWindowController(model: permissions)
        statusItem = StatusItemController(
            controller: controller,
            showPermissions: { [weak self] in self?.onboarding.show() },
            elementBoxesVisible: { [weak self] in self?.elementBoxes.isVisible ?? false },
            toggleElementBoxes: { [weak self] in self?.toggleElementBoxes() })
        controller.onFeedback = { [weak self] in self?.showFeedback($0) }
        controller.start()
        _ = hotkeys.register(.toggleElementBoxes) { [weak self] in self?.toggleElementBoxes() }

        elementStore.$elements.combineLatest(elementStore.$stats, elementStore.$lacksPermission)
            .sink { [weak self] elements, stats, lacks in
                self?.elementBoxes.update(elements: elements, stats: stats, lacksPermission: lacks)
            }
            .store(in: &cancellables)

        if !permissions.allRequiredGranted { onboarding.show() }
    }

    /// The element store runs only while something needs it (the overlay now; selection from M3).
    private func toggleElementBoxes() {
        if elementBoxes.isVisible {
            elementBoxes.hide()
            elementStore.stop()
            hud.show(symbol: "square.dashed", text: "Element boxes off", tint: .secondaryLabelColor)
        } else {
            elementBoxes.show()
            elementStore.start()
            hud.show(symbol: "square.dashed.inset.filled", text: "Element boxes on", tint: .controlAccentColor)
        }
    }

    private func showFeedback(_ feedback: ActivationFeedback) {
        switch feedback {
        case .activated:
            hud.show(symbol: "eye.fill", text: "Gazelle Active", tint: .controlAccentColor)
        case .deactivated:
            hud.show(symbol: "eye", text: "Gazelle Inactive", tint: .secondaryLabelColor)
        case .killed:
            hud.show(symbol: "eye.slash", text: "Kill switch: Gazelle stopped", tint: .systemRed)
        case .rearmed:
            hud.show(symbol: "eye", text: "Kill switch re-armed", tint: .secondaryLabelColor)
        case .refused(.killed):
            hud.show(symbol: "eye.slash", text: "Stopped by kill switch. Re-arm from the menu.", tint: .systemRed)
        case .refused(.killSwitchUnavailable):
            hud.show(symbol: "exclamationmark.triangle", text: "Kill switch unavailable", tint: .systemOrange)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
        elementStore.stop()
    }
}
