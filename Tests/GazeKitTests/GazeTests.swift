import Foundation
import Testing
@testable import GazeKit

/// A simulated user and camera: the true eye-local iris offset is a smooth function of where on
/// the screen the user looks *and* of head pose/position (eyes counter-rotate as the head turns).
struct SimulatedUser {
    var rng = SplitMix64(seed: 11)
    var noise = 0.002          // iris noise, eye widths
    let screen = Rect2(x: 0, y: 0, width: 1440, height: 900)

    func trueIris(target: Point2, pose: HeadPose, head: Point2) -> Point2 {
        let u = (target.x - 720) / 720, v = (target.y - 450) / 450
        return Point2(0.12 * u + 0.02 * u * u - 0.35 * pose.yaw - 0.05 * (head.x - 0.5),
                      0.08 * v + 0.01 * u * v - 0.30 * pose.pitch - 0.04 * (head.y - 0.5))
    }

    mutating func frame(looking target: Point2, t: Double, headMoving: Bool, blink: Bool = false) -> GazeFeatures {
        let pose = headMoving ? HeadPose(yaw: 0.12 * sin(1.7 * t), pitch: 0.08 * sin(1.1 * t + 1), roll: 0.03 * sin(t))
                              : HeadPose(yaw: 0.01, pitch: -0.02, roll: 0)
        let head = headMoving ? Point2(0.5 + 0.06 * sin(0.9 * t), 0.45 + 0.04 * cos(1.3 * t)) : Point2(0.5, 0.45)
        var iris = trueIris(target: target, pose: pose, head: head)
        iris.x += rng.uniform(-1, 1) * noise * 3.0.squareRoot()
        iris.y += rng.uniform(-1, 1) * noise * 3.0.squareRoot()
        return GazeFeatures(timestamp: t, iris: iris, irisLeft: iris, irisRight: iris, openness: blink ? 0.05 : 0.3,
                            pose: pose, headPosition: head, headScale: 0.1, interocularPx: 128, imageWidth: 1280)
    }
}

@Suite struct GazeModelTests {
    func randomFeatures(_ i: Int, _ rng: inout SplitMix64) -> GazeFeatures {
        GazeFeatures(timestamp: Double(i), iris: Point2(rng.uniform(-0.12, 0.12), rng.uniform(-0.08, 0.08)),
                     irisLeft: Point2(rng.uniform(-0.12, 0.12), 0), irisRight: Point2(rng.uniform(-0.12, 0.12), 0), openness: 0.3,
                     pose: HeadPose(yaw: rng.uniform(-0.15, 0.15), pitch: rng.uniform(-0.1, 0.1), roll: rng.uniform(-0.05, 0.05)),
                     headPosition: Point2(rng.uniform(0.4, 0.6), rng.uniform(0.35, 0.55)),
                     headScale: rng.uniform(0.08, 0.12), interocularPx: 120, imageWidth: 1280)
    }

    /// Truth inside the compact model's function class, 25 groups of 16 samples.
    func exactSamples(_ n: Int, noisePoints: Double, rng: inout SplitMix64) -> [GazeModel.Sample] {
        let k = GazeModel.compactTerms(randomFeatures(0, &rng)).count
        let truthX = (0..<k).map { Double(($0 * 37) % 11) * 300 - 1500 }
        let truthY = (0..<k).map { Double(($0 * 53) % 7) * 300 - 900 }
        return (0..<n).map { i in
            let f = randomFeatures(i, &rng)
            let t = GazeModel.compactTerms(f)
            let x = 700 + zip(t, truthX).reduce(0) { $0 + $1.0 * $1.1 } + rng.uniform(-1, 1) * noisePoints
            let y = 450 + zip(t, truthY).reduce(0) { $0 + $1.0 * $1.1 } + rng.uniform(-1, 1) * noisePoints
            return GazeModel.Sample(features: f, target: Point2(x, y), group: i % 25)
        }
    }

    @Test func recoversKnownMappingWithoutNoise() throws {
        var rng = SplitMix64(seed: 5)
        let train = exactSamples(400, noisePoints: 0, rng: &rng)
        let test = exactSamples(100, noisePoints: 0, rng: &rng)
        let model = try #require(GazeModel.fit(train, featureSet: .compact))
        let err = Stats.mean(test.map { (model.predict($0.features) - $0.target).length })
        #expect(err < 1, "error \(err) pt")
        #expect(model.ridge.lambdaRatioX <= 1e-4)   // clean data: cross-validation picks little shrinkage
    }

