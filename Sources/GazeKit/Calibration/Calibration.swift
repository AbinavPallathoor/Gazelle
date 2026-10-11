import Foundation

/// Calibration and validation target layouts, in global top-left points within `area`.
public enum CalibrationLayout: Int, Codable, Sendable, CaseIterable {
    case nine = 9
    case thirteen = 13
    case twentyFive = 25

    /// Inset from the screen edge, as a fraction of each dimension.
    public static let margin = 0.08

    public func targets(in area: Rect2) -> [Point2] {
        let m = Self.margin
        func p(_ fx: Double, _ fy: Double) -> Point2 {
            Point2(area.x + area.width * (m + (1 - 2 * m) * fx), area.y + area.height * (m + (1 - 2 * m) * fy))
        }
        switch self {
        case .nine:
            return [0.0, 0.5, 1.0].flatMap { fy in [0.0, 0.5, 1.0].map { p($0, fy) } }
        case .thirteen:
            return [0.0, 0.5, 1.0].flatMap { fy in [0.0, 0.5, 1.0].map { p($0, fy) } }
                + [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)].map { p($0.0, $0.1) }
        case .twentyFive:
            let steps = [0.0, 0.25, 0.5, 0.75, 1.0]
            return steps.flatMap { fy in steps.map { p($0, fy) } }
        }
    }

    /// Head-motion phase targets: all nine grid points. With only the centre and corners, a
    /// simulated user's error with the head moving was 2.6× the still error at held-out points;
    /// with all nine it was 1.3× (see ADR 0006).
    public static func headMotionTargets(in area: Rect2) -> [Point2] {
        CalibrationLayout.nine.targets(in: area)
    }

    /// Validation targets lie between the calibration grid points, so they are truly held out.
    public static func validationTargets(in area: Rect2) -> [Point2] {
        let m = margin
        return [(0.3, 0.3), (0.7, 0.3), (0.5, 0.55), (0.3, 0.75), (0.7, 0.75)].map { fx, fy in
            Point2(area.x + area.width * (m + (1 - 2 * m) * fx), area.y + area.height * (m + (1 - 2 * m) * fy))
        }
    }
}

/// Converts on-screen distances to visual angle.
public struct ScreenGeometry: Codable, Sendable, Equatable {
    /// Physical size of one point, in millimetres.
    public var mmPerPoint: Double

    public init(mmPerPoint: Double) {
        self.mmPerPoint = mmPerPoint
    }

    public init(widthMM: Double, widthPoints: Double) {
        mmPerPoint = widthMM / max(widthPoints, 1)
    }

    public func degrees(points: Double, viewingDistanceMM: Double) -> Double {
        atan(points * mmPerPoint / max(viewingDistanceMM, 1)) * 180 / .pi
    }
}

/// Drives one calibration run: still targets, a moving-target pursuit, a head-motion phase,
/// then validation.
///
/// - **Still**: for each dot, samples are accepted only after the eyes have settled (an iris
///   fixation lasting `settleSeconds`, or `maxWaitSeconds` at the latest) and only on non-blink
///   frames; each dot is one cross-validation group.
/// - **Pursuit** (after EyeTrax's Lissajous calibration): a dot glides along a Lissajous curve
///   for `pursuitSeconds`, giving hundreds of distinct target positions. Each sample is paired
///   with where the dot was `pursuitLagSeconds` earlier (smooth pursuit trails the target), and
///   the run is split into `pursuitSegments` groups so cross-validation holds out whole stretches.
/// - **Head motion**: the user keeps looking at each dot while moving their head, so the model
///   sees head variation at many gaze directions (eye-tracker ADR-0015).
/// - **Validation**: dots between the grid points, never used for fitting.
public struct CalibrationSession: Sendable {
    public enum Phase: String, Sendable, Codable {
        case still
        case pursuit
        case headMotion
        case validation
        case done
    }

    public struct Step: Sendable, Equatable {
        public var phase: Phase
        public var index: Int
        public var count: Int
        public var target: Point2
        /// 0…1 progress of collection on this target (or through the pursuit).
        public var progress: Double
        public var collecting: Bool
    }

    public var settleSeconds = 0.35
    public var maxWaitSeconds = 3.0
    public var stillSeconds = 1.0
    public var headMotionSeconds = 2.0
    public var validationSeconds = 1.0
    public var pursuitSeconds = 12.0
    public var pursuitLeadIn = 0.8
    public var pursuitLagSeconds = 0.12
    public var pursuitSegments = 8

    public private(set) var phase: Phase = .still
    public private(set) var samples: [GazeModel.Sample] = []
    public private(set) var validationSamples: [GazeModel.Sample] = []
    public private(set) var skippedTargets: [Point2] = []

