import CoreVideo
import Foundation
import GazeKit
import Vision

/// Face features from Apple Vision's `VNDetectFaceLandmarksRequest`.
/// Iris centres come from Vision's pupil landmarks, which Apple notes may be inaccurate during blinks.
@MainActor
public final class AppleVisionProvider: FaceFeatureProvider {
    public nonisolated let backendID = "vision"
    public nonisolated let features: AsyncStream<FaceFeatures>
    private nonisolated let continuation: AsyncStream<FaceFeatures>.Continuation
    private let camera = CameraCapture()

    public init() {
        (features, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    public func start() async throws {
        camera.onFrame = { [weak self] pb, t in self?.process(pb, timestamp: t) }
        try await camera.start()
    }

    public func stop() {
        camera.stop()
        continuation.finish()
    }

    private nonisolated func process(_ pb: CVPixelBuffer, timestamp: Double) {
        let w = Double(CVPixelBufferGetWidth(pb))
        let h = Double(CVPixelBufferGetHeight(pb))
        let start = DispatchTime.now().uptimeNanoseconds
        // Head pose comes from the rectangles request (rev 3) performed in the same call.
        // M0 testing: a landmarks request alone, or a VNSequenceRequestHandler, returned pose
        // as 0 or in 30° steps; this combination gives continuous yaw/pitch/roll.
        let rects = VNDetectFaceRectanglesRequest()
        rects.revision = VNDetectFaceRectanglesRequestRevision3
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        try? VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up).perform([rects, request])
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6

        var out = FaceFeatures(timestamp: timestamp, backend: backendID, confidence: 0,
                               processingMs: ms, imageWidth: w, imageHeight: h)
        if let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) {
            let bb = face.boundingBox
            out.faceBounds = Rect2(x: bb.minX * w, y: (1 - bb.maxY) * h, width: bb.width * w, height: bb.height * h)
            let pose = rects.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) ?? face
            out.headPose = HeadPose(yaw: pose.yaw?.doubleValue ?? 0,
                                    pitch: pose.pitch?.doubleValue ?? 0,
                                    roll: pose.roll?.doubleValue ?? 0)
            if let lm = face.landmarks,
               let a = Self.eye(region: lm.leftEye, pupil: lm.leftPupil, w: w, h: h),
               let b = Self.eye(region: lm.rightEye, pupil: lm.rightPupil, w: w, h: h) {
                // Assign by image side, not by Vision's naming.
                let (l, r) = a.inner.x + a.outer.x < b.inner.x + b.outer.x ? (a, b) : (b, a)
                let cx = (r.inner.x + r.outer.x + l.inner.x + l.outer.x) / 4
                out.leftEye = Self.orientCorners(l, faceCenterX: cx)
                out.rightEye = Self.orientCorners(r, faceCenterX: cx)
                out.confidence = Double(lm.confidence)
            }
        }
        continuation.yield(out)
    }

    /// Converts a Vision eye region to image-top-left pixels. Corners are the extreme points along x.
    nonisolated static func eye(region: VNFaceLandmarkRegion2D?, pupil: VNFaceLandmarkRegion2D?, w: Double, h: Double) -> EyeFeatures? {
        guard let region, let pupil, region.pointCount >= 4, pupil.pointCount >= 1 else { return nil }
        let size = CGSize(width: w, height: h)
        let pts = region.pointsInImage(imageSize: size).map { Point2(Double($0.x), h - Double($0.y)) }
        let p = pupil.pointsInImage(imageSize: size)[0]
        guard let minX = pts.min(by: { $0.x < $1.x }), let maxX = pts.max(by: { $0.x < $1.x }) else { return nil }
        let width = (maxX - minX).length
        let height = (pts.map(\.y).max()! - pts.map(\.y).min()!)
        return EyeFeatures(inner: minX, outer: maxX, iris: Point2(Double(p.x), h - Double(p.y)),
                           openness: width > 0 ? height / width : 0)
    }

    /// Makes `inner` the corner nearer the face centre.
    nonisolated static func orientCorners(_ e: EyeFeatures, faceCenterX: Double) -> EyeFeatures {
        var e = e
        if abs(e.outer.x - faceCenterX) < abs(e.inner.x - faceCenterX) { swap(&e.inner, &e.outer) }
        return e
    }
}
