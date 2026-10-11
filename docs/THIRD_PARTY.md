# Third-party components

| Component | Version | Licence | Location | Source |
|---|---|---|---|---|
| MediaPipe Tasks Vision (JS + WASM) | 1.1.0 | Apache-2.0 | `Sources/GazeVision/Resources/mediapipe/vision_bundle.mjs`, `wasm/` | npm `@mediapipe/tasks-vision` |
| MediaPipe Face Landmarker model (float16) | latest as of 2026-10-11 | Apache-2.0 | `Sources/GazeVision/Resources/mediapipe/face_landmarker.task` | storage.googleapis.com/mediapipe-models |

## Ported logic (no code copied verbatim beyond index tables)

| Source | Licence | What | Where |
|---|---|---|---|
| ck-zhang/EyeTrax | MIT | Eye-region landmark index lists; head-aligned landmark normalisation; Lissajous pursuit calibration | `GazeKit/Features/EyeRegion.swift`, `CalibrationSession` |
| shaal/eye-tracker | MIT | Design lessons (ADRs 0005/0006/0015/0019/0021/0025): 18-term compact features, λ by leave-one-target-out per axis, λ ∝ Σw, weighted standardisation, head-motion phase | `GazeKit/Mapping/GroupedRidge.swift`, `GazeModel.swift` |

The files are vendored unmodified and loaded locally; the app downloads nothing at runtime.
Full licence text: https://www.apache.org/licenses/LICENSE-2.0