    @Test func recoversKnownMappingWithNoiseNearTheNoiseFloor() throws {
        var rng = SplitMix64(seed: 6)
        let train = exactSamples(500, noisePoints: 20, rng: &rng)
        let truth = exactSamples(200, noisePoints: 0, rng: &rng)
        let model = try #require(GazeModel.fit(train, featureSet: .compact))
        let err = Stats.mean(truth.map { (model.predict($0.features) - $0.target).length })
        #expect(err < 8, "error \(err) pt")
    }

    @Test func pureNoiseFeaturesShrinkToTheMean() throws {
        // Features unrelated to the targets (the stalled-camera case): λ must go to the top of the
        // grid and predictions collapse to the target mean instead of fitting noise.
        var rng = SplitMix64(seed: 9)
        let targets = CalibrationLayout.nine.targets(in: Rect2(x: 0, y: 0, width: 1440, height: 900))
        var samples: [GazeModel.Sample] = []
        for (g, t) in targets.enumerated() {
            for i in 0..<30 { samples.append(GazeModel.Sample(features: randomFeatures(g * 30 + i, &rng), target: t, group: g)) }
        }
        let model = try #require(GazeModel.fit(samples, featureSet: .compact))
        let preds = samples.map { model.predict($0.features) }
        #expect(Stats.std(preds.map(\.x)) < 60)
        #expect(model.ridge.heldOutError > 300)    // and it says so
    }

    @Test func choosesEyeRegionFeaturesWhenTheyCarryTheSignal() throws {
        var rng = SplitMix64(seed: 12)
        var samples: [GazeModel.Sample] = []
        let n = EyeRegion.featureCount
        for g in 0..<20 {
            let target = Point2(rng.uniform(100, 1300), rng.uniform(100, 800))
            for i in 0..<15 {
                var f = randomFeatures(g * 15 + i, &rng)          // compact terms: noise only
                var v = (0..<n).map { _ in rng.uniform(-0.01, 0.01) }
                v[10] += (target.x - 700) / 6000                  // signal in two landmark coordinates
                v[40] += (target.y - 450) / 6000
                f.eyeRegion = v
                samples.append(GazeModel.Sample(features: f, target: target, group: g))
            }
        }
        let (model, cv) = try #require(GazeModel.fitCrossValidated(samples))
        #expect(model.featureSet == .eyeRegion)
        // Two informative coordinates among 486 noisy ones, 20 targets: well above chance, not perfect.
        #expect(cv < 250, "cv \(cv)")
        #expect(model.comparison.count == 2)
    }

    /// Realistic eye simulation (nonlinear, head moving during validation).
    @Test func realisticSimulationWithHeadMotion() throws {
        var user = SimulatedUser()
        var session = CalibrationSession(area: user.screen)
        var t = 0.0
        while !session.isFinished {
            let step = try #require(session.currentStep)
            t += 1 / 30
            session.update(user.frame(looking: step.target, t: t, headMoving: step.phase == .headMotion), at: t)
        }
        let (model, cv) = try #require(GazeModel.fitCrossValidated(session.samples))
        var errs: [Double] = []
        for target in CalibrationLayout.validationTargets(in: user.screen) {
            for _ in 0..<30 {
                t += 1 / 30
                errs.append((model.predict(user.frame(looking: target, t: t, headMoving: true)) - target).length)
            }
        }
        let err = Stats.mean(errs)
        #expect(err < 40, "mean held-out error \(err) pt")
        #expect(cv.isFinite)
    }

    @Test func tooFewSamplesFails() {
        #expect(GazeModel.fit([], featureSet: .compact) == nil)
    }
}

