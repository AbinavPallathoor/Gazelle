# 0002 — Package layout: GazeKit, GazeVision, gazespike

Status: accepted (M0, 2026-10-11)

## Context
PLAN.md requires all logic that does not need the camera, screen or Accessibility to live in the pure, fully tested `GazeKit` package. The vision backends need AVFoundation, Vision and WebKit, and both the M0 harness and the M1 app must share them.

## Decision
`Package.swift` defines three targets:
- **`GazeKit`:** Foundation only, Swift 6 language mode. It holds the feature types, the `FaceFeatureProvider` protocol (`@MainActor`), eye-local coordinates, statistics, ridge regression and the recording format.
- **`GazeVision`:** the camera and backends (`CameraCapture`, `AppleVisionProvider`, `MediaPipeWebProvider`) and the bundled MediaPipe resources. It uses Swift 5 language mode for now, because the AVFoundation and WebKit delegate APIs are not yet clean under strict concurrency. The M1 app target links this library.
- **`gazespike`:** the throwaway M0 harness (record/analyze). Its Info.plist is embedded through `-sectcreate` so WebKit and camera access have a usage description. It can be deleted once the app has its own replay and HUD tooling.

## Consequences
- The app target in M1 (XcodeGen) depends on the local package's `GazeKit` and `GazeVision` products.
- The linker flag (`unsafeFlags`) is allowed only because this is a root package. It is never consumed as a dependency.
- Test fixtures are read via `#filePath`-relative paths instead of bundle resources. This keeps the large `.jsonl` files out of the test bundle.
