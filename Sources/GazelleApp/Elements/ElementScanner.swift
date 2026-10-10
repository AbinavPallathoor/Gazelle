import AppKit
import ApplicationServices
import GazeKit

/// Statistics for one element scan, shown in the debug overlay.
struct ScanStats: Equatable {
    var elements = 0
    var visitedNodes = 0
    var truncated = false
    var durationMs = 0.0
    /// From the triggering change notification to the published result.
    var latencyMs: Double?
    var appName = ""
}

/// Live Accessibility handles for the elements of one scan, keyed by `Element.id`.
typealias ElementRefs = [UInt64: AXUIElement]

/// Reads the element map from the Accessibility API. Runs on a background queue; every call
/// has a short messaging timeout so a busy target app cannot freeze it for long.
final class ElementScanner {
    static let messagingTimeout: Float = 0.15

    private let ownPID = getpid()
    private var manualAccessibilityEnabled = Set<pid_t>()

    init() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Self.messagingTimeout)
    }

    /// Scans the frontmost app's windows, open menus and menu bar, and drops occluded elements.
    func scanFrontmost(app: NSRunningApplication?, screens: [Rect2]) -> ([Element], ElementRefs, ScanStats) {
        let start = DispatchTime.now().uptimeNanoseconds
        var stats = ScanStats()
        var elements: [Element] = []
        var refs: ElementRefs = [:]
        let clip = Self.bounds(of: screens)

        if let app, app.processIdentifier != ownPID {
            stats.appName = app.localizedName ?? "?"
            let pid = app.processIdentifier
            let appNode = AXNode(element: AXUIElementCreateApplication(pid))
            enableManualAccessibility(appNode, pid: pid)
            // App children include its windows and any open menus or popovers.
            var roots: [(node: AXNode, source: ElementSource)] = []
            for child in appNode.children(visibleOnly: false) {
                let role = child.snapshot()?.role
                roots.append((child, role == "AXMenuBar" ? .menuBar : .window))
            }
            let res = TreeWalker.walk(roots: roots, pid: pid, clip: clip) { refs[$0.id] = $1.element }
            elements = res.elements
            stats.visitedNodes = res.visitedNodes
            stats.truncated = res.truncated
        }

        let visible = Occlusion.visibleElements(elements, windows: Self.windowList(), screens: screens, ignoringPID: ownPID)
        stats.elements = visible.count
        stats.durationMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        return (visible, refs, stats)
    }

    /// Menu extras (status items of every app) and the Dock. Slow (one round trip per running
    /// app) but rarely changing, so the store runs it separately from frontmost-app scans.
    func scanSystem(screens: [Rect2]) -> ([Element], ElementRefs) {
        let clip = Self.bounds(of: screens)
        var refs: ElementRefs = [:]
        let all = scanMenuExtras(clip: clip, refs: &refs) + scanDock(clip: clip, refs: &refs)
        return (Occlusion.visibleElements(all, windows: [], screens: screens, ignoringPID: ownPID), refs)
    }

    private static func bounds(of screens: [Rect2]) -> Rect2 {
        screens.dropFirst().reduce(screens.first ?? Rect2(x: 0, y: 0, width: 0, height: 0)) { $0.union($1) }
    }

    /// Electron apps (and recent Chromium) only build their accessibility tree for assistive
    /// tools that ask. `AXManualAccessibility` is the documented, side-effect-free switch;
    /// apps that do not support it simply return an error. See ADR 0004.
    private func enableManualAccessibility(_ app: AXNode, pid: pid_t) {
        guard !manualAccessibilityEnabled.contains(pid) else { return }
        let result = AXUIElementSetAttributeValue(app.element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        // A just-launched app answers .cannotComplete until it is ready; try again next scan.
        if result != .cannotComplete { manualAccessibilityEnabled.insert(pid) }
    }

    private func scanMenuExtras(clip: Rect2, refs: inout ElementRefs) -> [Element] {
        var out: [Element] = []
        for app in NSWorkspace.shared.runningApplications where app.processIdentifier != ownPID {
            let node = AXNode(element: AXUIElementCreateApplication(app.processIdentifier))
            guard let extras = node.element("AXExtrasMenuBar") else { continue }
            out += TreeWalker.walk(roots: [(extras, .menuExtras)], pid: app.processIdentifier, clip: clip) {
                refs[$0.id] = $1.element
            }.elements
        }
        return out
    }

    private func scanDock(clip: Rect2, refs: inout ElementRefs) -> [Element] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [] }
        let node = AXNode(element: AXUIElementCreateApplication(dock.processIdentifier))
        let roots = node.children(visibleOnly: false).map { (node: $0, source: ElementSource.dock) }
        return TreeWalker.walk(roots: roots, pid: dock.processIdentifier, clip: clip) { refs[$0.id] = $1.element }.elements
    }

    /// On-screen windows front to back. Bounds are readable without Screen Recording permission.
    static func windowList() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return list.compactMap { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32,
                  let layer = w[kCGWindowLayer as String] as? Int,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let b = w[kCGWindowBounds as String] as? [String: Double],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"],
                  width > 1, height > 1 else { return nil }
            return WindowInfo(pid: pid, layer: layer, frame: Rect2(x: x, y: y, width: width, height: height))
        }
    }

    /// Screens in global top-left points.
    @MainActor
    static func screenRects() -> [Rect2] {
        guard let primary = NSScreen.screens.first else { return [] }
        let h = Double(primary.frame.height)
        return NSScreen.screens.map {
            ScreenSpace.topLeftRect(fromAppKit: Rect2(x: $0.frame.minX, y: $0.frame.minY,
                                                      width: $0.frame.width, height: $0.frame.height), primaryHeight: h)
        }
    }
}