    private enum Item: Sendable {
        case dots(Phase, [Point2])
        case pursuit(Rect2)
    }

    private let plan: [Item]
    private var itemIndex = 0
    private var targetIndex = 0
    private var targetStart: Double?
    private var collectStart: Double?
    private var lastT: Double?
    private var blink = BlinkGate()
    private var fixation: FixationDetector

    public init(area: Rect2, layout: CalibrationLayout = .nine, includePursuit: Bool = true, includeHeadMotion: Bool = true) {
        var plan: [Item] = [.dots(.still, layout.targets(in: area))]
        if includePursuit { plan.append(.pursuit(area)) }
        if includeHeadMotion { plan.append(.dots(.headMotion, CalibrationLayout.headMotionTargets(in: area))) }
        plan.append(.dots(.validation, CalibrationLayout.validationTargets(in: area)))
        self.plan = plan
        // Iris dispersion in eye widths; ~0.03 ew is about 4° of eye rotation.
        fixation = FixationDetector(maxDispersion: 0.03, minDuration: 0.35, saccadeSpeed: 1.0)
    }

    /// The pursuit path: a 3:2 Lissajous figure over the central 80 % of the area, with
    /// eased speed at both ends (EyeTrax `lissajous.py`).
    public static func pursuitPoint(in area: Rect2, progress u: Double) -> Point2 {
        let eased = (1 - cos(Double.pi * min(max(u, 0), 1))) / 2
        let t = 2 * Double.pi * eased
        return Point2(area.x + area.width * (0.5 + 0.4 * sin(3 * t)),
                      area.y + area.height * (0.5 + 0.4 * sin(2 * t)))
    }

    public var currentStep: Step? {
        guard itemIndex < plan.count else { return nil }
        switch plan[itemIndex] {
        case .dots(let ph, let targets):
            var progress = 0.0
            if let start = collectStart, let now = lastT {
                progress = min(1, (now - start) / duration(ph))
            }
            return Step(phase: ph, index: targetIndex, count: targets.count, target: targets[targetIndex],
                        progress: progress, collecting: collectStart != nil)
        case .pursuit(let area):
            let elapsed = (lastT ?? 0) - (targetStart ?? lastT ?? 0)
            let u = max(0, elapsed - pursuitLeadIn) / pursuitSeconds
            return Step(phase: .pursuit, index: 0, count: 1, target: Self.pursuitPoint(in: area, progress: u),
                        progress: min(1, u), collecting: elapsed >= pursuitLeadIn)
        }
    }

    private func duration(_ p: Phase) -> Double {
        switch p {
        case .still: return stillSeconds
        case .headMotion: return headMotionSeconds
        case .validation: return validationSeconds
        case .pursuit: return pursuitSeconds
        case .done: return 1
        }
    }

    /// Feeds one frame. `features` is nil when no face was found. Returns true when the
    /// session moved to a new target or phase.
    @discardableResult
    public mutating func update(_ features: GazeFeatures?, at t: Double) -> Bool {
        guard itemIndex < plan.count else { return false }
        if targetStart == nil { targetStart = t }
        lastT = t
        switch plan[itemIndex] {
        case .pursuit(let area):
            phase = .pursuit
            let elapsed = t - targetStart!
            if elapsed >= pursuitLeadIn, elapsed - pursuitLeadIn <= pursuitSeconds,
               let f = features, blink.accept(f) {
                // Pair with where the dot was a moment ago: smooth pursuit trails the target.
                let u = max(0, elapsed - pursuitLeadIn - pursuitLagSeconds) / pursuitSeconds
                let segment = min(pursuitSegments - 1, Int(u * Double(pursuitSegments)))
                samples.append(GazeModel.Sample(features: f, target: Self.pursuitPoint(in: area, progress: u),
                                                group: 1000 + segment))
            }
            guard elapsed - pursuitLeadIn >= pursuitSeconds else { return false }
            return nextItem()

        case .dots(let ph, let targets):
            phase = ph
            if collectStart == nil {
                var settled = false
                if let f = features, blink.accept(f) {
                    fixation.add(f.iris, at: t)
                    settled = ph == .headMotion ? t - targetStart! >= settleSeconds : fixation.isFixating
                }
                if settled || t - targetStart! >= maxWaitSeconds { collectStart = t }
                return false
            }
            if let f = features, blink.accept(f) {
                let group = (ph == .headMotion ? 2000 : 0) + targetIndex
                let sample = GazeModel.Sample(features: f, target: targets[targetIndex], group: group)
                if ph == .validation { validationSamples.append(sample) } else { samples.append(sample) }
            }
            guard t - collectStart! >= duration(ph) else { return false }
            let target = targets[targetIndex]
            let collected = (ph == .validation ? validationSamples : samples).filter { $0.target == target }.count
            if collected < 5 { skippedTargets.append(target) }
            targetIndex += 1
            targetStart = nil
            collectStart = nil
            fixation.reset()
            if targetIndex >= targets.count { return nextItem() }
            return true
        }
    }

