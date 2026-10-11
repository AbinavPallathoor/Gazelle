import AppKit
import AVFoundation
import GazeKit
import os

private let log = Logger(subsystem: "dev.gazelle.Gazelle", category: "calibration")

/// Stores calibration profiles per display and camera in Application Support (numbers only).
enum ProfileStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Gazelle", isDirectory: true)
    }

    static func keys(for screen: NSScreen) -> (display: String, camera: String) {
        var display = "unknown-display"
        if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
           let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
            display = CFUUIDCreateString(nil, uuid) as String
        }
        let camera = AVCaptureDevice.default(for: .video)?.uniqueID ?? "default-camera"
        return (display, camera)
    }

    static func load(for screen: NSScreen) -> CalibrationProfile? {
        let k = keys(for: screen)
        let url = directory.appendingPathComponent(CalibrationProfile.fileName(displayKey: k.display, cameraKey: k.camera))
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try CalibrationProfile.decode(data)
        } catch {
            log.error("could not read profile \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    static func save(_ p: CalibrationProfile) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(CalibrationProfile.fileName(displayKey: p.displayKey, cameraKey: p.cameraKey))
        try p.encoded().write(to: url, options: .atomic)
        log.info("saved profile \(url.lastPathComponent, privacy: .public)")
    }

    /// Physical size of one point on `screen`, from the display's reported physical width.
    static func geometry(for screen: NSScreen) -> ScreenGeometry {
        if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            let mm = CGDisplayScreenSize(id)
            if mm.width > 0 { return ScreenGeometry(widthMM: Double(mm.width), widthPoints: Double(screen.frame.width)) }
        }
        return ScreenGeometry(mmPerPoint: 0.2) // typical laptop fallback
    }

    /// The screen's frame in global top-left points.
    static func topLeftFrame(of screen: NSScreen) -> Rect2 {
        let h = Double(NSScreen.screens.first?.frame.height ?? screen.frame.height)
        let f = screen.frame
        return ScreenSpace.topLeftRect(fromAppKit: Rect2(x: f.minX, y: f.minY, width: f.width, height: f.height), primaryHeight: h)
    }
}

/// Runs a calibration on the main display: dots, model fit, validation, and save or retry.
@MainActor
final class CalibrationController {
    var onFinished: ((CalibrationProfile?) -> Void)?

    private let pipeline: GazePipeline
    private var window: CalibrationWindow?
    private var session: CalibrationSession?
    private var screen: NSScreen?
    private var result: (CalibrationProfile, ValidationResult)?

    var isRunning: Bool { window != nil }

    init(pipeline: GazePipeline) {
        self.pipeline = pipeline
    }

    func start() {
        guard window == nil, let screen = NSScreen.main else { return }
        self.screen = screen
        let w = CalibrationWindow(screen: screen)
        w.onKey = { [weak self] key in self?.handleKey(key) }
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        pipeline.start()
        beginSession()
    }

    private func beginSession() {
        guard let screen else { return }
        result = nil
        session = CalibrationSession(area: ProfileStore.topLeftFrame(of: screen))
        window?.view.mode = .intro
        window?.view.needsDisplay = true
        pipeline.onFrame = { [weak self] f, t in self?.frame(f, t) }
    }

    private var introUntil: Double?

    private func frame(_ f: GazeFeatures?, _ t: Double) {
        guard var s = session, let view = window?.view else { return }
        // A short intro so the first dot is not rushed.
        if introUntil == nil { introUntil = t + 2.0 }
        if t < introUntil! {
            view.mode = .intro
            view.faceVisible = f != nil
            view.needsDisplay = true
            return
        }
        // A stalled camera must never feed calibration (M5 bug: a whole run fitted to one frame).
        view.stalled = pipeline.snapshot.stalled
        if view.stalled {
            view.needsDisplay = true
            return
        }
        s.update(f, at: t)
        session = s
        if s.isFinished {
            finish(s)
            return
        }
        if let step = s.currentStep {
            view.mode = .target(step)
            view.faceVisible = f != nil
            view.needsDisplay = true
        }
    }

