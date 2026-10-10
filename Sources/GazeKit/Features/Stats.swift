import Foundation

public enum Stats {
    public static func mean(_ xs: [Double]) -> Double {
        xs.isEmpty ? .nan : xs.reduce(0, +) / Double(xs.count)
    }

    /// Population standard deviation.
    public static func std(_ xs: [Double]) -> Double {
        guard xs.count > 1 else { return .nan }
        let m = mean(xs)
        return (xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count)).squareRoot()
    }

    /// Linear-interpolated percentile, p in 0...100.
    public static func percentile(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return .nan }
        let s = xs.sorted()
        let rank = p / 100 * Double(s.count - 1)
        let lo = Int(rank.rounded(.down))
        let hi = min(lo + 1, s.count - 1)
        return s[lo] + (s[hi] - s[lo]) * (rank - Double(lo))
    }

    public static func median(_ xs: [Double]) -> Double { percentile(xs, 50) }

    /// Frame-to-frame jitter: std of successive differences divided by sqrt(2).
    /// Equals the white-noise std of the signal while ignoring slow drift.
    public static func successiveDifferenceJitter(_ xs: [Double]) -> Double {
        guard xs.count > 2 else { return .nan }
        let d = zip(xs.dropFirst(), xs).map { $0 - $1 }
        let rms = (d.reduce(0) { $0 + $1 * $1 } / Double(d.count)).squareRoot()
        return rms / 2.0.squareRoot()
    }
}
