import AppKit
import GazeKit

/// Debug HUD (PLAN.md §1): live camera pipeline numbers, eye features and an iris plot.
/// Click-through, top-right of the main display. The on-screen gaze dot is `GazeDotOverlay`.
@MainActor
final class DebugHUD {
    private var panel: HUDPanel?
    private(set) var isVisible = false

    func show() {
        guard !isVisible else { return }
        isVisible = true
        let p = HUDPanel()
        p.orderFrontRegardless()
        panel = p
    }

    func hide() {
        isVisible = false
        panel?.orderOut(nil)
        panel = nil
    }

    func update(_ s: PipelineSnapshot, validation: ValidationResult?) {
        guard let panel else { return }
        panel.view.snapshot = s
        panel.view.validation = validation
        panel.view.needsDisplay = true
    }
}

private final class HUDPanel: NSPanel {
    let view = HUDView(frame: NSRect(x: 0, y: 0, width: 340, height: 350))

    init() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: screen.maxX - 356, y: screen.maxY - 366, width: 340, height: 350)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)) + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        contentView = view
    }

    override var canBecomeKey: Bool { false }
}

private final class HUDView: NSView {
    var snapshot = PipelineSnapshot()
    var validation: ValidationResult?

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        NSColor.black.withAlphaComponent(0.78).setFill()
        bg.fill()

        let s = snapshot
        var lines: [(String, NSColor)] = []
        let white = NSColor.white, dim = NSColor(white: 0.7, alpha: 1)
        if let e = s.error { lines.append(("Camera error: \(e)", .systemRed)) }
        if s.stalled { lines.append(("CAMERA STALLED: frames not updating", .systemRed)) }
        let faceText: (String, NSColor)
        switch s.face {
        case .tracking: faceText = ("face: tracking", .systemGreen)
        case .lost: faceText = ("face: LOST (selection frozen)", .systemOrange)
        case .paused: faceText = (s.running ? "face: none: PAUSED" : "camera off", .systemRed)
        }
        lines.append(faceText)
        lines.append((String(format: "%.0f fps · %.1f ms/frame · CPU %@ · %@", s.fps, s.processingMsP50,
                             s.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "–", s.resolution), white))
        if let f = s.features {
            lines.append((String(format: "iris  L %+.3f %+.3f   R %+.3f %+.3f", f.irisLeft.x, f.irisLeft.y, f.irisRight.x, f.irisRight.y), white))
            if let e = f.extra, let lx = e["cL.x"], let ly = e["cL.y"], let rx = e["cR.x"], let ry = e["cR.y"] {
                lines.append((String(format: "lid-rel L %+.3f %+.3f  R %+.3f %+.3f", lx, ly, rx, ry), white))
            }
            if let e = f.extra, let inL = e["bs.eyeLookInLeft"], let outL = e["bs.eyeLookOutLeft"],
               let upL = e["bs.eyeLookUpLeft"], let downL = e["bs.eyeLookDownLeft"] {
                lines.append((String(format: "look L in %.2f out %.2f up %.2f down %.2f", inL, outL, upL, downL), white))
            }
            lines.append(("eye-region features: " + (f.eyeRegion.map { "✓ \($0.count)" } ?? "✗"), f.eyeRegion == nil ? .systemOrange : white))
            lines.append((String(format: "open %.2f %@", f.openness, s.blinking ? "BLINK (gated)" : ""), s.blinking ? .systemYellow : white))
            let d = 180 / Double.pi
            lines.append((String(format: "head yaw %+.1f° pitch %+.1f° roll %+.1f°", f.pose.yaw * d, f.pose.pitch * d, f.pose.roll * d), white))
            lines.append((String(format: "head pos %.2f,%.2f  dist ≈ %.0f mm", f.headPosition.x, f.headPosition.y, f.viewingDistanceMM()), white))
        }
        if s.calibrated {
            if let g = s.gaze {
                lines.append((String(format: "gaze %.0f, %.0f %@", g.x, g.y, s.fixating ? "· fixating" : ""), .systemTeal))
            }
            if let v = validation {
                lines.append((String(format: "calibration: %.2f° (%.0f pt), jitter %.2f°", v.meanErrorDegrees, v.meanErrorPoints, v.meanJitterDegrees), dim))
            }
        } else {
            lines.append(("not calibrated: menu → Calibrate…", dim))
        }

        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        var y = bounds.maxY - 22
        for (text, color) in lines {
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
                .draw(at: NSPoint(x: 12, y: y))
            y -= 17
        }

        // Iris plot: each eye's offset within ±0.2 eye widths.
        let plot = NSRect(x: 12, y: 12, width: 120, height: 90)
        NSColor(white: 1, alpha: 0.15).setStroke()
        NSBezierPath(rect: plot).stroke()
        NSBezierPath.strokeLine(from: NSPoint(x: plot.midX, y: plot.minY), to: NSPoint(x: plot.midX, y: plot.maxY))
        NSBezierPath.strokeLine(from: NSPoint(x: plot.minX, y: plot.midY), to: NSPoint(x: plot.maxX, y: plot.midY))
        if let f = s.features {
            for (p, c) in [(f.irisLeft, NSColor.systemPink), (f.irisRight, NSColor.systemCyan)] {
                let x = plot.midX + CGFloat(p.x / 0.2) * plot.width / 2
                let y = plot.midY - CGFloat(p.y / 0.2) * plot.height / 2
                c.setFill()
                NSBezierPath(ovalIn: NSRect(x: x - 3, y: y - 3, width: 6, height: 6)).fill()
            }
        }
        NSAttributedString(string: "iris L/R (±0.2 ew)", attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: dim])
            .draw(at: NSPoint(x: plot.maxX + 8, y: plot.minY))
    }
}
