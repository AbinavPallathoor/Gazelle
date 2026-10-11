import Foundation

/// Head-aligned eye-region landmark features, after EyeTrax (`ck-zhang/EyeTrax`, MIT,
/// `GazeEstimator.extract_features`; logic ported, see docs/THIRD_PARTY.md).
///
/// About 160 MediaPipe landmarks around both eyes (iris, lids, brows, upper cheeks) plus a few
/// face anchors are expressed in a frame attached to the head: origin between the outer eye
/// corners, x towards the other corner, y towards the top of the head, z out of the face, and
/// divided by the corner distance. Vertical gaze shows up mostly as lid and brow movement
/// relative to the face, which this captures and an iris-within-eye offset does not
/// (`shaal/eye-tracker` ADR-0025 measured the latter collapsing on real hardware).
public enum EyeRegion {
    /// MediaPipe Face Mesh indices, in EyeTrax order: left eye region (76), right eye region (76),
    /// mutual face anchors (9).
    public static let indices: [Int] = [
        107, 66, 105, 63, 70, 55, 65, 52, 53, 46, 468, 469, 470, 471, 472, 133, 33,
        173, 157, 158, 159, 160, 161, 246, 155, 154, 153, 145, 144, 163, 7,
        243, 190, 56, 28, 27, 29, 30, 247, 130, 25, 110, 24, 23, 22, 26, 112,
        244, 189, 221, 222, 223, 224, 225, 113, 226, 31, 228, 229, 230, 231, 232, 233,
        193, 245, 128, 121, 120, 119, 118, 117, 111, 35, 124, 143, 156,
        336, 296, 334, 293, 300, 285, 295, 282, 283, 276, 473, 476, 475, 474, 477, 362, 263,
        398, 384, 385, 386, 387, 388, 466, 382, 381, 380, 374, 373, 390, 249,
        463, 414, 286, 258, 257, 259, 260, 467, 359, 255, 339, 254, 253, 252, 256, 341,
        464, 413, 441, 442, 443, 444, 445, 342, 446, 261, 448, 449, 450, 451, 452, 453,
        417, 465, 357, 350, 349, 348, 347, 346, 340, 265, 353, 372, 383,
        4, 10, 151, 9, 152, 234, 454, 58, 288,
    ]

    static let leftCorner = indices.firstIndex(of: 33)!
    static let rightCorner = indices.firstIndex(of: 263)!
    static let topOfHead = indices.firstIndex(of: 10)!

    /// Number of values `features(_:)` returns: 3 per landmark plus yaw, pitch, roll.
    public static let featureCount = indices.count * 3 + 3

    /// - Parameter points: landmarks in `indices` order, flattened as x, y, z in pixel-like
    ///   units (x and z scaled by image width, y by image height, so axes share a unit).
    public static func features(_ points: [Double]) -> [Double]? {
        guard points.count == indices.count * 3 else { return nil }
        func p(_ i: Int) -> SIMD3<Double> { SIMD3(points[3 * i], points[3 * i + 1], points[3 * i + 2]) }
        let l = p(leftCorner), r = p(rightCorner), top = p(topOfHead)
        let center = (l + r) / 2
        var x = r - l
        let dist = (x * x).sum().squareRoot()
        guard dist > 1e-9 else { return nil }
        x /= dist
        var y = top - center
        y -= (y * x).sum() * x
        let ny = (y * y).sum().squareRoot()
        guard ny > 1e-9 else { return nil }
        y /= ny
        let z = SIMD3(x.y * y.z - x.z * y.y, x.z * y.x - x.x * y.z, x.x * y.y - x.y * y.x)

        var out = [Double]()
        out.reserveCapacity(featureCount)
        for i in 0..<indices.count {
            let d = p(i) - center
            out.append((d * x).sum() / dist)
            out.append((d * y).sum() / dist)
            out.append((d * z).sum() / dist)
        }
        // Rotation R = [x y z] as columns; angles as EyeTrax derives them.
        let yaw = atan2(x.y, x.x)
        let pitch = atan2(-x.z, (y.z * y.z + z.z * z.z).squareRoot())
        let roll = atan2(y.z, z.z)
        out += [yaw, pitch, roll]
        return out
    }
}
