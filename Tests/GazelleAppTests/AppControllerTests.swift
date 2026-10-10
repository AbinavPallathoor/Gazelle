import XCTest
@testable import Gazelle

@MainActor
final class MockHotkeys: HotkeyRegistering {
    var failing: [Hotkey] = []
    var handlers: [String: @MainActor () -> Void] = [:]

    func register(_ hotkey: Hotkey, handler: @escaping @MainActor () -> Void) -> Bool {
        if failing.contains(hotkey) { return false }
        handlers[hotkey.display] = handler
        return true
    }

    func unregisterAll() { handlers.removeAll() }

    func press(_ hotkey: Hotkey) { handlers[hotkey.display]?() }
}

@MainActor
final class MockInterceptor: InputInterceptor {
    private(set) var isEnabled = false
    private(set) var changes: [Bool] = []
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        changes.append(enabled)
    }
}

@MainActor
final class MockPermissions: PermissionChecking {
    var answers: [Permission: PermissionStatus] = [:]
    func status(of permission: Permission) -> PermissionStatus { answers[permission] ?? .notDetermined }
    func request(_ permission: Permission) async { answers[permission] = .granted }
}

@MainActor
final class AppControllerTests: XCTestCase {
    private func make(failing: [Hotkey] = []) -> (AppController, MockHotkeys, MockInterceptor) {
        let hk = MockHotkeys()
        hk.failing = failing
        let ic = MockInterceptor()
        let c = AppController(hotkeys: hk, permissions: PermissionsModel(checker: MockPermissions()), interceptor: ic)
        c.start()
        return (c, hk, ic)
    }

    func testToggleHotkeyActivatesAndEnablesInterception() {
        let (c, hk, ic) = make()
        hk.press(.toggleActive)
        XCTAssertTrue(c.activation.isActive)
        XCTAssertTrue(ic.isEnabled)
        hk.press(.toggleActive)
        XCTAssertFalse(c.activation.isActive)
        XCTAssertFalse(ic.isEnabled)
    }

    func testRefusesToActivateWhenKillSwitchCannotRegister() {
        let (c, hk, ic) = make(failing: [.killSwitch])
        hk.press(.toggleActive)
        c.toggleActive() // menu path too
        XCTAssertFalse(c.activation.isActive)
        XCTAssertFalse(ic.isEnabled)
        XCTAssertEqual(c.lastRefusal, .killSwitchUnavailable)
    }

    func testKillSwitchDisablesInterceptionAndBlocksUntilRearmed() {
        let (c, hk, ic) = make()
        hk.press(.toggleActive)
        hk.press(.killSwitch)
        XCTAssertFalse(c.activation.isActive)
        XCTAssertFalse(ic.isEnabled)
        hk.press(.toggleActive)
        XCTAssertFalse(c.activation.isActive)
        XCTAssertEqual(c.lastRefusal, .killed)
        c.rearm()
        hk.press(.toggleActive)
        XCTAssertTrue(c.activation.isActive)
    }

    func testToggleHotkeyFailureStillAllowsMenuActivation() {
        let (c, _, ic) = make(failing: [.toggleActive])
        XCTAssertFalse(c.toggleHotkeyRegistered)
        c.toggleActive()
        XCTAssertTrue(ic.isEnabled)
    }

    func testStopDisablesInterceptionAndUnregisters() {
        let (c, hk, ic) = make()
        hk.press(.toggleActive)
        c.stop()
        XCTAssertFalse(ic.isEnabled)
        XCTAssertTrue(hk.handlers.isEmpty)
    }

    func testFeedbackReportsEachOutcome() {
        let (c, hk, _) = make()
        var seen: [ActivationFeedback] = []
        c.onFeedback = { seen.append($0) }
        hk.press(.toggleActive)
        hk.press(.toggleActive)
        hk.press(.killSwitch)
        hk.press(.toggleActive)
        c.rearm()
        XCTAssertEqual(seen, [.activated, .deactivated, .killed, .refused(.killed), .rearmed])
    }

    func testPermissionsModelReportsRequiredGrants() {
        let checker = MockPermissions()
        let model = PermissionsModel(checker: checker)
        XCTAssertFalse(model.allRequiredGranted)
        for p in Permission.allCases where p.isRequired { checker.answers[p] = .granted }
        model.refresh()
        XCTAssertTrue(model.allRequiredGranted) // Screen Recording is optional
        XCTAssertEqual(model.status(.screenRecording), .notDetermined)
    }
}
