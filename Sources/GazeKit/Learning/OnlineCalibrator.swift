import Foundation

/// Implicit calibration from confirmed selections (PLAN.md M8, "no recalibration").
///
/// Every activation is a free labelled sample: the fixation just before the key, labelled with
/// the activated element's centre. Samples pass strict safeguards against poisoning (wrong
/// clicks, noise), and the model is refitted on the original calibration samples, which stay as
/// a fixed anchor, plus the accepted online samples with exponentially decaying weights (a
/// forgetting factor). That is the exact solution of the objective a recursive-least-squares
/// update with forgetting approximates, and with the λ fixed from calibration it costs
/// milliseconds. A rolling error estimate σ from the residuals feeds snapping and the HUD.
public struct OnlineCalibrator: Sendable {
    public struct Config: Sendable {
        /// The fixation must end within this long before the key press…
        public var fixationWindow = 0.6
        public var keyLatency = 0.05
        /// …and contain at least this many tracked, fixating, non-stalled frames.
        public var minFrames = 6
        /// Targets larger than this (either side, points) have no well-defined centre (rows,
        /// text areas, web views) and are never learned from.
        public var maxTargetSide = 220.0
        /// The element must be among the top-k gaze candidates, or within this many σ of the gaze.
        public var topK = 3
        public var maxDistanceSigmas = 3.0
        /// A residual above `outlierFactor` × the median of recent residuals is rejected.
        public var outlierFactor = 3.0
        /// Weight of one online sample, and of each original calibration frame (the anchor). With
        /// ~1,500 anchor frames at 0.25, about 20 recent clicks carry as much weight as the whole
        /// calibration: enough to follow real drift, while the anchor keeps the model from
        /// wandering (tested with poisoned clicks).
        public var sampleWeight = 20.0
        public var anchorWeight = 0.25
        /// Per-sample forgetting factor for online samples (newest weight 1).
        public var forgetting = 0.97
        public var maxOnlineSamples = 200
        /// σ over this many recent residuals.
        public var sigmaWindow = 20
        public var minSigma = 30.0
        /// Recentring is suggested when σ stays above this multiple of the calibration σ.
        public var recentreFactor = 1.8
        public var recentreAfter = 8

        public init() {}
    }

    public enum Decision: Equatable, Sendable {
        case accepted(residual: Double)
        case rejected(Reason)
    }

    public enum Reason: String, Equatable, Sendable {
        case noFixation = "no stable fixation before the key"
        case targetTooLarge = "target has no clear centre"
        case implausibleTarget = "target too far from where you were looking"
        case outlier = "error far above recent errors"
    }

    /// Persisted learned state.
    public struct State: Codable, Sendable, Equatable {
        public var samples: [GazeModel.Sample] = []
        /// Residuals of accepted samples (for σ).
        public var residuals: [Double] = []
        /// Residuals of every plausible sample, accepted or not (the outlier reference). A
        /// sustained shift raises this after a few clicks, so learning can follow real drift,
        /// while a one-off wrong click still stands out.
        public var plausibleResiduals: [Double] = []
        /// Additive correction from one-point re-centring (points).
        public var offset = Point2(0, 0)
        public var accepted = 0
        public var rejected = 0

        public init() {}
    }

    public var config = Config()
    public private(set) var state: State
    public private(set) var model: GazeModel
    public let baseSigma: Double
    private let anchors: [GazeModel.Sample]
    private var buffer: [(t: Double, f: GazeFeatures, ok: Bool, fixating: Bool)] = []
    private var highStreak = 0

    public init(model: GazeModel, anchors: [GazeModel.Sample], baseSigma: Double, state: State = State()) {
        self.model = model
        self.anchors = anchors
        self.baseSigma = max(baseSigma, 1)
        self.state = state
    }

    /// Current gaze error estimate (points): RMS of recent accepted residuals once there are
    /// enough of them, otherwise the calibration's validation error.
    public var sigma: Double {
        let r = state.residuals.suffix(config.sigmaWindow)
        guard r.count >= 5 else { return max(baseSigma, config.minSigma) }
        let rms = (r.reduce(0) { $0 + $1 * $1 } / Double(r.count)).squareRoot()
        return max(rms, config.minSigma)
    }

    /// True when σ has stayed high: offer a quick one-point re-centre instead of recalibrating.
    public var suggestsRecentre: Bool { highStreak >= config.recentreAfter }

    public func predict(_ f: GazeFeatures) -> Point2 { model.predict(f) + state.offset }

