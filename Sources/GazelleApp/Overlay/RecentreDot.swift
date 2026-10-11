import AppKit
import GazeKit

/// The dot shown during a one-point re-centre: high-contrast, above everything, click-through.
@MainActor
final class RecentreDot {
    private var panel: NSPanel?

    func show(at p: Point2) {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        let size: CGFloat = 120
        let panel = NSPanel(contentRect: NSRect(x: p.x - size / 2, y: Double(primaryHeight) - p.y - size / 2, width: size, height: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        let view = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.wantsLayer = true
        for (radius, color) in [(18.0, NSColor.white), (5.0, NSColor.systemRed)] {
            let l = CAShapeLayer()
            l.path = CGPath(ellipseIn: CGRect(x: size / 2 - radius, y: size / 2 - radius, width: 2 * radius, height: 2 * radius), transform: nil)
            l.fillColor = color.cgColor
            l.shadowColor = NSColor.black.cgColor
            l.shadowOpacity = 0.7
            l.shadowRadius = 4
            l.shadowOffset = .zero
            view.layer?.addSublayer(l)
        }
        let label = NSTextField(labelWithString: "Look here")
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.frame = NSRect(x: 0, y: 4, width: size, height: 16)
        label.alignment = .center
        view.addSubview(label)
        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}
