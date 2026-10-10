import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController!
    private var statusItem: StatusItemController!
    private var onboarding: OnboardingWindowController!
    private let hud = FeedbackHUD()

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
        controller = AppController(hotkeys: CarbonHotkeys(), permissions: permissions, interceptor: NoInputInterceptor())
        onboarding = OnboardingWindowController(model: permissions)
        statusItem = StatusItemController(controller: controller) { [weak self] in self?.onboarding.show() }
        controller.onFeedback = { [weak self] in self?.showFeedback($0) }
        controller.start()

        if !permissions.allRequiredGranted { onboarding.show() }
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
    }
}
