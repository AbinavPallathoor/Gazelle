import Foundation

/// Iris position expressed in a frame attached to the eye corners.
///
/// The x axis runs along the corner-to-corner line, pointing towards image right for both eyes;
/// y is perpendicular, pointing image-down. The origin is the midpoint of the corners, and both
/// coordinates are divided by the corner distance. This cancels head roll, translation and scale.
public enum EyeLocal {
    public static func irisOffset(_ eye: EyeFeatures) -> Point2? {
        var axis = eye.outer - eye.inner
        let width = axis.length
        guard width > 1e-9 else { return nil }
        if axis.x < 0 { axis = axis * -1 }
        let u = axis * (1 / width)
        let v = Point2(-u.y, u.x)
        let mid = (eye.inner + eye.outer) * 0.5
        let d = eye.iris - mid
        return Point2(d.dot(u) / width, d.dot(v) / width)
    }

    /// Iris-ring centre relative to the eyelid-contour centre: x along the corner axis divided
    /// by eye width, y across it divided by the lid opening (contour extent across the axis).
    /// Normalising y by the opening rather than the width tracks vertical gaze better, since
    /// the lids follow the eye up and down. Nil without contour and ring points.
    public static func contourOffset(_ eye: EyeFeatures) -> Point2? {
        guard let contour = eye.contour, contour.count >= 4, let ring = eye.irisRing, !ring.isEmpty else { return nil }
        var axis = eye.outer - eye.inner
        let width = axis.length
        guard width > 1e-9 else { return nil }
        if axis.x < 0 { axis = axis * -1 }
        let u = axis * (1 / width)
        let v = Point2(-u.y, u.x)
        let cc = contour.reduce(Point2(0, 0), +) * (1 / Double(contour.count))
        let rc = ring.reduce(Point2(0, 0), +) * (1 / Double(ring.count))
        let across = contour.map { ($0 - cc).dot(v) }
        let height = (across.max() ?? 0) - (across.min() ?? 0)
        guard height > 1e-9 else { return nil }
        let d = rc - cc
        return Point2(d.dot(u) / width, d.dot(v) / height)
    }

    /// Mean of both eyes' offsets when both are available, otherwise whichever exists.
    public static func meanIrisOffset(_ f: FaceFeatures) -> Point2? {
        let offsets = [f.leftEye, f.rightEye].compactMap { $0.flatMap(irisOffset) }
        guard !offsets.isEmpty else { return nil }
        return offsets.reduce(Point2(0, 0), +) * (1 / Double(offsets.count))
    }
}
