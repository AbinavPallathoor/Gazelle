import Foundation

/// Ridge regression solved with the normal equations.
public struct Ridge: Sendable {
    public let coefficients: [Double]

    /// Fits y ≈ X·β, minimising |y − Xβ|² + λ|β|². The column at
    /// `unpenalisedColumn` (typically an intercept of ones) is not regularised.
    public init?(x rows: [[Double]], y: [Double], lambda: Double, unpenalisedColumn: Int? = 0) {
        guard let p = rows.first?.count, p > 0, rows.count == y.count, !rows.isEmpty else { return nil }
        var a = [[Double]](repeating: [Double](repeating: 0, count: p), count: p)
        var b = [Double](repeating: 0, count: p)
        for (row, yi) in zip(rows, y) {
            guard row.count == p else { return nil }
            for i in 0..<p {
                b[i] += row[i] * yi
                for j in i..<p { a[i][j] += row[i] * row[j] }
            }
        }
        for i in 0..<p {
            for j in 0..<i { a[i][j] = a[j][i] }
            if i != unpenalisedColumn { a[i][i] += lambda }
        }
        guard let beta = Ridge.solve(a, b) else { return nil }
        coefficients = beta
    }

    public func predict(_ row: [Double]) -> Double {
        zip(row, coefficients).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// Gaussian elimination with partial pivoting.
    static func solve(_ aIn: [[Double]], _ bIn: [Double]) -> [Double]? {
        var a = aIn
        var b = bIn
        let n = b.count
        for col in 0..<n {
            guard let pivot = (col..<n).max(by: { abs(a[$0][col]) < abs(a[$1][col]) }),
                  abs(a[pivot][col]) > 1e-12 else { return nil }
            a.swapAt(col, pivot)
            b.swapAt(col, pivot)
            for r in (col + 1)..<n {
                let f = a[r][col] / a[col][col]
                if f == 0 { continue }
                for c in col..<n { a[r][c] -= f * a[col][c] }
                b[r] -= f * b[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = b[r]
            for c in (r + 1)..<n { s -= a[r][c] * x[c] }
            x[r] = s / a[r][r]
        }
        return x
    }
}
