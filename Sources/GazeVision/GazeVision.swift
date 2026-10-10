import GazeKit

/// Backends available in this build.
public enum Backend: String, CaseIterable, Sendable {
    case vision
    case mediapipe
}
