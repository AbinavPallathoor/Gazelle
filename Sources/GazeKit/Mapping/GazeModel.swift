import Foundation

/// Maps gaze features to a screen point (global top-left points) with `GroupedRidge`.
///
/// Two feature sets are fitted at calibration and the one with the lower held-out error wins:
/// - `.compact`: the 18-term expansion of `shaal/eye-tracker` ADR-0006 (eye-local iris offsets,
///   their squares and product, head rotation and translation, inverse distance, gaze×head
///   cross terms, vergence);
/// - `.eyeRegion`: EyeTrax's head-aligned eye-region landmark vector (`EyeRegion`), which
///   carries the lid and brow movement that vertical gaze mostly shows up as.
public struct GazeModel: Codable, Sendable, Equatable {
    public enum FeatureSet: String, Codable, Sendable, CaseIterable {
        case compact
        case eyeRegion
    }

    public var featureSet: FeatureSet
    public var ridge: GroupedRidge
    /// Held-out error of every feature set tried at fit time, for the record.
    public var comparison: [String: Double]

    /// A labelled calibration sample.
    public struct Sample: Codable, Sendable, Equatable {
        public var features: GazeFeatures
        /// Target in global top-left points.
        public var target: Point2
        public var weight: Double
        /// Samples of one fixation target (or one pursuit segment) share a group; cross-validation
        /// holds out whole groups. Nil: grouped by target position.
        public var group: Int?

        public init(features: GazeFeatures, target: Point2, weight: Double = 1, group: Int? = nil) {
            self.features = features
            self.target = target
            self.weight = weight
            self.group = group
        }
    }

    /// The compact feature vector (no intercept; the ridge handles it).
    public static func compactTerms(_ f: GazeFeatures) -> [Double] {
        let gx = f.iris.x, gy = f.iris.y
        let yaw = f.pose.yaw, pitch = f.pose.pitch, roll = f.pose.roll
        let hx = f.headPosition.x, hy = f.headPosition.y
        // Inverse interocular distance is closer to linear in physical distance (eye-tracker ADR-0005).
        let hz = 1 / max(f.headScale, 1e-6)
        let vergence = abs(f.irisLeft.x - f.irisRight.x)
        return [gx, gy, gx * gx, gy * gy, gx * gy,
                yaw, pitch, roll, hx, hy, hz,
                gx * yaw, gy * pitch, gx * hx, gy * hy, gx * hz, gy * hz,
                vergence]
    }

    public static func vector(_ f: GazeFeatures, _ set: FeatureSet) -> [Double]? {
        switch set {
        case .compact: return compactTerms(f)
        case .eyeRegion: return f.eyeRegion
        }
    }

    /// Predicts a screen point. Falls back to the ridge intercept (screen centre of the
    /// calibration) if the frame lacks this model's features.
    public func predict(_ f: GazeFeatures) -> Point2 {
        guard let v = Self.vector(f, featureSet), v.count == ridge.coefX.count else {
            return Point2(ridge.interceptX, ridge.interceptY)
        }
        return ridge.predict(v)
    }

    static func groupID(_ s: Sample) -> Int {
        if let g = s.group { return g }
        // Group by target position when no explicit group was assigned.
        return Int(s.target.x.rounded()) &* 100_003 &+ Int(s.target.y.rounded())
    }

    public static func fit(_ samples: [Sample], featureSet: FeatureSet,
                           fixedRatios: (x: Double, y: Double)? = nil) -> GazeModel? {
        let usable = samples.compactMap { s in vector(s.features, featureSet).map { (s, $0) } }
        guard usable.count >= 20, usable.count * 2 >= samples.count else { return nil }
        guard let ridge = GroupedRidge.fit(rows: usable.map(\.1), targets: usable.map(\.0.target),
                                           groups: usable.map { groupID($0.0) }, weights: usable.map(\.0.weight),
                                           fixedRatios: fixedRatios)
        else { return nil }
        return GazeModel(featureSet: featureSet, ridge: ridge, comparison: [featureSet.rawValue: ridge.heldOutError])
    }

    /// Refits this model's feature set on new samples, keeping its regularisation (no
    /// cross-validation, so it is fast enough to run after every confirmed click).
    public func refit(_ samples: [Sample]) -> GazeModel? {
        guard var m = GazeModel.fit(samples, featureSet: featureSet,
                                    fixedRatios: (ridge.lambdaRatioX, ridge.lambdaRatioY)) else { return nil }
        m.comparison = comparison
        m.ridge.heldOutError = ridge.heldOutError
        return m
    }

    /// Fits every feature set the samples support and keeps the one with the lowest held-out
    /// error (leave-one-target-out). Returns the model and its held-out error in points.
    public static func fitCrossValidated(_ samples: [Sample]) -> (model: GazeModel, cvErrorPoints: Double)? {
        var fitted = FeatureSet.allCases.compactMap { fit(samples, featureSet: $0) }
        guard !fitted.isEmpty else { return nil }
        let comparison = Dictionary(uniqueKeysWithValues: fitted.map { ($0.featureSet.rawValue, $0.ridge.heldOutError) })
        fitted.sort { ($0.ridge.heldOutError.isNaN ? .infinity : $0.ridge.heldOutError)
                    < ($1.ridge.heldOutError.isNaN ? .infinity : $1.ridge.heldOutError) }
        var best = fitted[0]
        best.comparison = comparison
        return (best, best.ridge.heldOutError)
    }
}
