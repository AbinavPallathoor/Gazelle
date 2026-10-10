import Testing
@testable import GazeKit

@Suite struct ActivationTests {
    @Test func refusesToActivateWithoutKillSwitch() {
        var s = ActivationState()
        #expect(s.toggleActive() == .killSwitchUnavailable)
        #expect(!s.isActive)
        #expect(!s.interceptionAllowed)
    }

    @Test func toggleActivatesAndDeactivates() {
        var s = ActivationState()
        s.setKillSwitchRegistered(true)
        #expect(s.toggleActive() == nil)
        #expect(s.isActive && s.interceptionAllowed)
        #expect(s.toggleActive() == nil)
        #expect(!s.isActive)
    }

    @Test func killForcesInactiveUntilRearmed() {
        var s = ActivationState()
        s.setKillSwitchRegistered(true)
        s.toggleActive()
        s.kill()
        #expect(!s.isActive && !s.interceptionAllowed)
        #expect(s.toggleActive() == .killed)
        #expect(!s.isActive)
        s.rearm()
        #expect(s.toggleActive() == nil)
        #expect(s.isActive)
    }

    @Test func losingKillSwitchDeactivates() {
        var s = ActivationState()
        s.setKillSwitchRegistered(true)
        s.toggleActive()
        s.setKillSwitchRegistered(false)
        #expect(!s.isActive)
        #expect(s.blocker == .killSwitchUnavailable)
    }
}