@Suite struct EyeRegionTests {
    @Test func invariantToHeadRotationTranslationAndScale() throws {
        var rng = SplitMix64(seed: 2)
        let n = EyeRegion.indices.count
        // A plausible face: eye corners left/right, top of head above.
        var pts = (0..<n).flatMap { _ in [rng.uniform(-50, 50), rng.uniform(-60, 40), rng.uniform(-10, 10)] }
        func set(_ idx: Int, _ v: [Double]) { let i = EyeRegion.indices.firstIndex(of: idx)!; pts[3 * i] = v[0]; pts[3 * i + 1] = v[1]; pts[3 * i + 2] = v[2] }
        set(33, [-60, 0, 0]); set(263, [60, 0, 0]); set(10, [0, -120, 5])
        let base = try #require(EyeRegion.features(pts))
        #expect(base.count == EyeRegion.featureCount)

        // Rotate about z by 0.3 rad and y by 0.2 rad, scale by 1.7, translate.
        let (cz, sz, cy, sy) = (cos(0.3), sin(0.3), cos(0.2), sin(0.2))
        var moved = pts
        for i in 0..<n {
            var x = pts[3 * i], y = pts[3 * i + 1], z = pts[3 * i + 2]
            (x, y) = (cz * x - sz * y, sz * x + cz * y)
            (x, z) = (cy * x + sy * z, -sy * x + cy * z)
            moved[3 * i] = 1.7 * x + 500; moved[3 * i + 1] = 1.7 * y + 300; moved[3 * i + 2] = 1.7 * z - 20
        }
        let out = try #require(EyeRegion.features(moved))
        for j in 0..<(EyeRegion.featureCount - 3) { #expect(abs(out[j] - base[j]) < 1e-9) }
        #expect(EyeRegion.features([1, 2, 3]) == nil)
    }
}

@Suite struct CalibrationSessionTests {
    @Test func fullRunCollectsSamplesAndValidates() throws {
        var user = SimulatedUser()
        var session = CalibrationSession(area: user.screen)
        var t = 0.0
        var frames = 0
        while !session.isFinished && frames < 30 * 180 {
            let step = try #require(session.currentStep)
            t += 1 / 30
            frames += 1
            let blink = frames % 90 == 0
            let f = user.frame(looking: step.target, t: t, headMoving: step.phase == .headMotion, blink: blink)
            session.update(f, at: t)
        }
        #expect(session.isFinished)
        #expect(session.skippedTargets.isEmpty)
        #expect(session.samples.count >= 9 * 25 + 9 * 50 + 300)   // still + head motion + pursuit
        #expect(session.validationSamples.count >= 5 * 25)
        #expect(!session.samples.contains { $0.features.openness < 0.1 })   // blinks gated

        let (model, _) = try #require(GazeModel.fitCrossValidated(session.samples))
        let geometry = ScreenGeometry(widthMM: 300, widthPoints: 1440)
        let v = ValidationResult.evaluate(model, samples: session.validationSamples, geometry: geometry)
        #expect(v.points.count == 5)
        #expect(v.meanErrorPoints < 40)
        #expect(v.meanErrorDegrees > 0 && v.meanErrorDegrees < 2)
    }

    @Test func missingFaceTimesOutAndSkipsTarget() {
        var session = CalibrationSession(area: Rect2(x: 0, y: 0, width: 100, height: 100))
        var t = 0.0
        for _ in 0..<(30 * 6) { t += 1 / 30; session.update(nil, at: t) }
        #expect(session.skippedTargets.count >= 1)
    }

    @Test func layoutsHaveExpectedCountsAndStayInside() {
        let area = Rect2(x: 100, y: -900, width: 1440, height: 900)  // e.g. a display above the primary
        for layout in CalibrationLayout.allCases {
            let ts = layout.targets(in: area)
            #expect(ts.count == layout.rawValue)
            #expect(ts.allSatisfy { area.contains($0) })
        }
    }
}

@Suite struct FilterTests {
    @Test func oneEuroSmoothsNoiseButFollowsJumps() {
        var rng = SplitMix64(seed: 3)
        var f = OneEuroFilter(minCutoff: 1, beta: 0.05)
        var out: [Double] = []
        for i in 0..<120 { out.append(f.filter(100 + rng.uniform(-5, 5), at: Double(i) / 60)) }
        #expect(Stats.std(Array(out.suffix(60))) < 2)           // input std ≈ 2.9
        for i in 120..<150 { out.append(f.filter(500, at: Double(i) / 60)) }
        #expect(abs(out.last! - 500) < 10)                       // caught up within 0.5 s
    }

    @Test func fixationAndSaccade() {
        var d = FixationDetector(maxDispersion: 10, minDuration: 0.2, saccadeSpeed: 1000)
        var t = 0.0
        for _ in 0..<12 { t += 1 / 30; d.add(Point2(100, 100), at: t) }
        #expect(d.isFixating)
        t += 1 / 30
        d.add(Point2(400, 100), at: t)
        #expect(d.isSaccade)
        #expect(!d.isFixating)
    }

    @Test func blinkGateDropsBlinkAndSettle() {
        var gate = BlinkGate()
        func f(_ t: Double, _ open: Double) -> GazeFeatures {
            GazeFeatures(timestamp: t, iris: Point2(0, 0), irisLeft: Point2(0, 0), irisRight: Point2(0, 0), openness: open,
                         pose: HeadPose(yaw: 0, pitch: 0, roll: 0), headPosition: Point2(0.5, 0.5), headScale: 0.1,
                         interocularPx: 100, imageWidth: 1280)
        }
        let accepted = [(0, 0.3), (0.033, 0.3), (0.066, 0.1), (0.1, 0.3), (0.3, 0.3)].map { gate.accept(f($0.0, $0.1)) }
        // open, open, closing (dropped), reopened but settling (dropped), settled
        #expect(accepted == [true, true, false, false, true])
    }

