import Foundation

/// A 2D point in image pixels, origin top-left, y down.
public struct Point2: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static func + (a: Point2, b: Point2) -> Point2 { Point2(a.x + b.x, a.y + b.y) }
    public static func - (a: Point2, b: Point2) -> Point2 { Point2(a.x - b.x, a.y - b.y) }
    public static func * (a: Point2, s: Double) -> Point2 { Point2(a.x * s, a.y * s) }
    public func dot(_ o: Point2) -> Double { x * o.x + y * o.y }
    public var length: Double { (x * x + y * y).squareRoot() }
}

/// An axis-aligned rectangle in image pixels, origin top-left.
public struct Rect2: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var center: Point2 { Point2(x + width / 2, y + height / 2) }
}

/// Landmarks for one eye, in image pixels.
public struct EyeFeatures: Codable, Sendable, Equatable {
    /// Corner nearest the nose.
    public var inner: Point2
    /// Corner nearest the temple.
    public var outer: Point2
    /// Iris (or pupil) centre.
    public var iris: Point2
    /// Eye opening height divided by eye width. Drops towards 0 during a blink.
    public var openness: Double
    /// Full eyelid contour, when the backend provides it (MediaPipe: 16 points).
    public var contour: [Point2]?
    /// Points on the iris boundary, when the backend provides them (MediaPipe: 4 points).
    public var irisRing: [Point2]?

    public init(inner: Point2, outer: Point2, iris: Point2, openness: Double,
                contour: [Point2]? = nil, irisRing: [Point2]? = nil) {
        self.inner = inner
        self.outer = outer
        self.iris = iris
        self.openness = openness
        self.contour = contour
        self.irisRing = irisRing
    }
}

/// Head rotation in radians. Sign conventions are still backend-specific; M4 normalises them.
/// The M0 metrics only regress on pose, so they do not depend on sign.
public struct HeadPose: Codable, Sendable, Equatable {
    public var yaw: Double
    public var pitch: Double
    public var roll: Double

    public init(yaw: Double, pitch: Double, roll: Double) {
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
    }
}

/// Features extracted from one camera frame. No pixels are ever stored.
public struct FaceFeatures: Codable, Sendable, Equatable {
    /// Capture time in seconds on a monotonic clock.
    public var timestamp: Double
    /// Backend identifier, e.g. "vision" or "mediapipe".
    public var backend: String
    /// Eye on the image's left side (the subject's right eye for an unmirrored camera).
    public var leftEye: EyeFeatures?
    /// Eye on the image's right side.
    public var rightEye: EyeFeatures?
    public var headPose: HeadPose?
    public var faceBounds: Rect2?
    /// 0 when no face was found.
    public var confidence: Double
    /// Time spent extracting features from this frame, in milliseconds.
    public var processingMs: Double
    public var imageWidth: Double
    public var imageHeight: Double
    /// Backend-specific scores, e.g. MediaPipe's eye blendshapes (`eyeLookInLeft`, …).
    public var blendshapes: [String: Double]?
    /// Eye-region landmarks in `EyeRegion.indices` order, flattened x, y, z (pixel-like units).
    public var landmarks3D: [Double]?

    public init(
        timestamp: Double, backend: String,
        leftEye: EyeFeatures? = nil, rightEye: EyeFeatures? = nil,
        headPose: HeadPose? = nil, faceBounds: Rect2? = nil,
        confidence: Double, processingMs: Double,
        imageWidth: Double, imageHeight: Double, blendshapes: [String: Double]? = nil
    ) {
        self.timestamp = timestamp
        self.backend = backend
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.headPose = headPose
        self.faceBounds = faceBounds
        self.confidence = confidence
        self.processingMs = processingMs
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.blendshapes = blendshapes
    }

    public var faceFound: Bool { confidence > 0 && leftEye != nil && rightEye != nil }
}

/// A source of per-frame face features. Implementations own the camera.
/// Frames where no face is found are still delivered, with `confidence == 0`.
/// Started and stopped from the main actor; implementations may produce features on any queue.
@MainActor
public protocol FaceFeatureProvider: AnyObject {
    var backendID: String { get }
    var features: AsyncStream<FaceFeatures> { get }
    func start() async throws
    func stop()
}
