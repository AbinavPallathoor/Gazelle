import Foundation

/// Summary numbers for one recording, used to compare vision backends (M0).
///
/// Iris jitter is in eye-width units (see `EyeLocal`). As a rough guide, 0.01 eye widths is
/// about 0.3 mm of iris travel, or roughly 1.4° of eye rotation.
public struct SessionMetrics: Sendable, Equatable {
    public var backend: String
    public var label: String
    public var frames: Int
    public var durationS: Double
    public var fps: Double
    public var latencyP50Ms: Double
    public var latencyP95Ms: Double
    public var cpuPercent: Double
    public var faceFoundPercent: Double
    public var blinkPercent: Double
    /// Std of the eye-local iris offset (RMS of x and y) over open-eye frames.
    public var irisStd: Double
    /// Frame-to-frame iris jitter (RMS of x and y), insensitive to slow drift.
    public var irisFrameJitter: Double
    /// Iris std left after regressing out head pose and face position/size.
    /// While gaze stays on one point, this is the noise a head-aware mapping would still see.
    public var irisResidualStd: Double
    public var yawStdDeg: Double
    public var pitchStdDeg: Double
    public var rollStdDeg: Double

    /// Frames whose openness falls below this fraction of the median count as blinks.
    public static let blinkRatio = 0.6

    public init(recording rec: Recording) {
        let frames = rec.frames
        backend = rec.meta?.backend ?? frames.first?.backend ?? "?"
        label = rec.meta?.label ?? "?"
        self.frames = frames.count
        let t = frames.map(\.timestamp)
        durationS = (t.max() ?? 0) - (t.min() ?? 0)
        fps = durationS > 0 ? Double(frames.count - 1) / durationS : .nan
        let lat = frames.map(\.processingMs)
        latencyP50Ms = Stats.percentile(lat, 50)
        latencyP95Ms = Stats.percentile(lat, 95)
        cpuPercent = Stats.mean(rec.cpu.map(\.percent))

        let found = frames.filter(\.faceFound)
        faceFoundPercent = frames.isEmpty ? .nan : 100 * Double(found.count) / Double(frames.count)

        func openness(_ f: FaceFeatures) -> Double {
            Stats.mean([f.leftEye, f.rightEye].compactMap { $0?.openness })
        }
        let medianOpen = Stats.median(found.map(openness))
        let open = found.filter { openness($0) >= SessionMetrics.blinkRatio * medianOpen }
        blinkPercent = found.isEmpty ? .nan : 100 * Double(found.count - open.count) / Double(found.count)

        let usable = open.compactMap { f in EyeLocal.meanIrisOffset(f).map { (f, $0) } }
        let xs = usable.map(\.1.x)
        let ys = usable.map(\.1.y)
        irisStd = SessionMetrics.rms(Stats.std(xs), Stats.std(ys))
        irisFrameJitter = SessionMetrics.rms(
            Stats.successiveDifferenceJitter(xs), Stats.successiveDifferenceJitter(ys))

        let rows = usable.map { SessionMetrics.headRow($0.0) }
        func residualStd(_ target: [Double]) -> Double {
            guard let p = rows.first?.count, rows.count > 3 * p,
                  let model = Ridge(x: rows, y: target, lambda: 1e-6) else { return .nan }
            return Stats.std(zip(rows, target).map { $1 - model.predict($0) })
        }
        irisResidualStd = SessionMetrics.rms(residualStd(xs), residualStd(ys))

        let poses = found.compactMap(\.headPose)
        let deg = 180 / Double.pi
        yawStdDeg = Stats.std(poses.map(\.yaw)) * deg
        pitchStdDeg = Stats.std(poses.map(\.pitch)) * deg
        rollStdDeg = Stats.std(poses.map(\.roll)) * deg
    }

    /// Regressors for head-motion compensation: intercept, pose and normalised face position/size.
    static func headRow(_ f: FaceFeatures) -> [Double] {
        let p = f.headPose ?? HeadPose(yaw: 0, pitch: 0, roll: 0)
        let b = f.faceBounds ?? Rect2(x: 0, y: 0, width: 0, height: 0)
        let w = max(f.imageWidth, 1)
        let h = max(f.imageHeight, 1)
        return [1, p.yaw, p.pitch, p.roll, b.center.x / w, b.center.y / h, b.width / w]
    }

    static func rms(_ a: Double, _ b: Double) -> Double { (a * a + b * b).squareRoot() }

    public static let tableHeader = """
        | backend | label | frames | fps | latency p50/p95 ms | CPU % | face % | blink % | iris std (ew) | iris frame jitter (ew) | iris residual after head regression (ew) | yaw/pitch/roll std ° |
        |---|---|---|---|---|---|---|---|---|---|---|---|
        """

    public var tableRow: String {
        func f(_ v: Double, _ d: Int) -> String { v.isNaN ? "–" : String(format: "%.\(d)f", v) }
        return "| \(backend) | \(label) | \(frames) | \(f(fps, 1)) | \(f(latencyP50Ms, 1)) / \(f(latencyP95Ms, 1)) | \(f(cpuPercent, 0)) | \(f(faceFoundPercent, 1)) | \(f(blinkPercent, 1)) | \(f(irisStd, 4)) | \(f(irisFrameJitter, 4)) | \(f(irisResidualStd, 4)) | \(f(yawStdDeg, 1)) / \(f(pitchStdDeg, 1)) / \(f(rollStdDeg, 1)) |"
    }
}
