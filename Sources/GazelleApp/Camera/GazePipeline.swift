import AppKit
import Combine
import GazeKit
import GazeVision
import os

private let log = Logger(subsystem: "dev.gazelle.Gazelle", category: "camera")

/// What the HUD shows, refreshed a few times per second.
struct PipelineSnapshot: Equatable {
    var running = false
    var fps = 0.0
    var processingMsP50 = 0.0
    var cpuPercent: Double?
    var face: FaceTrackingState.Status = .paused
    var features: GazeFeatures?
    var blinking = false
    var gaze: Point2?
    var fixating = false
    /// Frames arrive but nothing changes: the camera web view is not getting new video.
    var stalled = false
    var calibrated = false
    var error: String?
    var resolution = ""
}

/// Runs the chosen vision backend (MediaPipe in a WKWebView, ADR 0001) continuously and turns
/// frames into gaze features: blink gating, face-lost handling, and, once calibrated, a
/// filtered gaze point. Camera frames never leave the web view; only numbers arrive here.
@MainActor
final class GazePipeline: ObservableObject {
    @Published private(set) var snapshot = PipelineSnapshot()
    /// Every frame (nil features when no face), for calibration.
    var onFrame: ((GazeFeatures?, Double) -> Void)?
    /// Filtered gaze point in global top-left points, for consumers (debug dot now, snapping in M6).
    var onGaze: ((Point2, Bool) -> Void)?

    private(set) var profile: CalibrationProfile?
    private var provider: MediaPipeWebProvider?
    private var host: CameraHostPanel?
    private var consumer: Task<Void, Never>?
    private var face = FaceTrackingState(pauseAfter: 2)
    private var blink = BlinkGate()
    private var stall = StallDetector()
    private var smoother = OneEuroFilter2D(minCutoff: 0.8, beta: 0.004)
    private var fixation = FixationDetector(maxDispersion: 60, minDuration: 0.15, saccadeSpeed: 1500)
    private let cpu = ProcessCPU()
    private var frameTimes: [Double] = []
    private var processing: [Double] = []
    private var publishTimer: Timer?
    private var latestFeatures: GazeFeatures?
    private var latestGaze: Point2?

    /// Camera resolution. 640×480 saved only ~4 % CPU (46 % vs 50 %) in M4, so the higher
    /// resolution is kept for more pixels on the eyes (ADR 0006).
    static let videoSize = (width: 1280, height: 720)

    var isRunning: Bool { provider != nil }

    func setProfile(_ p: CalibrationProfile?) {
        profile = p
        smoother.reset()
        fixation.reset()
    }

    func start() {
        guard provider == nil else { return }
        let p = MediaPipeWebProvider(videoWidth: Self.videoSize.width, videoHeight: Self.videoSize.height)
        let host = CameraHostPanel(webView: p.webView)
        host.orderFrontRegardless()
        provider = p
        self.host = host
        snapshot.running = true
        snapshot.error = nil
        snapshot.resolution = "\(Self.videoSize.width)×\(Self.videoSize.height)"
        face = FaceTrackingState(pauseAfter: 2)
        _ = cpu.sample()
        publishTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        }
        consumer = Task { [weak self] in
            do {
                try await p.start()
                log.info("camera pipeline started")
            } catch {
                log.error("camera pipeline failed: \(String(describing: error), privacy: .public)")
                self?.snapshot.error = String(describing: error)
                return
            }
            for await f in p.features {
                self?.consume(f)
            }
        }
    }

    func stop() {
        consumer?.cancel()
        consumer = nil
        provider?.stop()
        provider = nil
        host?.orderOut(nil)
        host = nil
        publishTimer?.invalidate()
        publishTimer = nil
        snapshot = PipelineSnapshot(calibrated: profile != nil)
        latestFeatures = nil
        latestGaze = nil
        log.info("camera pipeline stopped")
    }

    private func consume(_ raw: FaceFeatures) {
        let t = raw.timestamp
        frameTimes.append(t)
        processing.append(raw.processingMs)
        let g = GazeFeatures(raw)
        face.update(faceFound: g != nil, at: t)
        if let g { stall.update(g) } else { stall.reset() }
        var usable: GazeFeatures?
        if let g, !stall.isStalled, blink.accept(g) { usable = g }
        latestFeatures = g
        onFrame?(usable, t)

        guard let usable, let profile else { return }
        let point = smoother.filter(profile.model.predict(usable), at: t)
        fixation.add(point, at: t)
        latestGaze = point
        onGaze?(point, fixation.isFixating)
    }

    private func publish() {
        let now = frameTimes.last ?? 0
        frameTimes.removeAll { $0 < now - 1 }
        if processing.count > 60 { processing.removeFirst(processing.count - 60) }
        var s = snapshot
        s.fps = Double(frameTimes.count)
        s.processingMsP50 = Stats.median(processing)
        if let c = cpu.sample() { s.cpuPercent = c }
        s.face = face.status
        s.features = latestFeatures
        s.blinking = blink.isBlinking
        s.gaze = face.isTracking ? latestGaze : nil
        s.fixating = fixation.isFixating
        s.stalled = stall.isStalled
        s.calibrated = profile != nil
        snapshot = s
    }
}

/// Hosts the MediaPipe web view. WebKit only delivers *new* camera frames to a view in a window
/// that is on screen and not covered: when the full-screen calibration window covered it, frame
/// callbacks kept firing with a stale image (see `StallDetector`). So this tiny, nearly
/// transparent, click-through panel sits above everything, including the calibration screen,
/// in the bottom-left corner, on all Spaces.
final class CameraHostPanel: NSPanel {
    init(webView: NSView) {
        let size = NSSize(width: 64, height: 48)
        let origin = NSScreen.main.map { NSPoint(x: $0.frame.minX, y: $0.frame.minY) } ?? .zero
        super.init(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        alphaValue = 0.02
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        webView.frame = NSRect(origin: .zero, size: size)
        contentView = webView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
