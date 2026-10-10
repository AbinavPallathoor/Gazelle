import AppKit
import Foundation
import GazeKit
import GazeVision

/// Shows a fixation dot full-screen, streams features from one backend and writes them as JSONL.
@MainActor
final class Recorder {
    struct Config {
        var backend: Backend
        var label: String
        var seconds: Double
        var countdown: Double
        var delegate: String
        var outDir: URL
    }

    let config: Config
    private let window: FixationWindow
    private let cpu = ProcessCPU()
    private var file: FileHandle?
    private var recording = false
    private var aborted = false
    private var framesSinceTick = 0
    private var foundSinceTick = 0
    private var latencySinceTick: [Double] = []

    init(config: Config) {
        self.config = config
        window = FixationWindow()
        window.onEscape = { [weak self] in self?.aborted = true }
    }

    func run() async {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.view.status = "Starting \(config.backend.rawValue)…"

        let provider: FaceFeatureProvider
        switch config.backend {
        case .vision:
            provider = AppleVisionProvider()
        case .mediapipe:
            let mp = MediaPipeWebProvider(delegate: config.delegate)
            window.embed(mp.webView)
            provider = mp
        }

        do {
            try await provider.start()
        } catch {
            fail("\(config.backend.rawValue) failed to start: \(error)")
        }

        let consumer = Task { @MainActor in
            for await f in provider.features { self.consume(f) }
        }

        // Countdown: frames arrive but are not recorded (warm-up).
        let countdownEnd = Date().addingTimeInterval(config.countdown)
        while Date() < countdownEnd, !aborted {
            window.view.status = String(format: "%@ Recording starts in %.0f s. Esc aborts.",
                                        instruction, countdownEnd.timeIntervalSinceNow.rounded(.up))
            tick(printing: false)
            try? await Task.sleep(for: .seconds(1))
        }

        try? FileManager.default.createDirectory(at: config.outDir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let name = "\(config.backend.rawValue)\(config.backend == .mediapipe ? "-" + config.delegate.lowercased() : "")-\(config.label)-\(stamp).jsonl"
        let url = config.outDir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try? FileHandle(forWritingTo: url)
        write(RecordLine(meta: RecordingMeta(backend: config.backend.rawValue, label: config.label, startedAt: Date(),
                                             note: config.backend == .mediapipe ? "delegate=\(config.delegate)" : nil)))
        _ = cpu.sample()
        recording = true

        let end = Date().addingTimeInterval(config.seconds)
        while Date() < end, !aborted {
            try? await Task.sleep(for: .seconds(1))
            if let pct = cpu.sample() {
                write(RecordLine(cpu: CPUSample(timestamp: Double(DispatchTime.now().uptimeNanoseconds) / 1e9, percent: pct)))
            }
            let left = end.timeIntervalSinceNow.rounded(.up)
            window.view.status = String(format: "Recording “%@”: %.0f s left. %@", config.label, max(0, left), instruction)
            tick(printing: true)
        }

        recording = false
        provider.stop()
        consumer.cancel()
        try? file?.close()
        file = nil
        window.orderOut(nil)

        if aborted {
            try? FileManager.default.removeItem(at: url)
            fail("aborted; recording discarded")
        }
        let helpers = cpu.helperNames()
        if !helpers.isEmpty { print("CPU includes helper processes: \(Set(helpers).sorted().joined(separator: ", "))") }
        print("Saved \(url.path)\n")
        if let rec = try? Recording.decode(jsonl: Data(contentsOf: url)) {
            print(SessionMetrics.tableHeader)
            print(SessionMetrics(recording: rec).tableRow)
        }
    }

    private var instruction: String {
        switch config.label {
        case "still": return "Keep your head still and look at the dot."
        case "moving": return "Keep looking at the dot while slowly moving, turning and tilting your head."
        default: return "Look at the dot."
        }
    }

    private func consume(_ f: FaceFeatures) {
        framesSinceTick += 1
        if f.faceFound { foundSinceTick += 1 }
        latencySinceTick.append(f.processingMs)
        if recording { write(RecordLine(frame: f)) }
    }

    private func tick(printing: Bool) {
        let line = String(format: "fps %2d  face %3.0f%%  latency p50 %.1f ms",
                          framesSinceTick,
                          framesSinceTick > 0 ? 100 * Double(foundSinceTick) / Double(framesSinceTick) : 0,
                          Stats.median(latencySinceTick))
        window.view.detail = line
        if printing { print(line) }
        framesSinceTick = 0
        foundSinceTick = 0
        latencySinceTick.removeAll(keepingCapacity: true)
    }

    private func write(_ line: RecordLine) {
        guard let file, let data = try? Recording.encodeLine(line) else { return }
        file.write(data)
    }
}

/// Borderless full-screen window with a fixation dot in the centre of the main screen.
final class FixationWindow: NSWindow {
    let view = FixationView()
    var onEscape: (() -> Void)?

    init() {
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .floating
        backgroundColor = NSColor(white: 0.12, alpha: 1)
        contentView = view
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }

    /// Places a camera preview (e.g. the MediaPipe web view) in the bottom-left corner.
    func embed(_ sub: NSView) {
        sub.frame = NSRect(x: 24, y: 24, width: 256, height: 144)
        view.addSubview(sub)
    }
}

final class FixationView: NSView {
    var status = "" { didSet { needsDisplay = true } }
    var detail = "" { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.12, alpha: 1).setFill()
        bounds.fill()
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18)).fill()
        NSColor.red.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(white: 0.8, alpha: 1),
            .font: NSFont.systemFont(ofSize: 16),
        ]
        for (i, s) in [status, detail].enumerated() {
            let str = NSAttributedString(string: s, attributes: attrs)
            str.draw(at: NSPoint(x: c.x - str.size().width / 2, y: c.y - 80 - CGFloat(i) * 26))
        }
    }
}
