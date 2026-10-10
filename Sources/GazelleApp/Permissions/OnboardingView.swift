import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: PermissionsModel
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up Gazelle")
                .font(.title2.weight(.semibold))
            Text("Gazelle needs these permissions. Status updates automatically when you change them in System Settings.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Permission.allCases) { p in
                PermissionRow(permission: p, status: model.status(p)) { model.grant(p) }
            }

            Text("Input Monitoring and Screen Recording may only take effect after Gazelle is relaunched.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(model.allRequiredGranted ? "Done" : "Continue Without All Permissions", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

private struct PermissionRow: View {
    let permission: Permission
    let status: PermissionStatus
    let grant: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(permission.title).font(.headline)
                    if !permission.isRequired {
                        Text("Optional").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(permission.purpose)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if status == .granted {
                Text("Granted").foregroundStyle(.secondary)
            } else {
                Button(status == .notDetermined ? "Allow…" : "Open Settings…", action: grant)
            }
        }
    }

    private var icon: String {
        switch status {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .notDetermined: return "questionmark.circle"
        }
    }

    private var color: Color {
        switch status {
        case .granted: return .green
        case .denied: return .red
        case .notDetermined: return .secondary
        }
    }
}

/// Hosts the onboarding view in a normal window and polls permission status while it is open.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: PermissionsModel

    init(model: PermissionsModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(
                rootView: OnboardingView(model: model) { [weak self] in self?.window?.close() }))
            w.title = "Gazelle Permissions"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        model.refresh()
        model.startPolling()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.stopPolling()
    }
}
