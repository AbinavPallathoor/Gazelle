import Foundation

/// Per-frame features used for gaze mapping, derived from `FaceFeatures` (M4).
public struct GazeFeatures: Codable, Sendable, Equatable {
    public var timestamp: Double
    /// Mean of both eyes' eye-local iris offsets (eye widths, see `EyeLocal`).
    public var iris: Point2
    public var irisLeft: Point2
    public var irisRight: Point2
    /// Mean eye openness (height / width).
    public var openness: Double
    public var pose: HeadPose
    /// Face centre in normalised image coordinates (0…1, top-left origin).
    public var headPosition: Point2
    /// Distance between the two eye centres divided by image width. Grows as the head comes closer.
    public var headScale: Double
    /// Distance between eye centres in pixels, for viewing-distance estimates.
    public var interocularPx: Double
    public var imageWidth: Double
    /// Extra candidate features for offline analysis and richer models (nil in old profiles):
    /// - `cL.x`, `cL.y`, `cR.x`, `cR.y`: iris-ring centre relative to the eyelid-contour centre,
    ///   x along the corner axis ÷ eye width, y across it ÷ eye height (lid opening);
    /// - `bs.<name>`: backend eye blendshapes, e.g. `bs.eyeLookInLeft` (MediaPipe).
    public var extra: [String: Double]?
    /// Head-aligned eye-region landmark vector (`EyeRegion.features`), when available.
    public var eyeRegion: [Double]?

    public init(timestamp: Double, iris: Point2, irisLeft: Point2, irisRight: Point2, openness: Double,
                pose: HeadPose, headPosition: Point2, headScale: Double, interocularPx: Double, imageWidth: Double,
                extra: [String: Double]? = nil, eyeRegion: [Double]? = nil) {
        self.timestamp = timestamp
        self.iris = iris
        self.irisLeft = irisLeft
        self.irisRight = irisRight
        self.openness = openness
        self.pose = pose
        self.headPosition = headPosition
        self.headScale = headScale
        self.interocularPx = interocularPx
        self.imageWidth = imageWidth
        self.extra = extra
        self.eyeRegion = eyeRegion
    }

    /// Derives gaze features from a frame. Nil when the face or either eye is missing.
    public init?(_ f: FaceFeatures) {
        guard f.faceFound, let l = f.leftEye, let r = f.rightEye,
              let il = EyeLocal.irisOffset(l), let ir = EyeLocal.irisOffset(r),
              f.imageWidth > 0, f.imageHeight > 0 else { return nil }
        let lc = (l.inner + l.outer) * 0.5
        let rc = (r.inner + r.outer) * 0.5
        let iod = (rc - lc).length
        let center = f.faceBounds?.center ?? (lc + rc) * 0.5
        var extra: [String: Double] = [:]
        for (key, eye) in [("cL", l), ("cR", r)] {
            if let c = EyeLocal.contourOffset(eye) {
                extra[key + ".x"] = c.x
                extra[key + ".y"] = c.y
            }
        }
        for (name, value) in f.blendshapes ?? [:] { extra["bs." + name] = value }
        self.init(timestamp: f.timestamp,
                  iris: (il + ir) * 0.5, irisLeft: il, irisRight: ir,
                  openness: (l.openness + r.openness) / 2,
                  pose: f.headPose ?? HeadPose(yaw: 0, pitch: 0, roll: 0),
                  headPosition: Point2(center.x / f.imageWidth, center.y / f.imageHeight),
                  headScale: iod / f.imageWidth, interocularPx: iod, imageWidth: f.imageWidth,
                  extra: extra.isEmpty ? nil : extra,
                  eyeRegion: f.landmarks3D.flatMap(EyeRegion.features))
    }

    /// Element-wise mean of several frames (one fixation), used as a single online sample.
    public static func mean(_ fs: [GazeFeatures]) -> GazeFeatures? {
        guard let first = fs.first else { return nil }
        let n = Double(fs.count)
        func avg(_ k: (GazeFeatures) -> Double) -> Double { fs.reduce(0) { $0 + k($1) } / n }
        func avgP(_ k: (GazeFeatures) -> Point2) -> Point2 { Point2(avg { k($0).x }, avg { k($0).y }) }
        var eyeRegion: [Double]?
        if let len = first.eyeRegion?.count, fs.allSatisfy({ $0.eyeRegion?.count == len }) {
            var acc = [Double](repeating: 0, count: len)
            for f in fs { for (i, v) in f.eyeRegion!.enumerated() { acc[i] += v } }
            eyeRegion = acc.map { $0 / n }
        }
        return GazeFeatures(timestamp: fs.last!.timestamp, iris: avgP(\.iris), irisLeft: avgP(\.irisLeft),
                            irisRight: avgP(\.irisRight), openness: avg(\.openness),
                            pose: HeadPose(yaw: avg(\.pose.yaw), pitch: avg(\.pose.pitch), roll: avg(\.pose.roll)),
                            headPosition: avgP(\.headPosition), headScale: avg(\.headScale),
                            interocularPx: avg(\.interocularPx), imageWidth: first.imageWidth,
                            extra: nil, eyeRegion: eyeRegion)
    }

