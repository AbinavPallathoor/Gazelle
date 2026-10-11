import Testing
@testable import GazeKit

/// End-to-end M8 checks on the simulated user: calibrate, then click on things.
@Suite struct OnlineCalibratorTests {
    struct World {
        var user = SimulatedUser()
        var t = 0.0
        var learner: OnlineCalibrator
        var rng = SplitMix64(seed: 77)

        init() throws {
            var user = SimulatedUser()
            var session = CalibrationSession(area: user.screen)
            var t = 0.0
            while !session.isFinished {
                let step = try #require(session.currentStep)
                t += 1 / 30
                session.update(user.frame(looking: step.target, t: t, headMoving: step.phase == .headMotion), at: t)
            }
            let (model, _) = try #require(GazeModel.fitCrossValidated(session.samples))
            let v = ValidationResult.evaluate(model, samples: session.validationSamples, geometry: ScreenGeometry(mmPerPoint: 0.2))
            learner = OnlineCalibrator(model: model, anchors: session.samples, baseSigma: v.meanErrorPoints)
            self.user = user
            self.t = t
        }

        /// The user fixates `look` for 0.5 s, then activates `target`.
        mutating func click(look: Point2, target: Rect2, rank: Int? = 0, fixating: Bool = true, faceOK: Bool = true)
            -> OnlineCalibrator.Decision {
            for _ in 0..<15 {
                t += 1 / 30
                learner.observe(user.frame(looking: look, t: t, headMoving: false), ok: faceOK, fixating: fixating, at: t)
            }
            t += 0.08
            let (decision, samples) = learner.confirm(target: target, rank: rank, at: t)
            if let samples, let m = learner.refit(samples) { learner.install(m) }
            return decision
        }

        mutating func randomButton() -> Rect2 {
            Rect2(x: rng.uniform(100, 1280), y: rng.uniform(80, 800), width: 60, height: 28)
        }

        mutating func error() -> Double {
            var errs: [Double] = []
            for target in CalibrationLayout.validationTargets(in: user.screen) {
                for _ in 0..<20 {
                    t += 1 / 30
                    errs.append((learner.predict(user.frame(looking: target, t: t, headMoving: false)) - target).length)
                }
            }
            return Stats.mean(errs)
        }
    }

    @Test func recoversFromDriftWithinBoundedConfirmations() throws {
        var w = try World()
        let baseline = w.error()
        w.user.bias = Point2(0.02, -0.012)            // e.g. the laptop screen was tilted
        let drifted = w.error()
        #expect(drifted > 2 * baseline, "drift should hurt: \(baseline) → \(drifted)")
        var accepted = 0
        for _ in 0..<25 {
            let b = w.randomButton()
            if case .accepted = w.click(look: b.center, target: b) { accepted += 1 }
        }
        let recovered = w.error()
        #expect(accepted >= 15)
        #expect(recovered < 1.5 * baseline + 10, "baseline \(baseline), drifted \(drifted), recovered \(recovered)")
    }

    @Test func farWrongClicksAreRejectedAndChangeNothing() throws {
        var w = try World()
        let before = w.error()
        for _ in 0..<20 {
            let look = w.randomButton()
            var wrong = look
            wrong.x = look.x > 720 ? look.x - 600 : look.x + 600     // activated something far away
            let d = w.click(look: look.center, target: wrong, rank: nil)
            #expect(d == .rejected(.implausibleTarget))
        }
        #expect(w.learner.state.accepted == 0)
        #expect(abs(w.error() - before) < 2)       // only fresh measurement noise
    }

    @Test func subtlyWrongClicksDoNotCorruptTheModel() throws {
        var w = try World()
        let before = w.error()
        for i in 0..<40 {
            let look = w.randomButton()
            var target = look
            if i % 3 == 0 { target.x += 90 }                         // the neighbour was activated
            _ = w.click(look: look.center, target: target, rank: i % 3 == 0 ? 1 : 0)
        }
        let after = w.error()
        #expect(after < before + 25, "before \(before), after \(after)")
    }

    @Test func largeTargetsAndMissingFixationsAreRejected() throws {
        var w = try World()
        let row = Rect2(x: 100, y: 300, width: 800, height: 30)
        #expect(w.click(look: row.center, target: row) == .rejected(.targetTooLarge))
        let b = w.randomButton()
        #expect(w.click(look: b.center, target: b, fixating: false) == .rejected(.noFixation))
        #expect(w.click(look: b.center, target: b, faceOK: false) == .rejected(.noFixation))
        #expect(w.learner.state.accepted == 0)
    }

    @Test func recentreRemovesAConstantBiasAndSigmaTracksError() throws {
        var w = try World()
        w.user.bias = Point2(0.015, 0.0)
        let drifted = w.error()
        var preds: [Point2] = []
        let center = Point2(720, 450)
        for _ in 0..<30 {
            w.t += 1 / 30
            preds.append(w.learner.predict(w.user.frame(looking: center, t: w.t, headMoving: false)))
        }
        w.learner.recentre(predictions: preds, target: center)
        #expect(w.error() < 0.6 * drifted)
        #expect(w.learner.sigma >= w.learner.config.minSigma)
    }
}
