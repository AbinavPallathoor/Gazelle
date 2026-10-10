# Third-party components

| Component | Version | Licence | Location | Source |
|---|---|---|---|---|
| MediaPipe Tasks Vision (JS + WASM) | 1.1.0 | Apache-2.0 | `Sources/GazeVision/Resources/mediapipe/vision_bundle.mjs`, `wasm/` | npm `@mediapipe/tasks-vision` |
| MediaPipe Face Landmarker model (float16) | latest as of 2026-10-11 | Apache-2.0 | `Sources/GazeVision/Resources/mediapipe/face_landmarker.task` | storage.googleapis.com/mediapipe-models |

The files are vendored unmodified and loaded locally; the app downloads nothing at runtime.
Full licence text: https://www.apache.org/licenses/LICENSE-2.0