    /// Viewing distance in millimetres from the interocular distance, assuming an average adult
    /// eye-centre separation and the camera's horizontal field of view. Rough (±20 %), used only
    /// to express errors in degrees.
    public func viewingDistanceMM(horizontalFOVDegrees: Double = 70, interocularMM: Double = 62) -> Double {
        let focalPx = (imageWidth / 2) / tan(horizontalFOVDegrees * .pi / 360)
        return interocularMM * focalPx / max(interocularPx, 1)
    }
}

/// Blink gating: drops frames while the eyes close and reopen, plus a short settle time after,
/// because iris landmarks jump during blinks.
public struct BlinkGate: Sendable {
    /// A frame is a blink when openness falls below this fraction of the recent open level.
    public var closedRatio = 0.65
    /// Frames are still gated for this long after the eyes reopen.
    public var settleSeconds = 0.12
    private var openLevel: Double?
    private var gatedUntil = -Double.infinity
    public private(set) var isBlinking = false

    public init() {}

    /// Returns true if the frame should be used.
    public mutating func accept(_ f: GazeFeatures) -> Bool {
        guard let level = openLevel else {
            openLevel = f.openness
            return true
        }
        if f.openness < closedRatio * level {
            isBlinking = true
            gatedUntil = f.timestamp + settleSeconds
            return false
        }
        isBlinking = false
        // Track the open level slowly so squinting or lighting changes adapt over seconds.
        openLevel = level + 0.02 * (f.openness - level)
        return f.timestamp >= gatedUntil
    }
}

/// Face tracking state for the pipeline: tracking → lost (selection frozen, warning shown) →
/// paused after `pauseAfter` seconds without a face. Recovers as soon as the face is back.
public struct FaceTrackingState: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case tracking
        case lost(since: Double)
        case paused
    }

    public var pauseAfter = 2.0
    public private(set) var status: Status = .paused

    public init(pauseAfter: Double = 2.0) {
        self.pauseAfter = pauseAfter
    }

    public mutating func update(faceFound: Bool, at t: Double) {
        if faceFound {
            status = .tracking
            return
        }
        switch status {
        case .tracking: status = .lost(since: t)
        case .lost(let since) where t - since >= pauseAfter: status = .paused
        default: break
        }
    }

    public var isTracking: Bool { status == .tracking }
}

/// Detects a stalled camera: frames keep arriving but the features do not change at all.
///
/// Found in M5: when the window hosting the camera web view was covered, WebKit kept firing
/// frame callbacks with a stale video frame, so a whole calibration was fitted to one image.
/// Real faces always show micro-movement (iris std ≈ 0.001–0.003 eye widths at rest); a stale
/// frame gives ≈ 0.0001.
public struct StallDetector: Sendable {
    public var window = 1.0
    public var irisThreshold = 0.0003
    public var poseThreshold = 0.0005 // radians
    private var history: [(t: Double, iris: Point2, yaw: Double, pitch: Double)] = []
    public private(set) var isStalled = false

    public init() {}

    public mutating func update(_ f: GazeFeatures) {
        history.append((f.timestamp, f.iris, f.pose.yaw, f.pose.pitch))
        history.removeAll { $0.t < f.timestamp - window }
        guard let first = history.first, f.timestamp - first.t >= window * 0.8, history.count >= 10 else {
            isStalled = false
            return
        }
        let sx = Stats.std(history.map(\.iris.x)), sy = Stats.std(history.map(\.iris.y))
        let syaw = Stats.std(history.map(\.yaw)), spitch = Stats.std(history.map(\.pitch))
        isStalled = max(sx, sy) < irisThreshold && max(syaw, spitch) < poseThreshold
    }

    public mutating func reset() {
        history.removeAll()
        isStalled = false
    }
}
