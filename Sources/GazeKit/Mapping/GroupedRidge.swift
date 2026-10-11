import Accelerate
import Foundation

/// Ridge regression to a 2D screen point with leave-one-group-out selection of λ, per axis.
///
/// Lessons taken from `shaal/eye-tracker` (MIT) ADR-0006, ADR-0019 and ADR-0021:
/// - features are standardised with weighted moments; the intercept is not penalised
///   (targets and features are centred);
/// - λ is `ratio × Σw`, so one grid works whatever the sample count, and the grid runs from
///   almost no shrinkage to very strong shrinkage;
/// - λ is chosen by holding out whole calibration targets ("groups"): the ~30 frames of one
///   fixation are one observation, not 30, and criteria that treat them as independent pick far
///   too little shrinkage (which let head-pose terms drown the gaze signal there, and here);
/// - x and y get independent λ, since vertical gaze is the weaker signal.
/// Per-group sufficient statistics are accumulated once; each fold subtracts its group.
public struct GroupedRidge: Codable, Sendable, Equatable {
    public var means: [Double]
    public var scales: [Double]
    public var interceptX: Double
    public var interceptY: Double
    public var coefX: [Double]
    public var coefY: [Double]
    public var lambdaRatioX: Double
    public var lambdaRatioY: Double
    /// Mean Euclidean error of each held-out group's mean prediction (chosen λ), output units.
    public var heldOutError: Double
    public var groups: Int

    public static let ratioGrid: [Double] = stride(from: -6.0, through: 2.0, by: 0.5).map { pow(10, $0) }
    /// Used when there are too few groups to hold one out: fairly strong shrinkage.
    static let fallbackRatio = 1e-1

    public func predict(_ features: [Double]) -> Point2 {
        var x = interceptX, y = interceptY
        for j in 0..<coefX.count {
            let z = (features[j] - means[j]) / scales[j]
            x += coefX[j] * z
            y += coefY[j] * z
        }
        return Point2(x, y)
    }

    /// Sufficient statistics of a set of rows (standardised features z, weights w).
    struct Stats2 {
        var g: [Double]      // Σ w z zᵀ (upper triangle, row-major p×p)
        var s: [Double]      // Σ w z
        var cx: [Double]     // Σ w z x
        var cy: [Double]     // Σ w z y
        var sw = 0.0, sx = 0.0, sy = 0.0

        init(p: Int) {
            g = [Double](repeating: 0, count: p * p)
            s = [Double](repeating: 0, count: p)
            cx = s
            cy = s
        }

        static func - (a: Stats2, b: Stats2) -> Stats2 {
            var r = a
            vDSP.subtract(a.g, b.g, result: &r.g)
            vDSP.subtract(a.s, b.s, result: &r.s)
            vDSP.subtract(a.cx, b.cx, result: &r.cx)
            vDSP.subtract(a.cy, b.cy, result: &r.cy)
            r.sw -= b.sw; r.sx -= b.sx; r.sy -= b.sy
            return r
        }

        static func + (a: Stats2, b: Stats2) -> Stats2 {
            var r = a
            vDSP.add(a.g, b.g, result: &r.g)
            vDSP.add(a.s, b.s, result: &r.s)
            vDSP.add(a.cx, b.cx, result: &r.cx)
            vDSP.add(a.cy, b.cy, result: &r.cy)
            r.sw += b.sw; r.sx += b.sx; r.sy += b.sy
            return r
        }

        /// Eigendecomposition of the centred Gram matrix G − s sᵀ/Σw: (Q row-major, eigenvalues).
        func centredEigen(p: Int) -> ([Double], [Double])? {
            var a = g
            for i in 0..<p { for j in 0..<p { a[i * p + j] -= s[i] * s[j] / sw } }
            var nn = __CLPK_integer(p), lda = __CLPK_integer(p), info = __CLPK_integer(0)
            var jobz = Int8(UInt8(ascii: "V")), uplo = Int8(UInt8(ascii: "L"))
            var eig = [Double](repeating: 0, count: p)
            var lwork = __CLPK_integer(-1), wq = 0.0
            dsyev_(&jobz, &uplo, &nn, &a, &lda, &eig, &wq, &lwork, &info)
            lwork = __CLPK_integer(wq)
            var work = [Double](repeating: 0, count: Int(lwork))
            dsyev_(&jobz, &uplo, &nn, &a, &lda, &eig, &work, &lwork, &info)
            guard info == 0 else { return nil }
            // LAPACK returns eigenvectors as columns in column-major order, i.e. as rows of `a`
            // read row-major: a[k*p + i] is component i of eigenvector k.
            return (a, eig)
        }