    /// Records a frame (call for every frame; `ok` false when the face is lost or the camera
    /// stalled, `fixating` from the gaze fixation detector).
    public mutating func observe(_ f: GazeFeatures?, ok: Bool, fixating: Bool, at t: Double) {
        if let f { buffer.append((t, f, ok, fixating)) }
        buffer.removeAll { $0.t < t - 1.5 }
    }

    /// The fixation just before `t`, if it qualifies.
    func fixationBefore(_ t: Double) -> (features: GazeFeatures, frames: Int)? {
        let window = buffer.filter { $0.t >= t - config.fixationWindow && $0.t <= t - config.keyLatency }
        // The face must have been tracked throughout the window, not just in the good frames.
        guard !window.contains(where: { !$0.ok }) else { return nil }
        let good = window.filter(\.fixating)
        guard good.count >= config.minFrames, let mean = GazeFeatures.mean(good.map(\.f)) else { return nil }
        return (mean, good.count)
    }

    /// Considers a confirmed activation of `target` (global top-left points) at time `t`.
    /// - Parameter rank: the element's rank among gaze candidates at that moment (0 = best), or
    ///   nil if it was not a candidate.
    /// - Returns: the decision, and when accepted, the samples to refit on (call `refit` with
    ///   them, typically off the main thread, then `install` the result).
    public mutating func confirm(target: Rect2, rank: Int?, at t: Double) -> (Decision, [GazeModel.Sample]?) {
        guard target.width <= config.maxTargetSide, target.height <= config.maxTargetSide else {
            state.rejected += 1
            return (.rejected(.targetTooLarge), nil)
        }
        guard let (features, frames) = fixationBefore(t) else {
            state.rejected += 1
            return (.rejected(.noFixation), nil)
        }
        let predicted = predict(features)
        let s = sigma
        let near = SpatialNavigator.distance(predicted, target) <= config.maxDistanceSigmas * s
        guard near || (rank.map { $0 < config.topK } ?? false) else {
            state.rejected += 1
            return (.rejected(.implausibleTarget), nil)
        }
        let residual = (predicted - target.center).length
        let recent = state.plausibleResiduals.suffix(config.sigmaWindow)
        let reference = recent.count >= 5 ? Stats.median(Array(recent)) : max(baseSigma, config.minSigma)
        state.plausibleResiduals.append(residual)
        if state.plausibleResiduals.count > 100 { state.plausibleResiduals.removeFirst(state.plausibleResiduals.count - 100) }
        guard residual <= config.outlierFactor * max(reference, config.minSigma) else {
            state.rejected += 1
            return (.rejected(.outlier), nil)
        }

        state.accepted += 1
        state.residuals.append(residual)
        if state.residuals.count > 100 { state.residuals.removeFirst(state.residuals.count - 100) }
        highStreak = sigma > config.recentreFactor * max(baseSigma, config.minSigma) ? highStreak + 1 : 0

        // Store the label against the model's own features (before the offset), so refits learn
        // the correction and the offset can be dropped.
        let confidence = min(1, Double(frames) / 10)
        state.samples.append(GazeModel.Sample(features: features, target: target.center - state.offset,
                                              weight: confidence, group: 10_000 + state.accepted))
        if state.samples.count > config.maxOnlineSamples {
            state.samples.removeFirst(state.samples.count - config.maxOnlineSamples)
        }
        return (.accepted(residual: residual), trainingSet())
    }

    /// Anchor samples at `anchorWeight`, plus online samples weighted by confidence × forgetting^age.
    public func trainingSet() -> [GazeModel.Sample] {
        let n = state.samples.count
        let anchors = self.anchors.map { a -> GazeModel.Sample in
            var a = a
            a.weight *= config.anchorWeight
            return a
        }
        let online = state.samples.enumerated().map { i, s -> GazeModel.Sample in
            var s = s
            s.weight = s.weight * config.sampleWeight * pow(config.forgetting, Double(n - 1 - i))
            return s
        }
        return anchors + online
    }

    /// Refits on `samples` with the model's regularisation. Pure; safe to run off the main thread.
    public func refit(_ samples: [GazeModel.Sample]) -> GazeModel? { model.refit(samples) }

    public mutating func install(_ m: GazeModel) { model = m }

    /// One-point re-centre: the user looked at `target`; shift predictions by the mean error.
    public mutating func recentre(predictions: [Point2], target: Point2) {
        guard !predictions.isEmpty else { return }
        let mean = Point2(Stats.mean(predictions.map(\.x)), Stats.mean(predictions.map(\.y)))
        state.offset = state.offset + (target - mean)
        state.residuals.removeAll()
        state.plausibleResiduals.removeAll()
        highStreak = 0
    }
}
