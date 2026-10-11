import AppKit
import GazeKit

/// Shows where Gazelle thinks you are looking: a ring that follows the filtered gaze point at
/// camera rate, solid while fixating, hidden when no gaze arrives for a moment (face lost,
/// blink, stalled camera). Click-through and above everything, on all Spaces.
@MainActor
final class GazeDotOverlay {
    private var panel: GazeDotPanel?
    private var hideTimer: Timer?
    private(set) var isVisible = false

    func show() {
        guard !isVisible else { return }
        isVisible = true
        let p = GazeDotPanel()
        p.orderFrontRegardless()
        panel = p
    }

    func hide() {
        isVisible = false
        panel?.orderOut(nil)
        panel = nil
        hideTimer?.invalidate()
        hideTimer = nil
    }

    /// Called for every gaze sample (global top-left points).
    func update(_ p: Point2, fixating: Bool) {
        guard let panel else { return }
        panel.place(at: p, fixating: fixating)
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel?.alphaValue = 0 }
        }
    }
}

private final class GazeDotPanel: NSPanel {
    static let size: CGFloat = 44
    private let ring = CAShapeLayer()
    private let center = CAShapeLayer()

    init() {
        let s = Self.size
        super.init(contentRect: NSRect(x: 0, y: 0, width: s, height: s), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)) + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView(frame: NSRect(x: 0, y: 0, width: s, height: s))
        view.wantsLayer = true
        let inset: CGFloat = 4
        ring.path = CGPath(ellipseIn: CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset), transform: nil)
        ring.lineWidth = 3
        ring.strokeColor = NSColor.systemTeal.cgColor
        ring.shadowColor = NSColor.black.cgColor
        ring.shadowOpacity = 0.6
        ring.shadowRadius = 3
        ring.shadowOffset = .zero
        center.path = CGPath(ellipseIn: CGRect(x: s / 2 - 4, y: s / 2 - 4, width: 8, height: 8), transform: nil)
        center.fillColor = NSColor.white.cgColor
        view.layer?.addSublayer(ring)
        view.layer?.addSublayer(center)
        contentView = view
        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }

    func place(at p: Point2, fixating: Bool) {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.fillColor = NSColor.systemTeal.withAlphaComponent(fixating ? 0.45 : 0.12).cgColor
        CATransaction.commit()
        alphaValue = fixating ? 1 : 0.75
        let s = Self.size
        setFrameOrigin(NSPoint(x: p.x - s / 2, y: Double(primaryHeight) - p.y - s / 2))
    }
}