        /// Centred ridge solution for one axis: (intercept, β).
        func solve(lambda: Double, axisX: Bool, p: Int) -> (Double, [Double])? {
            let my = (axisX ? sx : sy) / sw
            let c = axisX ? cx : cy
            var a = g
            var rhs = [Double](repeating: 0, count: p)
            for i in 0..<p {
                for j in i..<p { a[i * p + j] -= s[i] * s[j] / sw }
                a[i * p + i] += lambda
                rhs[i] = c[i] - s[i] * my
            }
            guard let beta = GroupedRidge.choleskySolve(a, rhs, p) else { return nil }
            var intercept = my
            for j in 0..<p { intercept -= beta[j] * s[j] / sw }
            return (intercept, beta)
        }
    }

    /// - Parameters:
    ///   - rows: feature vectors (all the same length).
    ///   - targets: screen points.
    ///   - groups: group id per row; rows of one calibration target (or one pursuit segment) share an id.
    ///   - weights: optional per-row weights (e.g. tracking quality).
    public static func fit(rows: [[Double]], targets: [Point2], groups: [Int], weights: [Double]? = nil) -> GroupedRidge? {
        let n = rows.count
        guard n > 0, let p = rows.first?.count, p > 0, targets.count == n, groups.count == n else { return nil }
        let w = weights ?? [Double](repeating: 1, count: n)
        let sw = w.reduce(0, +)
        guard sw > 0 else { return nil }

        var means = [Double](repeating: 0, count: p)
        var scales = [Double](repeating: 1, count: p)
        for j in 0..<p {
            var m = 0.0
            for i in 0..<n { m += w[i] * rows[i][j] }
            m /= sw
            var v = 0.0
            for i in 0..<n { v += w[i] * (rows[i][j] - m) * (rows[i][j] - m) }
            v /= sw
            means[j] = m
            scales[j] = v > 1e-18 ? v.squareRoot() : 1
        }

        let ids = Array(Set(groups)).sorted()
        let slot = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        var members = [[Int]](repeating: [], count: ids.count)
        for i in 0..<n { members[slot[groups[i]]!].append(i) }

        // Per-group sufficient statistics; the Gram matrix via BLAS (Z_gᵀ W Z_g).
        var stats = [Stats2](repeating: Stats2(p: p), count: ids.count)
        var meanZ = [[Double]](repeating: [Double](repeating: 0, count: p), count: ids.count)
        for (k, rowsOfGroup) in members.enumerated() {
            let m = rowsOfGroup.count
            var zw = [Double](repeating: 0, count: m * p)     // row-major m×p, rows scaled by √w
            for (r, i) in rowsOfGroup.enumerated() {
                let sq = w[i].squareRoot()
                for j in 0..<p {
                    let zij = (rows[i][j] - means[j]) / scales[j]
                    zw[r * p + j] = sq * zij
                    stats[k].s[j] += w[i] * zij
                    stats[k].cx[j] += w[i] * zij * targets[i].x
                    stats[k].cy[j] += w[i] * zij * targets[i].y
                }
                stats[k].sw += w[i]
                stats[k].sx += w[i] * targets[i].x
                stats[k].sy += w[i] * targets[i].y
            }
            // G = zwᵀ zw (full symmetric p×p).
            cblas_dgemm(CblasRowMajor, CblasTrans, CblasNoTrans, Int32(p), Int32(p), Int32(m),
                        1, zw, Int32(p), zw, Int32(p), 0, &stats[k].g, Int32(p))
            for j in 0..<p { meanZ[k][j] = stats[k].s[j] / stats[k].sw }
        }
        let total = stats.dropFirst().reduce(stats[0], +)

        var bestX = ratioGrid.firstIndex { $0 >= fallbackRatio }!
        var bestY = bestX
        var heldOut = Double.nan
        if ids.count >= 3 {
            // predictions[k][r] for each held-out group and λ ratio. One eigendecomposition of the
            // centred training Gram matrix per fold makes every λ cheap:
            // β(λ) = Q (Λ + λ)⁻¹ Qᵀ r, so a prediction is Σ_i (Qᵀz)_i (Qᵀr)_i / (Λ_i + λ).
            var predX = [[Double]](repeating: [Double](repeating: .nan, count: ratioGrid.count), count: ids.count)
            var predY = predX
            for k in 0..<ids.count {
                let train = total - stats[k]
                guard let (q, eig) = train.centredEigen(p: p) else { continue }
                let mx = train.sx / train.sw, my = train.sy / train.sw
                var rx = [Double](repeating: 0, count: p), ry = rx, zc = rx
                for i in 0..<p {
                    rx[i] = train.cx[i] - train.s[i] * mx
                    ry[i] = train.cy[i] - train.s[i] * my
                    zc[i] = meanZ[k][i] - train.s[i] / train.sw     // held-out point, centred on the training mean
                }
                let qrx = GroupedRidge.transposeTimes(q, rx, p), qry = GroupedRidge.transposeTimes(q, ry, p)
                let qz = GroupedRidge.transposeTimes(q, zc, p)
                for (r, ratio) in ratioGrid.enumerated() {
                    let lambda = ratio * train.sw
                    var px = mx, py = my
                    for i in 0..<p {
                        let d = 1 / max(eig[i] + lambda, 1e-12)
                        px += qz[i] * qrx[i] * d
                        py += qz[i] * qry[i] * d
                    }
                    predX[k][r] = px
                    predY[k][r] = py
                }
            }
            func score(_ r: Int, x: Bool) -> Double {
                (0..<ids.count).reduce(0) { acc, k in
                    let pred = x ? predX[k][r] : predY[k][r]
                    let t = x ? stats[k].sx / stats[k].sw : stats[k].sy / stats[k].sw
                    return acc + (pred.isNaN ? .infinity : abs(pred - t))
                }
            }
            bestX = ratioGrid.indices.min { score($0, x: true) < score($1, x: true) }!
            bestY = ratioGrid.indices.min { score($0, x: false) < score($1, x: false) }!
            heldOut = Stats.mean((0..<ids.count).map { k in
                hypot(predX[k][bestX] - stats[k].sx / stats[k].sw, predY[k][bestY] - stats[k].sy / stats[k].sw)
            })
        }
        guard let (ix, bx) = total.solve(lambda: ratioGrid[bestX] * total.sw, axisX: true, p: p),
              let (iy, by) = total.solve(lambda: ratioGrid[bestY] * total.sw, axisX: false, p: p) else { return nil }
        return GroupedRidge(means: means, scales: scales, interceptX: ix, interceptY: iy, coefX: bx, coefY: by,
                            lambdaRatioX: ratioGrid[bestX], lambdaRatioY: ratioGrid[bestY],
                            heldOutError: heldOut, groups: ids.count)
    }

    /// Qᵀv where row k of `q` (row-major) is eigenvector k: (Qᵀv)_k = q_k · v.
    static func transposeTimes(_ q: [Double], _ v: [Double], _ p: Int) -> [Double] {
        var out = [Double](repeating: 0, count: p)
        cblas_dgemv(CblasRowMajor, CblasNoTrans, Int32(p), Int32(p), 1, q, Int32(p), v, 1, 0, &out, 1)
        return out
    }

    /// Solves a symmetric positive-definite system whose upper triangle (row-major) is filled,
    /// with LAPACK's Cholesky solver. Row-major upper = column-major lower.
    static func choleskySolve(_ a: [Double], _ b: [Double], _ n: Int) -> [Double]? {
        var m = a
        var rhs = b
        var nn = __CLPK_integer(n), nrhs = __CLPK_integer(1), lda = __CLPK_integer(n), ldb = __CLPK_integer(n)
        var info = __CLPK_integer(0)
        var uplo = Int8(UInt8(ascii: "L"))
        dposv_(&uplo, &nn, &nrhs, &m, &lda, &rhs, &ldb, &info)
        return info == 0 ? rhs : nil
    }
}
