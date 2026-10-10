# 0001 — Vision backend: MediaPipe Face Landmarker (WASM in WKWebView)

Status: accepted (M0, 2026-10-11)

## Context

Gazelle needs per-frame eye corners, iris centres and head pose from the built-in webcam at about 30 fps.
PLAN.md §2 listed three candidates and asked M0 to choose by measurement:

1. **Apple Vision.** `VNDetectFaceLandmarksRequest` provides pupils and eye regions, and the face observation carries yaw/pitch/roll.
2. **MediaPipe Face Landmarker.** It provides 478 landmarks, including iris landmarks 468–477, plus a facial transformation matrix.
3. **An appearance-based CNN** (ETH-XGaze / L2CS-Net in CoreML). This is deferred to M7 as an optional fusion model.

### MediaPipe native on macOS: not available
The CocoaPods spec for `MediaPipeTasksVision` 1.0.0 declares `platforms: { ios: 15.0 }`. Its xcframework contains only `ios-arm64` and `ios-arm64_x86_64-simulator` slices: no macOS and no Mac Catalyst. Re-tagging the iOS slice for macOS would be fragile and unsupported. The candidate was therefore run as the official WASM build (`@mediapipe/tasks-vision` 1.1.0, Apache-2.0) inside a `WKWebView`.

## Measurements

Setup:
- Hardware: Apple M4 MacBook Air, macOS 26.6.2, built-in camera at 1280×720 and 30 fps, indoor lighting.
- Protocol: `make m0-record` runs 60 s looking at a centred dot with the head still, then 60 s looking at the same dot while turning, tilting and shifting the head.
- Data: the recordings are in `Tests/Fixtures/m0/` (numeric features only) and are re-checked by `M0FixtureTests`.

| backend | label | frames | fps | latency p50/p95 ms | CPU % | face % | iris std (ew) | iris frame jitter (ew) | iris residual after head regression (ew) | yaw/pitch/roll std ° |
|---|---|---|---|---|---|---|---|---|---|---|
| vision | still | 1818 | 30.0 | 19.1 / 24.0 | 41 | 100.0 | 0.0158 | 0.0094 | 0.0152 | 0.5 / 1.1 / 0.6 |
| vision | moving | 1813 | 30.0 | 19.8 / 24.5 | 42 | 99.9 | 0.0467 | 0.0237 | 0.0440 | 8.4 / 4.7 / 7.3 |
| mediapipe (GPU) | still | 1823 | 30.0 | 13.0 / 15.0 | 48 | 100.0 | 0.0106 | 0.0016 | 0.0066 | 0.2 / 0.9 / 0.3 |
| mediapipe (GPU) | moving | 1808 | 30.0 | 14.0 / 15.0 | 48 | 100.0 | 0.0376 | 0.0064 | 0.0215 | 7.0 / 5.1 / 6.3 |

How to read the columns:
- **ew = eye widths.** Iris position is measured in a frame attached to the eye corners, which cancels head roll, translation and scale (`GazeKit/Features/EyeLocal.swift`). As a rough guide, 0.01 ew ≈ 0.3 mm of iris travel ≈ 1.4° of eye rotation.
- **Iris frame jitter:** the white-noise level from successive differences. It ignores slow drift.
- **Iris residual after head regression:** iris variation left after a linear fit on head pose and face position/size. Gaze stays on one dot throughout, so this approximates the noise a head-aware mapping would still face. It also contains real fixational eye movement.
- **CPU:** percent of one core.
  - MediaPipe includes the WebKit WebContent, GPU and Networking helper processes.
  - Vision work done on the Neural Engine or GPU is not counted as CPU.
- **Latency:** feature extraction time per frame only, not capture-to-output time.

## Decision

Use **MediaPipe Face Landmarker, WASM build in a `WKWebView`, GPU delegate** as the production `FaceFeatureProvider` (`GazeVision/MediaPipeWebProvider.swift`). Keep `AppleVisionProvider` as a fallback and as a second opinion for face-lost detection.

Reasons:
- **Steadier iris signal:** about 6× lower frame jitter with the head still, and about 3.7× lower with the head moving.
- **Less unexplained variation after head regression:** about 2.3× lower still (≈ 0.9° vs ≈ 2.2°) and about 2× lower moving. This is the number that bounds achievable gaze accuracy.
- **Faster:** 13 ms vs 19 ms per frame, with a much tighter p95.
- **Real iris landmarks:** Vision's pupil points are estimates that Apple documents as unreliable during blinks.
- **Full head pose:** the transformation matrix gives continuous pose, and the landmarks give face size for distance.

## Consequences

- **Web view must be in a window.** The `WKWebView` has to be in a window for WebKit to keep delivering frames. The app will host it in a tiny or offscreen-positioned panel; verify this in M4.
- **The page owns the camera** through `getUserMedia`. The WebKit permission prompt is auto-granted for camera only, behind macOS camera TCC.
- **Privacy:**
  - All assets (JS, WASM, the 3.7 MB `.task` model) are bundled.
  - A `WKContentRuleList` blocks http(s) and ws(s) loads. This was verified in M0: a test `fetch('https://example.com')` from the page failed.
  - WebKit still starts its Networking helper process, which is idle. The M9 "no network code" test must allow for this.
- **Possible hidden smoothing.** MediaPipe's VIDEO mode may smooth landmarks over time. Part of the jitter advantage could be smoothing, which adds lag. M4 must measure capture-to-feature latency with a step stimulus (a quick saccade) before final filter tuning.
- **Workarounds and their costs:**
  - First-detection GPU warm-up blocks for several seconds. The page runs one warm-up detection before reporting ready.
  - `file://` fetches return status 0, so the page loads the model bytes itself and passes `modelAssetBuffer`.
  - These rely on WebKit preferences set by KVC (`allowFileAccessFromFileURLs`). If a future macOS breaks this, switch to a `WKURLSchemeHandler` that serves the bundle.
- **CPU is about 48%** of one core while tracking at 30 fps, just under half a core. The M4 target is under ~25%. Options:
  - lower the input resolution (MediaPipe works internally at 256×256, so 640×480 is likely enough);
  - run at a lower frame rate when idle;
  - compare the CPU delegate (`gazespike record --delegate CPU`).
- **Apple Vision findings, if it is used again:**
  - Run `VNDetectFaceRectanglesRequest` rev 3 in the same `perform` call as landmarks, using a per-frame `VNImageRequestHandler`. Otherwise yaw/pitch/roll come back as 0 or in 30° steps.
  - Set explicit width and height in the `AVCaptureVideoDataOutput` settings. Otherwise macOS delivers native 1920×1080 regardless of the preset.