    private mutating func nextItem() -> Bool {
        itemIndex += 1
        targetIndex = 0
        targetStart = nil
        collectStart = nil
        fixation.reset()
        if itemIndex >= plan.count { phase = .done }
        return true
    }

    public var isFinished: Bool { itemIndex >= plan.count }
}

/// Validation results, with errors in points and in degrees of visual angle.
public struct ValidationResult: Codable, Sendable, Equatable {
    public struct Point: Codable, Sendable, Equatable {
        public var target: Point2
        public var meanPrediction: Point2
        public var errorPoints: Double
        public var errorDegrees: Double
        /// Std of predictions around their mean while fixating this target (RMS of x and y).
        public var jitterPoints: Double
        public var samples: Int
    }

    public var points: [Point]
    public var meanErrorPoints: Double
    public var meanErrorDegrees: Double
    public var meanJitterPoints: Double
    public var meanJitterDegrees: Double
    public var viewingDistanceMM: Double

    public static func evaluate(_ model: GazeModel, samples: [GazeModel.Sample], geometry: ScreenGeometry) -> ValidationResult {
        let byTarget = Dictionary(grouping: samples) { "\($0.target.x),\($0.target.y)" }
        let distance = Stats.median(samples.map { $0.features.viewingDistanceMM() })
        var pts: [Point] = []
        for group in byTarget.values {
            let target = group[0].target
            let preds = group.map { model.predict($0.features) }
            let mean = Point2(Stats.mean(preds.map(\.x)), Stats.mean(preds.map(\.y)))
            let err = (mean - target).length
            let jitter = (pow(Stats.std(preds.map(\.x)), 2) + pow(Stats.std(preds.map(\.y)), 2)).squareRoot()
            pts.append(Point(target: target, meanPrediction: mean, errorPoints: err,
                             errorDegrees: geometry.degrees(points: err, viewingDistanceMM: distance),
                             jitterPoints: jitter.isFinite ? jitter : 0, samples: group.count))
        }
        pts.sort { ($0.target.y, $0.target.x) < ($1.target.y, $1.target.x) }
        let meanErr = Stats.mean(pts.map(\.errorPoints))
        let meanJit = Stats.mean(pts.map(\.jitterPoints))
        return ValidationResult(points: pts, meanErrorPoints: meanErr,
                                meanErrorDegrees: geometry.degrees(points: meanErr, viewingDistanceMM: distance),
                                meanJitterPoints: meanJit,
                                meanJitterDegrees: geometry.degrees(points: meanJit, viewingDistanceMM: distance),
                                viewingDistanceMM: distance)
    }
}

/// A saved calibration for one display and camera (numbers only, never images).
public struct CalibrationProfile: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version = CalibrationProfile.currentVersion
    public var createdAt: Date
    public var displayKey: String
    public var cameraKey: String
    public var geometry: ScreenGeometry
    public var layout: CalibrationLayout
    public var model: GazeModel
    public var crossValidatedErrorPoints: Double
    public var validation: ValidationResult
    /// Kept as the anchor set for online learning (M8).
    public var samples: [GazeModel.Sample]
    /// Held-out validation samples, kept for offline model comparison (nil in old profiles).
    public var validationSamples: [GazeModel.Sample]?

    public init(createdAt: Date, displayKey: String, cameraKey: String, geometry: ScreenGeometry,
                layout: CalibrationLayout, model: GazeModel, crossValidatedErrorPoints: Double,
                validation: ValidationResult, samples: [GazeModel.Sample],
                validationSamples: [GazeModel.Sample]? = nil) {
        self.createdAt = createdAt
        self.displayKey = displayKey
        self.cameraKey = cameraKey
        self.geometry = geometry
        self.layout = layout
        self.model = model
        self.crossValidatedErrorPoints = crossValidatedErrorPoints
        self.validation = validation
        self.samples = samples
        self.validationSamples = validationSamples
    }

    public static func fileName(displayKey: String, cameraKey: String) -> String {
        let safe = { (s: String) in s.map { $0.isLetter || $0.isNumber ? $0 : "-" } }
        return "profile-\(String(safe(displayKey)))-\(String(safe(cameraKey))).json"
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> CalibrationProfile {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(CalibrationProfile.self, from: data)
    }
}
