import AppKit
import ApplicationServices
import AVFoundation
import Combine
import IOKit.hid

enum Permission: CaseIterable, Identifiable {
    case camera
    case accessibility
    case inputMonitoring
    case screenRecording

    var id: Self { self }

    var title: String {
        switch self {
        case .camera: return "Camera"
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        case .screenRecording: return "Screen Recording"
        }
    }

    var purpose: String {
        switch self {
        case .camera: return "Estimates where you are looking. Frames stay in memory and are never saved."
        case .accessibility: return "Reads on-screen buttons and links, and presses the one you choose."
        case .inputMonitoring: return "Lets the navigation keys move the outline while Gazelle is Active."
        case .screenRecording: return "Optional. Finds clickable things in apps with poor accessibility support."
        }
    }

    var isRequired: Bool { self != .screenRecording }

    var settingsURL: URL {
        let anchor: String
        switch self {
        case .camera: anchor = "Privacy_Camera"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

enum PermissionStatus: Equatable {
    case granted
    case denied
    case notDetermined
}

/// Reads and requests macOS privacy permissions. Behind a protocol so tests can use fixed answers.
@MainActor
protocol PermissionChecking: AnyObject {
    func status(of permission: Permission) -> PermissionStatus
    /// Shows the system prompt where macOS has one. Some permissions only take effect after relaunch.
    func request(_ permission: Permission) async
}

@MainActor
final class SystemPermissions: PermissionChecking {
    func status(of permission: Permission) -> PermissionStatus {
        switch permission {
        case .camera:
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        case .inputMonitoring:
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted: return .granted
            case kIOHIDAccessTypeDenied: return .denied
            default: return .notDetermined
            }
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        }
    }

    func request(_ permission: Permission) async {
        switch permission {
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case .inputMonitoring:
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        }
    }
}

/// Observable permission statuses, refreshed while the onboarding window is open
/// (macOS sends no notification when the user flips a switch in System Settings).
@MainActor
final class PermissionsModel: ObservableObject {
    @Published private(set) var statuses: [Permission: PermissionStatus] = [:]
    private let checker: PermissionChecking
    private var timer: Timer?

    init(checker: PermissionChecking) {
        self.checker = checker
        refresh()
    }

    var allRequiredGranted: Bool {
        Permission.allCases.filter(\.isRequired).allSatisfy { statuses[$0] == .granted }
    }

    func status(_ p: Permission) -> PermissionStatus { statuses[p] ?? .notDetermined }

    func refresh() {
        var s: [Permission: PermissionStatus] = [:]
        for p in Permission.allCases { s[p] = checker.status(of: p) }
        if s != statuses { statuses = s }
    }

    /// Shows the system prompt while the permission is undecided; once denied, opens System Settings.
    /// Accessibility's prompt has its own "Open System Settings" button. Screen Recording only
    /// prompts once, so its pane is opened as well.
    func grant(_ p: Permission) {
        switch (p, status(p)) {
        case (_, .granted):
            return
        case (.accessibility, _), (_, .notDetermined):
            Task {
                await checker.request(p)
                refresh()
            }
        case (.screenRecording, _):
            Task {
                await checker.request(p)
                NSWorkspace.shared.open(p.settingsURL)
            }
        default:
            NSWorkspace.shared.open(p.settingsURL)
        }
    }

    func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
}
