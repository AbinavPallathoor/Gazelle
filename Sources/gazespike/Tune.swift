import Foundation
import GazeKit

/// Replays a profile's held-out validation fixations through One Euro filter settings and
/// reports jitter while fixating vs lag after a jump to the next target (replay harness, PLAN.md §6).
enum Tune {
    struct Result { var minCutoff: Double; var beta: Double; var jitter: Double; var lag: Double }

    static func run(profilePath: String) throws {
        let profile = try CalibrationProfile.decode(Data(contentsOf: URL(fileURLWithPath: profilePath)))
        guard let samples = profile.validationSamples, !samples.isEmpty else {
            fail("profile has no validation samples (recalibrate with a current build)")
        }
        let model = profile.learnedModel ?? profile.model
        let seq = samples.sorted { $0.features.timestamp < $1.features.timestamp }
        let raw = seq.map { (t: $0.features.timestamp, p: model.predict($0.features), target: $0.target) }

        // Unfiltered reference.
        let unfiltered = evaluate(raw.map { ($0.t, $0.p, $0.target) })
        print(String(format: "unfiltered: jitter %.1f pt", unfiltered.jitter))

        var results: [Result] = []
        for mc in [0.2, 0.3, 0.5, 0.8, 1.2, 2.0] {
            for beta in [0.0005, 0.001, 0.002, 0.004, 0.008, 0.016, 0.03] {
                var f = OneEuroFilter2D(minCutoff: mc, beta: beta)
                let filtered = raw.map { ($0.t, f.filter($0.p, at: $0.t), $0.target) }
                let e = evaluate(filtered)
                results.append(Result(minCutoff: mc, beta: beta, jitter: e.jitter, lag: e.lag))
            }
        }
        print("minCutoff beta   jitter(pt) lag(ms)")
        for r in results.sorted(by: { $0.jitter < $1.jitter }).prefix(12) {
            print(String(format: "%8.2f %7.4f %9.1f %7.0f", r.minCutoff, r.beta, r.jitter, r.lag * 1000))
        }
        if let best = results.filter({ $0.lag <= 0.25 }).min(by: { $0.jitter < $1.jitter }) {
            print(String(format: "\nbest with lag ≤ 250 ms: minCutoff %.2f, beta %.4f → jitter %.1f pt, lag %.0f ms",
                         best.minCutoff, best.beta, best.jitter, best.lag * 1000))
        }
    }

    /// Jitter: RMS spread around each fixation's mean after 0.3 s. Lag: time from a fixation's
    /// first sample until the output is within half the jump of that fixation's settled mean.
    static func evaluate(_ seq: [(Double, Point2, Point2)]) -> (jitter: Double, lag: Double) {
        var groups: [[(Double, Point2)]] = []
        var lastTarget: Point2?
        for (t, p, target) in seq {
            if target != lastTarget { groups.append([]); lastTarget = target }
            groups[groups.count - 1].append((t, p))
        }
        var jitters: [Double] = [], lags: [Double] = []
        var previousMean: Point2?
        for g in groups {
            guard let t0 = g.first?.0 else { continue }
            let settled = g.filter { $0.0 >= t0 + 0.3 }.map(\.1)
            guard settled.count > 3 else { continue }
            let mean = Point2(Stats.mean(settled.map(\.x)), Stats.mean(settled.map(\.y)))
            jitters.append((settled.reduce(0) { $0 + pow(($1 - mean).length, 2) } / Double(settled.count)).squareRoot())
            if let prev = previousMean {
                let jump = (mean - prev).length
                if jump > 50, let hit = g.first(where: { ($0.1 - mean).length <= jump / 2 }) {
                    lags.append(hit.0 - t0)
                }
            }
            previousMean = mean
        }
        return (Stats.mean(jitters), lags.isEmpty ? 0 : Stats.mean(lags))
    }
}