    private func finish(_ s: CalibrationSession) {
        pipeline.onFrame = nil
        introUntil = nil
        guard let screen, let view = window?.view else { return }
        guard let (model, cv) = GazeModel.fitCrossValidated(s.samples) else {
            view.mode = .failed("Not enough usable samples (\(s.samples.count)). Check lighting and that your face is visible, then press R to retry.")
            view.needsDisplay = true
            return
        }
        let geometry = ProfileStore.geometry(for: screen)
        let validation = ValidationResult.evaluate(model, samples: s.validationSamples, geometry: geometry)
        let keys = ProfileStore.keys(for: screen)
        let profile = CalibrationProfile(createdAt: Date(), displayKey: keys.display, cameraKey: keys.camera,
                                         geometry: geometry, layout: .nine, model: model,
                                         crossValidatedErrorPoints: cv, validation: validation, samples: s.samples,
                                         validationSamples: s.validationSamples)
        result = (profile, validation)
        log.info("calibration models: \(model.comparison.map { "\($0.key) \(Int($0.value)) pt" }.sorted().joined(separator: ", "), privacy: .public); chose \(model.featureSet.rawValue, privacy: .public), λ ratio x \(model.ridge.lambdaRatioX) y \(model.ridge.lambdaRatioY)")
        log.info("calibration: \(s.samples.count) samples, cv \(cv, format: .fixed(precision: 1)) pt, validation \(validation.meanErrorDegrees, format: .fixed(precision: 2))° (\(validation.meanErrorPoints, format: .fixed(precision: 1)) pt), jitter \(validation.meanJitterDegrees, format: .fixed(precision: 2))°, distance \(validation.viewingDistanceMM, format: .fixed(precision: 0)) mm, skipped \(s.skippedTargets.count)")
        view.mode = .result(validation, skipped: s.skippedTargets.count)
        view.needsDisplay = true
    }

    private func handleKey(_ key: CalibrationWindow.Key) {
        switch key {
        case .cancel:
            close(saving: false)
        case .retry:
            beginSession()
        case .accept:
            guard result != nil else { return }
            close(saving: true)
        }
    }

    private func close(saving: Bool) {
        pipeline.onFrame = nil
        introUntil = nil
        var saved: CalibrationProfile?
        if saving, let (profile, _) = result {
            do {
                try ProfileStore.save(profile)
                saved = profile
            } catch {
                log.error("save failed: \(String(describing: error), privacy: .public)")
            }
        }
        window?.orderOut(nil)
        window = nil
        session = nil
        result = nil
        onFinished?(saved)
    }
}

/// Full-screen calibration window. Keys: Return accepts, R retries, Esc cancels.
final class CalibrationWindow: NSWindow {
    enum Key { case accept, retry, cancel }

    let view: CalibrationView
    var onKey: ((Key) -> Void)?

    init(screen: NSScreen) {
        view = CalibrationView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        backgroundColor = NSColor(white: 0.1, alpha: 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        contentView = view
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onKey?(.cancel)
        case 36, 76: onKey?(.accept)
        case 15: onKey?(.retry)
        default: super.keyDown(with: event)
        }
    }
}

final class CalibrationView: NSView {
    enum Mode {
        case intro
        case target(CalibrationSession.Step)
        case result(ValidationResult, skipped: Int)
        case failed(String)
    }

    var mode: Mode = .intro
    var faceVisible = false
    var stalled = false

