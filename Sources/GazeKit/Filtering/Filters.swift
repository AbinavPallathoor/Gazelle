import Foundation

/// One Euro filter (Casiez, Roussel & Vogel, CHI 2012): a low-pass filter whose cutoff rises
/// with speed, so the output is steady during fixations and still follows fast jumps.
public struct OneEuroFilter: Sendable {
    public var minCutoff: Double
    public var beta: Double
    public var derivativeCutoff: Double
    private var x: Double?
    private var dx = 0.0
    private var lastT: Double?

    public init(minCutoff: Double = 1.0, beta: Double = 0.007, derivativeCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    private static func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    public mutating func filter(_ value: Double, at t: Double) -> Double {
        guard let prev = x, let pt = lastT, t > pt else {
            x = value
            lastT = t
            return value
        }
        let dt = t - pt
        let rawDx = (value - prev) / dt
        dx += Self.alpha(derivativeCutoff, dt) * (rawDx - dx)
        let cutoff = minCutoff + beta * abs(dx)
        let out = prev + Self.alpha(cutoff, dt) * (value - prev)
        x = out
        lastT = t
        return out
    }

    public mutating func reset() {
        x = nil
        lastT = nil
        dx = 0
    }
}

/// Two One Euro filters for a 2D point.
public struct OneEuroFilter2D: Sendable {
    private var fx: OneEuroFilter
    private var fy: OneEuroFilter

    public init(minCutoff: Double = 1.0, beta: Double = 0.007, derivativeCutoff: Double = 1.0) {
        fx = OneEuroFilter(minCutoff: minCutoff, beta: beta, derivativeCutoff: derivativeCutoff)
        fy = fx
    }

    public mutating func filter(_ p: Point2, at t: Double) -> Point2 {
        Point2(fx.filter(p.x, at: t), fy.filter(p.y, at: t))
    }

    public mutating func reset() {
        fx.reset()
        fy.reset()
    }
}

/// Dispersion-based fixation detector (I-DT): the most recent samples spanning `minDuration`
/// form a fixation when their bounding box is within `maxDispersion` (in the samples' units).
/// A saccade is reported when consecutive samples move faster than `saccadeSpeed` units/s.
public struct FixationDetector: Sendable {
    public var maxDispersion: Double
    public var minDuration: Double
    public var saccadeSpeed: Double
    private var window: [(t: Double, p: Point2)] = []
    public private(set) var isFixating = false
    public private(set) var isSaccade = false

    public init(maxDispersion: Double, minDuration: Double = 0.15, saccadeSpeed: Double) {
        self.maxDispersion = maxDispersion
        self.minDuration = minDuration
        self.saccadeSpeed = saccadeSpeed
    }

    /// Adds a sample; returns the fixation centroid while fixating.
    @discardableResult
    public mutating func add(_ p: Point2, at t: Double) -> Point2? {
        if let last = window.last, t > last.t {
            isSaccade = (p - last.p).length / (t - last.t) > saccadeSpeed
        }
        if isSaccade { window.removeAll() }
        window.append((t, p))
        // Keep just enough history to cover minDuration.
        while window.count > 2, window[1].t <= t - minDuration { window.removeFirst() }
        guard let first = window.first, t - first.t >= minDuration * 0.9 else {
            isFixating = false
            return nil
        }
        let xs = window.map(\.p.x), ys = window.map(\.p.y)
        let dispersion = (xs.max()! - xs.min()!) + (ys.max()! - ys.min()!)
        isFixating = dispersion <= maxDispersion
        guard isFixating else {
            window.removeFirst()
            return nil
        }
        return Point2(Stats.mean(xs), Stats.mean(ys))
    }

    public mutating func reset() {
        window.removeAll()
        isFixating = false
        isSaccade = false
    }
}
