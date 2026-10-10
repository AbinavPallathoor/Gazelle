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

    /// Mean of both eyes' offsets when both are available, otherwise whichever exists.
    public static func meanIrisOffset(_ f: FaceFeatures) -> Point2? {
        let offsets = [f.leftEye, f.rightEye].compactMap { $0.flatMap(irisOffset) }
        guard !offsets.isEmpty else { return nil }
        return offsets.reduce(Point2(0, 0), +) * (1 / Double(offsets.count))
    }
}
