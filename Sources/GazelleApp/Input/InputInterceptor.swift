import Foundation

/// Anything that intercepts user input (the M3 keyboard event tap, later mouse synthesis).
/// The app enables it only while Active, and the kill switch disables it unconditionally.
@MainActor
protocol InputInterceptor: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool)
}

/// M1 placeholder: no interception exists yet. M3 replaces this with a CGEventTap.
@MainActor
final class NoInputInterceptor: InputInterceptor {
    private(set) var isEnabled = false
    func setEnabled(_ enabled: Bool) { isEnabled = enabled }
}