    @Test func stallDetectorFlagsFrozenFramesOnly() {
        var user = SimulatedUser()
        var live = StallDetector()
        var frozen = StallDetector()
        let target = Point2(700, 400)
        var t = 0.0
        let still = user.frame(looking: target, t: 0, headMoving: false)
        for _ in 0..<45 {
            t += 1 / 30
            live.update(user.frame(looking: target, t: t, headMoving: false))
            var f = still
            f.timestamp = t
            f.iris.x += 0.00005 * sin(t * 50)   // the 0.0001-level noise seen in the stalled M5 data
            frozen.update(f)
        }
        #expect(!live.isStalled)
        #expect(frozen.isStalled)
    }

    @Test func faceTrackingStates() {
        var s = FaceTrackingState(pauseAfter: 2)
        s.update(faceFound: true, at: 0)
        #expect(s.isTracking)
        s.update(faceFound: false, at: 1)
        #expect(s.status == .lost(since: 1))
        s.update(faceFound: false, at: 2.5)
        #expect(s.status == .lost(since: 1))
        s.update(faceFound: false, at: 3.1)
        #expect(s.status == .paused)
        s.update(faceFound: true, at: 4)
        #expect(s.isTracking)
    }
}

@Suite struct ProfileTests {
    @Test func degreesAndProfileRoundTrip() throws {
        let g = ScreenGeometry(widthMM: 300, widthPoints: 1500)    // 0.2 mm/pt
        #expect(abs(g.degrees(points: 50, viewingDistanceMM: 573) - 1.0) < 0.01)

        var user = SimulatedUser()
        var samples: [GazeModel.Sample] = []
        for (i, target) in CalibrationLayout.nine.targets(in: user.screen).enumerated() {
            for j in 0..<5 { samples.append(.init(features: user.frame(looking: target, t: Double(i * 5 + j), headMoving: true), target: target)) }
        }
        let model = try #require(GazeModel.fit(samples, featureSet: .compact))
        let profile = CalibrationProfile(createdAt: Date(timeIntervalSince1970: 1_800_000_000), displayKey: "Built-in 1",
                                         cameraKey: "FaceTime HD", geometry: g, layout: .nine, model: model,
                                         crossValidatedErrorPoints: 20,
                                         validation: ValidationResult.evaluate(model, samples: samples, geometry: g),
                                         samples: samples)
        let back = try CalibrationProfile.decode(profile.encoded())
        #expect(back == profile)
        #expect(CalibrationProfile.fileName(displayKey: "Built-in 1", cameraKey: "Face/Time") == "profile-Built-in-1-Face-Time.json")
    }

    @Test func contourOffsetNormalisesByWidthAndLidOpening() throws {
        // Eye 40 wide, lids 10 apart; iris ring centred 4 right and 2 down of the contour centre.
        let contour = [Point2(560, 300), Point2(580, 295), Point2(600, 300), Point2(580, 305)]
        let ring = [Point2(582, 300), Point2(586, 302), Point2(584, 300), Point2(584, 304)]
        let eye = EyeFeatures(inner: Point2(600, 300), outer: Point2(560, 300), iris: Point2(584, 302), openness: 0.25,
                              contour: contour, irisRing: ring)
        let c = try #require(EyeLocal.contourOffset(eye))
        #expect(abs(c.x - 4.0 / 40) < 1e-9)
        #expect(abs(c.y - 1.5 / 10) < 1e-9)
        #expect(EyeLocal.contourOffset(EyeFeatures(inner: eye.inner, outer: eye.outer, iris: eye.iris, openness: 0.25)) == nil)
    }

    @Test func gazeFeaturesFromFaceFeatures() throws {
        let l = EyeFeatures(inner: Point2(600, 300), outer: Point2(560, 300), iris: Point2(580, 300), openness: 0.3)
        let r = EyeFeatures(inner: Point2(680, 300), outer: Point2(720, 300), iris: Point2(704, 300), openness: 0.32)
        let face = FaceFeatures(timestamp: 1, backend: "test", leftEye: l, rightEye: r,
                                headPose: HeadPose(yaw: 0.1, pitch: 0, roll: 0),
                                faceBounds: Rect2(x: 540, y: 220, width: 200, height: 220),
                                confidence: 1, processingMs: 5, imageWidth: 1280, imageHeight: 720)
        let g = try #require(GazeFeatures(face))
        #expect(abs(g.iris.x - 0.05) < 1e-9)           // left 0, right +0.1 → mean 0.05
        #expect(abs(g.interocularPx - 120) < 1e-9)
        #expect(abs(g.headPosition.x - 640 / 1280) < 1e-9)
        #expect(GazeFeatures(FaceFeatures(timestamp: 1, backend: "t", confidence: 0, processingMs: 1,
                                          imageWidth: 1280, imageHeight: 720)) == nil)
    }
}