    override var isFlipped: Bool { true } // match global top-left coordinates within the screen

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.1, alpha: 1).setFill()
        bounds.fill()
        guard let window else { return }
        let origin = ProfileStore.topLeftFrame(of: window.screen ?? NSScreen.main!)
        func local(_ p: Point2) -> NSPoint { NSPoint(x: p.x - origin.x, y: p.y - origin.y) }

        switch mode {
        case .intro:
            text("Gazelle calibration", at: NSPoint(x: bounds.midX, y: bounds.midY - 60), size: 28, weight: .semibold)
            text("Sit as you normally do. Follow each dot with your eyes until it shrinks away.", at: NSPoint(x: bounds.midX, y: bounds.midY - 20))
            text("Head still for the dots, then follow a moving dot, then keep looking at dots while slowly moving your head.",
                 at: NSPoint(x: bounds.midX, y: bounds.midY + 10))
            text(faceVisible ? "Face detected. Starting…" : "Looking for your face…",
                 at: NSPoint(x: bounds.midX, y: bounds.midY + 60), color: faceVisible ? .systemGreen : .systemOrange)
            text("Esc cancels", at: NSPoint(x: bounds.midX, y: bounds.maxY - 40), size: 12, color: .gray)

        case .target(let step):
            let c = local(step.target)
            let radius = 14 * (1 - 0.6 * step.progress)
            let color: NSColor = step.phase == .validation ? .systemTeal : .white
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)).fill()
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)).fill()
            let title: String
            switch step.phase {
            case .still: title = "Part 1 of 4: keep your head still · \(step.index + 1)/\(step.count)"
            case .pursuit: title = "Part 2 of 4: follow the moving dot with your eyes, head still"
            case .headMotion: title = "Part 3 of 4: keep looking at the dot and slowly move your head · \(step.index + 1)/\(step.count)"
            case .validation: title = "Part 4 of 4: checking accuracy · \(step.index + 1)/\(step.count)"
            case .done: title = ""
            }
            text(title, at: NSPoint(x: bounds.midX, y: bounds.maxY - 60), size: 14, color: .lightGray)
            if stalled {
                text("Camera frames stalled: paused until video resumes", at: NSPoint(x: bounds.midX, y: bounds.maxY - 36), size: 13, color: .systemRed)
            } else if !faceVisible {
                text("Face not visible", at: NSPoint(x: bounds.midX, y: bounds.maxY - 36), size: 13, color: .systemOrange)
            }

        case .result(let v, let skipped):
            for p in v.points {
                let t = local(p.target), m = local(p.meanPrediction)
                NSColor.systemTeal.setFill()
                NSBezierPath(ovalIn: NSRect(x: t.x - 6, y: t.y - 6, width: 12, height: 12)).fill()
                NSColor.systemYellow.setStroke()
                let line = NSBezierPath()
                line.move(to: t)
                line.line(to: m)
                line.lineWidth = 2
                line.stroke()
                NSColor.systemYellow.setFill()
                NSBezierPath(ovalIn: NSRect(x: m.x - 4, y: m.y - 4, width: 8, height: 8)).fill()
            }
            text(String(format: "Accuracy: %.2f° (%.0f pt) · jitter %.2f° · viewing distance ≈ %.0f mm",
                        v.meanErrorDegrees, v.meanErrorPoints, v.meanJitterDegrees, v.viewingDistanceMM),
                 at: NSPoint(x: bounds.midX, y: bounds.midY - 20), size: 20, weight: .semibold)
            text("Teal: validation dots. Yellow: where Gazelle thought you looked." + (skipped > 0 ? " \(skipped) dot(s) had too few samples." : ""),
                 at: NSPoint(x: bounds.midX, y: bounds.midY + 14), color: .lightGray)
            text("Return: save   ·   R: recalibrate   ·   Esc: discard", at: NSPoint(x: bounds.midX, y: bounds.midY + 50))

        case .failed(let message):
            text(message, at: NSPoint(x: bounds.midX, y: bounds.midY), color: .systemOrange)
        }
    }

    private func text(_ s: String, at p: NSPoint, size: CGFloat = 15, weight: NSFont.Weight = .regular, color: NSColor = .white) {
        let a = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        let sz = a.size()
        a.draw(at: NSPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2))
    }
}
