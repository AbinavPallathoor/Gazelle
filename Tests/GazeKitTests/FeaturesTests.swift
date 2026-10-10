import Foundation
import Testing
@testable import GazeKit

private func eye(center c: Point2, width w: Double, angle a: Double, iris local: Point2, flip: Bool = false) -> EyeFeatures {
    let u = Point2(cos(a), sin(a))
    let v = Point2(-u.y, u.x)
    var inner = c - u * (w / 2)
    var outer = c + u * (w / 2)
    if flip { swap(&inner, &outer) }
    let iris = c + u * (local.x * w) + v * (local.y * w)
    return EyeFeatures(inner: inner, outer: outer, iris: iris, openness: 0.3)
}

@Suite struct EyeLocalTests {
    @Test func offsetInvariantToRollTranslationScaleAndCornerOrder() throws {
        let local = Point2(0.12, -0.05)
        for (c, w, a, flip) in [
            (Point2(100, 100), 30.0, 0.0, false),
            (Point2(640, 300), 80.0, 0.3, false),
            (Point2(10, 900), 12.0, -0.4, true),
        ] {
            let got = try #require(EyeLocal.irisOffset(eye(center: c, width: w, angle: a, iris: local, flip: flip)))
            #expect(abs(got.x - local.x) < 1e-9)
            #expect(abs(got.y - local.y) < 1e-9)
        }
    }

    @Test func degenerateEyeReturnsNil() {
        let p = Point2(5, 5)
        #expect(EyeLocal.irisOffset(EyeFeatures(inner: p, outer: p, iris: p, openness: 0)) == nil)
    }
}

@Suite struct StatsTests {
    @Test func basicStats() {
        let xs: [Double] = [2, 4, 4, 4, 5, 5, 7, 9]
        #expect(Stats.mean(xs) == 5)
        #expect(Stats.std(xs) == 2)
        #expect(Stats.percentile(xs, 0) == 2)
        #expect(Stats.percentile(xs, 100) == 9)
        #expect(Stats.median([1, 3, 2]) == 2)
    }

    @Test func frameJitterIgnoresLinearDrift() {
        let drift = (0..<100).map { Double($0) * 0.5 }
        #expect(abs(Stats.successiveDifferenceJitter(drift) - 0.5 / 2.0.squareRoot()) < 1e-12)
        let alternating = (0..<100).map { $0 % 2 == 0 ? 1.0 : -1.0 }
        #expect(abs(Stats.successiveDifferenceJitter(alternating) - 2.0.squareRoot()) < 1e-12)
    }
}

@Suite struct RidgeTests {
    @Test func recoversKnownLinearModel() throws {
        var rng = SplitMix64(seed: 7)
        let beta = [0.5, -2.0, 3.0]
        var rows: [[Double]] = []
        var y: [Double] = []
        for _ in 0..<500 {
            let row = [1, rng.uniform(-1, 1), rng.uniform(-1, 1)]
            rows.append(row)
            y.append(zip(row, beta).reduce(0) { $0 + $1.0 * $1.1 } + rng.uniform(-0.01, 0.01))
        }
        let model = try #require(Ridge(x: rows, y: y, lambda: 1e-6))
        for (got, want) in zip(model.coefficients, beta) { #expect(abs(got - want) < 0.01) }
    }

    @Test func singularWithoutRegularisationReturnsNil() {
        #expect(Ridge(x: [[1, 1], [1, 1]], y: [1, 2], lambda: 0) == nil)
    }
}

@Suite struct RecordingTests {
    @Test func jsonlRoundTrip() throws {
        let meta = RecordingMeta(backend: "vision", label: "still", startedAt: Date(timeIntervalSince1970: 1_000_000))
        let e = EyeFeatures(inner: Point2(1, 2), outer: Point2(3, 4), iris: Point2(2, 3), openness: 0.25)
        let frame = FaceFeatures(timestamp: 1.5, backend: "vision", leftEye: e, rightEye: e,
                                 headPose: HeadPose(yaw: 0.1, pitch: 0, roll: -0.1),
                                 faceBounds: Rect2(x: 1, y: 2, width: 3, height: 4),
                                 confidence: 0.9, processingMs: 4, imageWidth: 1280, imageHeight: 720)
        let lost = FaceFeatures(timestamp: 1.6, backend: "vision", confidence: 0, processingMs: 3,
                                imageWidth: 1280, imageHeight: 720)
        var data = Data()
        for line in [RecordLine(meta: meta), RecordLine(frame: frame), RecordLine(frame: lost),
                     RecordLine(cpu: CPUSample(timestamp: 2, percent: 12))] {
            data.append(try Recording.encodeLine(line))
        }
        let rec = try Recording.decode(jsonl: data)
        #expect(rec.meta == meta)
        #expect(rec.frames == [frame, lost])
        #expect(rec.cpu == [CPUSample(timestamp: 2, percent: 12)])
        #expect(!String(decoding: data, as: UTF8.self).contains("pixel"))
    }
}

@Suite struct SessionMetricsTests {
    /// Gaze fixed while the head moves: the iris offset is a linear function of pose plus noise.
    /// The residual std must recover the noise level, and blinks must be detected and excluded.
    @Test func residualRecoversNoiseUnderHeadMotion() {
        var rng = SplitMix64(seed: 42)
        let noise = 0.002
        var frames: [FaceFeatures] = []
        for i in 0..<900 {
            let t = Double(i) / 30
            let yaw = 0.2 * sin(t), pitch = 0.1 * cos(0.7 * t)
            let blink = i % 100 == 50
            let local = Point2(-0.3 * yaw + rng.uniform(-1, 1) * noise * 3.0.squareRoot(),
                               0.2 * pitch + rng.uniform(-1, 1) * noise * 3.0.squareRoot())
            var l = eye(center: Point2(500, 300), width: 40, angle: 0.05, iris: local)
            var r = eye(center: Point2(600, 300), width: 40, angle: 0.05, iris: local)
            if blink { l.openness = 0.05; r.openness = 0.05 }
            frames.append(FaceFeatures(timestamp: t, backend: "synthetic", leftEye: l, rightEye: r,
                                       headPose: HeadPose(yaw: yaw, pitch: pitch, roll: 0.05),
                                       faceBounds: Rect2(x: 450, y: 200, width: 200, height: 200),
                                       confidence: 1, processingMs: Double(i % 10),
                                       imageWidth: 1280, imageHeight: 720))
        }
        frames.append(FaceFeatures(timestamp: 30, backend: "synthetic", confidence: 0, processingMs: 1,
                                   imageWidth: 1280, imageHeight: 720))
        let m = SessionMetrics(recording: Recording(frames: frames))
        #expect(abs(m.fps - 30) < 0.1)
        #expect(abs(m.blinkPercent - 1) < 0.01)
        #expect(m.faceFoundPercent < 100)
        // Raw std is dominated by the head-driven signal; the residual sees only the noise.
        #expect(m.irisStd > 0.03)
        #expect(abs(m.irisResidualStd - noise * 2.0.squareRoot()) < 0.0005)
        #expect(m.yawStdDeg > 5)
    }
}

/// Deterministic RNG for tests.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform(_ lo: Double, _ hi: Double) -> Double {
        lo + (hi - lo) * Double(next() >> 11) / Double(1 << 53)
    }
}
