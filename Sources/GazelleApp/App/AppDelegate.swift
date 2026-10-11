import AppKit
import Combine
import GazeKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController!
    private var statusItem: StatusItemController!
    private var onboarding: OnboardingWindowController!
    private let hud = FeedbackHUD()
    private let elementStore = ElementStore()
    private let elementBoxes = ElementBoxesOverlay()
    private let keyboardTap = KeyboardTap()
    private let pipeline = GazePipeline()
    private let hudPanel = DebugHUD()
    private let gazeDot = GazeDotOverlay()
    /// Show the gaze dot once the calibration started from ⌃⌥D is saved.
    private var showDotAfterCalibration = false
    private lazy var calibration = CalibrationController(pipeline: pipeline)
    private lazy var navigation = NavigationController(store: elementStore)
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
        controller = AppController(hotkeys: hotkeys, permissions: permissions, interceptor: keyboardTap)
        keyboardTap.onCommand = { [weak self] in self?.navigation.handle($0) }
        keyboardTap.onKill = { [weak self] in self?.controller.kill() }
        navigation.onExitRequested = { [weak self] reason in self?.controller.deactivate(reason: reason) }
        navigation.onConfirmed = { [weak self] frame, rank, uptime in
            self?.pipeline.confirm(target: frame, rank: rank, uptime: uptime)
        }
        onboarding = OnboardingWindowController(model: permissions)
        statusItem = StatusItemController(
            controller: controller,
            showPermissions: { [weak self] in self?.onboarding.show() },
            elementBoxesVisible: { [weak self] in self?.elementBoxes.isVisible ?? false },
            toggleElementBoxes: { [weak self] in self?.toggleElementBoxes() },
            hudVisible: { [weak self] in self?.hudPanel.isVisible ?? false },
            gazeDotVisible: { [weak self] in self?.gazeDot.isVisible ?? false },
            toggleGazeDot: { [weak self] in self?.toggleGazeDot() },
            toggleHUD: { [weak self] in self?.toggleHUD() },
            calibrate: { [weak self] in self?.startCalibration() },
            calibrationSummary: { [weak self] in self?.calibrationSummary })
        controller.onFeedback = { [weak self] in self?.showFeedback($0) }
        controller.start()
        _ = hotkeys.register(.toggleElementBoxes) { [weak self] in self?.toggleElementBoxes() }
        _ = hotkeys.register(.toggleHUD) { [weak self] in self?.toggleHUD() }
        _ = hotkeys.register(.toggleGazeDot) { [weak self] in self?.toggleGazeDot() }
        _ = hotkeys.register(.recentre) { [weak self] in self?.recentre() }
        pipeline.onGaze = { [weak self] p, fixating in
            self?.gazeDot.update(p, fixating: fixating)
            self?.navigation.gaze(p, fixating: fixating, at: ProcessInfo.processInfo.systemUptime)
        }

        if let screen = NSScreen.main, let profile = ProfileStore.load(for: screen) {
            pipeline.setProfile(profile)
        }
        calibration.onFinished = { [weak self] profile in
            guard let self else { return }
            if let profile {
                self.pipeline.setProfile(profile)
                self.hud.show(symbol: "scope", text: String(format: "Calibrated: %.2f°", profile.validation.meanErrorDegrees),
                              tint: .systemGreen)
                if self.showDotAfterCalibration { self.gazeDot.show() }
            }
            self.showDotAfterCalibration = false
            self.updateCameraRunning()
        }
        pipeline.$snapshot
            .sink { [weak self] s in
                self?.hudPanel.update(s, validation: self?.pipeline.profile?.validation)
                self?.navigation.faceTracking = s.face == .tracking
                if let sigma = s.sigma { self?.navigation.gazeSigma = sigma }
            }
            .store(in: &cancellables)

        controller.$activation
            .map(\.isActive)
            .removeDuplicates()
            .sink { [weak self] active in
                guard let self else { return }
                self.navigation.gazeSigma = self.gazeSigma
                self.navigation.setActive(active)
                self.updateCameraRunning(active: active)
                // @Published emits before the property changes, so pass the new value along.
                self.updateStoreRunning(active: active)
            }
            .store(in: &cancellables)

        elementStore.$elements.combineLatest(elementStore.$stats, elementStore.$lacksPermission)
            .sink { [weak self] elements, stats, lacks in
                self?.elementBoxes.update(elements: elements, stats: stats, lacksPermission: lacks)
            }
            .store(in: &cancellables)

        if !permissions.allRequiredGranted { onboarding.show() }
    }

    private func toggleElementBoxes() {
        if elementBoxes.isVisible {
            elementBoxes.hide()
            hud.show(symbol: "square.dashed", text: "Element boxes off", tint: .secondaryLabelColor)
        } else {
            elementBoxes.show()
            hud.show(symbol: "square.dashed.inset.filled", text: "Element boxes on", tint: .controlAccentColor)
        }
        updateStoreRunning(active: controller.activation.isActive)
    }

    private func toggleHUD() {
        if hudPanel.isVisible { hudPanel.hide() } else { hudPanel.show() }
        updateCameraRunning()
    }

    private func toggleGazeDot() {
        if gazeDot.isVisible {
            gazeDot.hide()
        } else if pipeline.profile == nil {
            hud.show(symbol: "scope", text: "Calibrate first: starting calibration", tint: .systemOrange)
            showDotAfterCalibration = true
            startCalibration()
            return
        } else {
            gazeDot.show()
            hud.show(symbol: "eye.circle", text: "Gaze dot on (\(Hotkey.toggleGazeDot.display) to hide)", tint: .systemTeal)
        }
        updateCameraRunning()
    }

    private func startCalibration() {
        guard !calibration.isRunning else { return }
        calibration.start()
    }

    /// Gaze error σ for snapping: the online learner's rolling estimate (M8), which starts at
    /// the calibration's validation error; at least 40 pt.
    private var gazeSigma: Double {
        max(40, pipeline.sigma ?? pipeline.profile?.validation.meanErrorPoints ?? 80)
    }

    private var recentring = false
    private let recentreDot = RecentreDot()

    /// Quick one-point re-centre: look at the dot in the middle of the screen for ~2 s.
    private func recentre() {
        guard !recentring else { return }
        guard pipeline.profile != nil else {
            hud.show(symbol: "scope", text: "Calibrate first", tint: .systemOrange)
            return
        }
        guard let screen = NSScreen.main else { return }
        recentring = true
        let f = ProfileStore.topLeftFrame(of: screen)
        let target = Point2(f.x + f.width / 2, f.y + f.height / 2)
        pipeline.start()
        recentreDot.show(at: target)
        // Give the camera a moment if it was just started.
        DispatchQueue.main.asyncAfter(deadline: .now() + (pipeline.snapshot.fps > 0 ? 0 : 2.5)) { [weak self] in
            self?.pipeline.recentre(at: target) {
                guard let self else { return }
                self.recentreDot.hide()
                self.recentring = false
                self.hud.show(symbol: "scope", text: "Re-centred", tint: .systemGreen)
                self.updateCameraRunning()
            }
        }
    }

    /// The camera runs only while something uses it: Active with a calibration (gaze snapping),
    /// the HUD, the gaze dot, or a calibration in progress.
    private func updateCameraRunning(active: Bool? = nil) {
        let isActive = active ?? controller.activation.isActive
        if (isActive && pipeline.profile != nil) || hudPanel.isVisible || gazeDot.isVisible || calibration.isRunning || recentring {
            pipeline.start()
        } else {
            pipeline.stop()
        }
    }

    private var calibrationSummary: String? {
        guard let v = pipeline.profile?.validation else { return nil }
        return String(format: "Calibrated: %.2f° (%.0f pt)", v.meanErrorDegrees, v.meanErrorPoints)
    }

    /// The element store runs only while something needs it: Active navigation or the debug boxes.
    private func updateStoreRunning(active: Bool) {
        if active || elementBoxes.isVisible {
            elementStore.start()
        } else {
            elementStore.stop()
        }
    }

    private func showFeedback(_ feedback: ActivationFeedback) {
        switch feedback {
        case .activated:
            hud.show(symbol: "eye.fill", text: "Gazelle Active", tint: .controlAccentColor)
        case .deactivated(let reason):
            hud.show(symbol: "eye", text: reason.map { "Gazelle Inactive: \($0)" } ?? "Gazelle Inactive", tint: .secondaryLabelColor)
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
        pipeline.stop()
    }
}
