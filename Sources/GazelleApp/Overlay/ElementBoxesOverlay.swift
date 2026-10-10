import AppKit
import GazeKit

/// Debug overlay: one click-through panel per display that outlines every element in the store,
/// coloured by kind, plus a stats line. Panels float above everything, including the menu bar,
/// the Dock and full-screen apps, and never take focus or mouse events.
@MainActor
final class ElementBoxesOverlay {
    private var panels: [OverlayPanel] = []
    private var screenToken: NSObjectProtocol?
    private(set) var isVisible = false

    func show() {
        guard !isVisible else { return }
        isVisible = true
        rebuildPanels()
        screenToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildPanels() }
        }
    }

    func hide() {
        isVisible = false
        panels.forEach { $0.orderOut(nil) }
        panels = []
        if let screenToken { NotificationCenter.default.removeObserver(screenToken) }
        screenToken = nil
    }

    func update(elements: [Element], stats: ScanStats, lacksPermission: Bool) {
        guard isVisible, let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        let status: String
        if lacksPermission {
            status = "Gazelle needs Accessibility permission to read elements (menu → Permissions…)"
        } else {
            var s = String(format: "%@ · %d elements · %d nodes · scan %.0f ms",
                           stats.appName, stats.elements, stats.visitedNodes, stats.durationMs)
            if let l = stats.latencyMs { s += String(format: " · change→boxes %.0f ms", l) }
            if stats.truncated { s += " · TRUNCATED" }
            status = s
        }
        for panel in panels {
            let origin = panel.frame.origin
            panel.boxes.items = elements.compactMap { e in
                let r = ScreenSpace.appKitRect(fromTopLeft: e.frame, primaryHeight: Double(primaryHeight))
                let local = NSRect(x: r.x - origin.x, y: r.y - origin.y, width: r.width, height: r.height)
                guard local.intersects(panel.boxes.bounds) else { return nil }
                return BoxesView.Item(rect: local, color: Self.color(e.kind))
            }
            panel.boxes.status = status
            panel.boxes.needsDisplay = true
        }
    }

    private func rebuildPanels() {
        panels.forEach { $0.orderOut(nil) }
        panels = NSScreen.screens.map { OverlayPanel(screen: $0) }
        panels.forEach { $0.orderFrontRegardless() }
    }

    static func color(_ kind: ElementKind) -> NSColor {
        switch kind {
        case .button, .popUp, .disclosure: return .systemBlue
        case .link: return .systemPurple
        case .checkbox, .radio, .slider: return .systemTeal
        case .tab: return .systemIndigo
        case .menuItem, .menuBarItem: return .systemOrange
        case .statusItem: return .systemYellow
        case .dockItem: return .systemPink
        case .textField: return .systemGreen
        case .row, .cell: return .systemGray
        case .pressable: return .systemRed
        }
    }
}

private final class OverlayPanel: NSPanel {
    let boxes = BoxesView()

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(screen.frame, display: false)
        contentView = boxes
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class BoxesView: NSView {
    struct Item {
        var rect: NSRect
        var color: NSColor
    }

    var items: [Item] = []
    var status = ""

    override func draw(_ dirtyRect: NSRect) {
        for item in items {
            let path = NSBezierPath(roundedRect: item.rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            item.color.withAlphaComponent(0.12).setFill()
            path.fill()
            item.color.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
        guard !status.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: status, attributes: attrs)
        let size = text.size()
        let box = NSRect(x: 12, y: 80, width: size.width + 16, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        text.draw(at: NSPoint(x: box.minX + 8, y: box.minY + 4))
    }
}
