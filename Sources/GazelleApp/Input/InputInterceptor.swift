import Foundation

/// Anything that intercepts user input (`KeyboardTap`; mocked in tests).
/// The app enables it only while Active, and the kill switch disables it unconditionally.
@MainActor
protocol InputInterceptor: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool)
}
