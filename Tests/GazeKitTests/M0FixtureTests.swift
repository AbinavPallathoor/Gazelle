import Foundation
import Testing
@testable import GazeKit

/// Replays the M0 recordings (numeric features only) and checks the numbers ADR 0001 relies on.
@Suite struct M0FixtureTests {
    static let dir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/m0")

    static func metrics(_ name: String) throws -> SessionMetrics {
        let data = try Data(contentsOf: dir.appendingPathComponent("\(name).jsonl"))
        return SessionMetrics(recording: try Recording.decode(jsonl: data))
    }

    @Test(arguments: ["vision-still", "vision-moving", "mediapipe-gpu-still", "mediapipe-gpu-moving"])
    func recordingsAreComplete(_ name: String) throws {
        let m = try Self.metrics(name)
        #expect(m.frames > 1700)
        #expect(m.fps > 29)
        #expect(m.faceFoundPercent > 99)
    }

    @Test func mediapipeIsSteadierThanVision() throws {
        for label in ["still", "moving"] {
            let v = try Self.metrics("vision-\(label)")
            let mp = try Self.metrics("mediapipe-gpu-\(label)")
            #expect(mp.irisFrameJitter < v.irisFrameJitter / 2, "\(label)")
            #expect(mp.irisResidualStd < v.irisResidualStd / 1.5, "\(label)")
        }
    }

    @Test func movingRunsActuallyMovedTheHead() throws {
        for name in ["vision-moving", "mediapipe-gpu-moving"] {
            let m = try Self.metrics(name)
            #expect(max(m.yawStdDeg, m.pitchStdDeg) > 3, "\(name)")
        }
    }
}
