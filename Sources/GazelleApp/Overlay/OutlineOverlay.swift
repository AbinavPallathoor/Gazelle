import AppKit
import GazeKit
import QuartzCore

/// The selection outline: a rounded, high-contrast ring that animates between elements.
/// One click-through, non-activating panel per display, above full-screen apps and on all Spaces.
@MainActor
final class OutlineOverlay {
    private var panels: [OutlinePanel] = []
    private var screenToken: NSObjectProtocol?
    private var current: Rect2?

    func show() {
        guard panels.isEmpty else { return }
        rebuild()
        screenToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuild()
                if let r = self?.current { self?.highlight(r, animated: false) }
            }
        }
    }

    func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        current = nil
        if let screenToken { NotificationCenter.default.removeObserver(screenToken) }
        screenToken = nil
    }

    /// Outlines `frame` (global top-left points), or hides the ring when nil.
    func highlight(_ frame: Rect2?, animated: Bool = true) {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        let previous = current
        current = frame
        for panel in panels {
            guard let frame else { panel.ring.setPath(nil, animated: false); continue }
            let r = ScreenSpace.appKitRect(fromTopLeft: frame, primaryHeight: Double(primaryHeight))
            let local = NSRect(x: r.x - panel.frame.minX, y: r.y - panel.frame.minY, width: r.width, height: r.height)
            let onThisScreen = local.intersects(panel.ring.bounds)
            // Animate only when the ring stays on the same display.
            let wasHere = previous.map { p -> Bool in
                let pr = ScreenSpace.appKitRect(fromTopLeft: p, primaryHeight: Double(primaryHeight))
                return NSRect(x: pr.x, y: pr.y, width: pr.width, height: pr.height).intersects(panel.frame)
            } ?? false
            panel.ring.setPath(onThisScreen ? local : nil, animated: animated && wasHere && onThisScreen)
        }
    }

    private func rebuild() {
        panels.forEach { $0.orderOut(nil) }
        panels = NSScreen.screens.map { OutlinePanel(screen: $0) }
        panels.forEach { $0.orderFrontRegardless() }
    }
}

private final class OutlinePanel: NSPanel {
    let ring = RingView()

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Above the debug boxes so the selection is always readable.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)) + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(screen.frame, display: false)
        contentView = ring
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Two stacked strokes (dark outer, bright inner) stay visible on light and dark content.
private final class RingView: NSView {
    private let outer = CAShapeLayer()
    private let inner = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for (l, color, width) in [(outer, NSColor.black.withAlphaComponent(0.75), 6.0),
                                  (inner, NSColor.systemYellow, 3.0)] {
            l.fillColor = nil
            l.strokeColor = color.cgColor
            l.lineWidth = width
            l.lineJoin = .round
            layer?.addSublayer(l)
        }
        inner.shadowColor = NSColor.systemYellow.cgColor
        inner.shadowRadius = 6
        inner.shadowOpacity = 0.6
        inner.shadowOffset = .zero
    }

    required init?(coder: NSCoder) { fatalError() }

    func setPath(_ rect: NSRect?, animated: Bool) {
        guard let rect else {
            outer.path = nil
            inner.path = nil
            return
        }
        let r = rect.insetBy(dx: -4, dy: -4)
        let radius = min(10, min(r.width, r.height) / 2)
        let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        for l in [outer, inner] {
            if animated, let from = l.path {
                let a = CABasicAnimation(keyPath: "path")
                a.fromValue = from
                a.toValue = path
                a.duration = 0.12
                a.timingFunction = CAMediaTimingFunction(name: .easeOut)
                l.add(a, forKey: "path")
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            l.path = path
            CATransaction.commit()
        }
    }
}
