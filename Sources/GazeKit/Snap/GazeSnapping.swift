import Foundation

/// Scores elements by how likely each is the one being looked at (PLAN.md M6).
///
/// Likelihood falls off with the distance from the gaze point to the element's box (0 inside),
/// measured in units of the current gaze error σ: `exp(−½ (d/σ)²)`. A large σ spreads
/// probability across neighbours instead of making a confident wrong choice. Small priors:
/// elements in the window under the gaze point, and recently used elements.
public enum SnapScorer {
    public struct Candidate: Equatable, Sendable {
        public var element: Element
        public var probability: Double
    }

    public static let sameWindowPrior = 1.5
    public static let recentPrior = 1.2

    /// Candidates sorted by probability (highest first). Only elements within 3σ are considered.
    public static func rank(gaze g: Point2, sigma: Double, elements: [Element],
                            gazedPID: Int32? = nil, recentIDs: Set<UInt64> = []) -> [Candidate] {
        let s = max(sigma, 1)
        var scored: [(Element, Double)] = []
        for e in elements {
            let d = SpatialNavigator.distance(g, e.frame)
            guard d <= 3 * s else { continue }
            var score = exp(-0.5 * (d / s) * (d / s))
            if let pid = gazedPID, e.pid == pid { score *= sameWindowPrior }
            if recentIDs.contains(e.id) { score *= recentPrior }
            // Among boxes that all contain the gaze point, prefer the smallest (a button over
            // the row that contains it); a gentle factor so it never outweighs distance.
            score *= 1 / (1 + 0.000_01 * e.frame.area)
            scored.append((e, score))
        }
        let total = scored.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return [] }
        return scored.map { Candidate(element: $0.0, probability: $0.1 / total) }
            .sorted { $0.probability > $1.probability }
    }
}

/// Turns a stream of gaze samples into a stable selection: the current element gets a bonus,
/// and a challenger must beat it by `switchMargin` for `dwellSeconds` before the selection moves.
/// Only fixation samples drive changes, so saccades and noise do not make the outline flicker.
public struct GazeSelector: Sendable {
    public var switchMargin = 1.6
    public var dwellSeconds = 0.15
    public private(set) var selectedID: UInt64?
    /// Second-best candidate when it is close to the best (for "arrow to the runner-up").
    public private(set) var runnerUp: Element?
    private var challengerID: UInt64?
    private var challengerSince: Double?

    public init() {}

    /// Returns the element to select after this sample, or nil to keep the current one.
    public mutating func update(gaze: Point2, fixating: Bool, sigma: Double, elements: [Element],
                                at t: Double, gazedPID: Int32? = nil, recentIDs: Set<UInt64> = []) -> Element? {
        let ranked = SnapScorer.rank(gaze: gaze, sigma: sigma, elements: elements, gazedPID: gazedPID, recentIDs: recentIDs)
        guard let best = ranked.first else { return nil }
        runnerUp = ranked.count > 1 && ranked[1].probability > 0.5 * best.probability ? ranked[1].element : nil

        guard let current = selectedID else {
            guard fixating else { return nil }
            selectedID = best.element.id
            return best.element
        }
        if best.element.id == current {
            challengerID = nil
            challengerSince = nil
            return nil
        }
        guard fixating else { return nil }
        let currentP = ranked.first { $0.element.id == current }?.probability ?? 0
        guard best.probability > switchMargin * currentP else {
            challengerID = nil
            return nil
        }
        if challengerID != best.element.id {
            challengerID = best.element.id
            challengerSince = t
            return nil
        }
        guard t - (challengerSince ?? t) >= dwellSeconds else { return nil }
        selectedID = best.element.id
        challengerID = nil
        challengerSince = nil
        return best.element
    }

    /// Adopts a selection made some other way (keyboard), so gaze continues from it.
    public mutating func adopt(_ id: UInt64?) {
        selectedID = id
        challengerID = nil
        challengerSince = nil
    }
}

/// Who drives the selection (PLAN.md §1 engagement model): gaze, or the keyboard after a
/// navigation key. Gaze takes over again only after a deliberate large eye movement away from
/// the locked element (a fixation far from it, held briefly) or after an idle period.
/// Gaze never activates anything; only keys do.
public struct EngagementState: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case gazeDriven
        case keyboardLocked(since: Double)
    }

    public var idleSeconds = 2.0
    /// A release needs a fixation at least this many σ (and this many points) from the locked element…
    public var releaseSigmas = 3.0
    public var releaseMinPoints = 150.0
    /// …held for this long.
    public var releaseHoldSeconds = 0.3
    public private(set) var mode: Mode = .gazeDriven
    private var lastKey = -Double.infinity
    private var awaySince: Double?

    public init() {}

    public var gazeDrives: Bool { mode == .gazeDriven }

    public mutating func keyPressed(at t: Double) {
        mode = .keyboardLocked(since: t)
        lastKey = t
        awaySince = nil
    }

    /// Feeds a gaze sample while keyboard-locked; returns true if gaze took over again.
    @discardableResult
    public mutating func gaze(_ g: Point2, fixating: Bool, sigma: Double, lockedFrame: Rect2?, at t: Double) -> Bool {
        guard case .keyboardLocked = mode else { return false }
        if t - lastKey >= idleSeconds {
            mode = .gazeDriven
            return true
        }
        guard fixating, let frame = lockedFrame else {
            awaySince = nil
            return false
        }
        let far = SpatialNavigator.distance(g, frame) >= max(releaseSigmas * sigma, releaseMinPoints)
        if !far {
            awaySince = nil
            return false
        }
        if awaySince == nil { awaySince = t }
        if t - awaySince! >= releaseHoldSeconds {
            mode = .gazeDriven
            awaySince = nil
            return true
        }
        return false
    }
}
