# 0006 — Camera pipeline, gaze model and calibration

Status: accepted (M4/M5, 2026-10-11).

## Context
- **M4** runs the chosen backend (MediaPipe WASM in a `WKWebView`, ADR 0001) continuously inside the app and shows features in a HUD. Blinks and a lost face must not disturb anything downstream.
- **M5** adds calibration, the gaze mapping, filtering and validation in degrees. Head movement has to be part of the model from the start.

## Decision
### Pipeline (`GazelleApp/Camera/GazePipeline.swift`)
- **Frames.** The web view opens the camera itself and only posts landmark numbers. Frames are dropped by design (`requestVideoFrameCallback`) and never queued or written anywhere.
- **Hosting the web view.** WebKit only delivers *new* camera frames to a view in a window that is on screen and not covered. **Found in M5:** the first real calibration ran with the host panel underneath the full-screen calibration window. Frame callbacks kept firing at 30 fps, but with a stale image: all 776 samples had the same iris and pose values (σ ≈ 0.0001 eye widths). The model was then fitted to noise, giving a cross-validated error of 797 pt and a validation error of 3.5°.
  - **Fix:** the 64×48 click-through panel (alpha 0.02, bottom-left, all Spaces) now sits at screen-saver level + 1, above everything including the calibration window.
  - **Guard:** `StallDetector` flags frames whose iris and pose show no micro-movement for 1 s while a face is present. Those frames are dropped, the HUD shows "CAMERA STALLED", and calibration pauses instead of collecting.
  - The bad profile was moved aside with a `.stalled-bug` suffix.
- **Resolution: 1280×720.** Measured in the app's HUD, with CPU including WebKit helpers: 640×480 ran at 31 fps for 46 % CPU, and 1280×720 at 30 fps for 50 %. The cost is in WebKit and MediaPipe's fixed per-frame work, not the image size, so the higher resolution is kept. The ~25 % CPU target is **not met**. The next lever is a lower frame rate when idle (M9).
- **Features** (`GazeKit.GazeFeatures`): eye-local iris offsets per eye and their mean, openness, head pose, head position (normalised face centre), and head scale (interocular distance ÷ image width). A rough viewing distance comes from the interocular distance (62 mm average, 70° horizontal FOV assumed, ±20 %). It is used only to express errors in degrees.
- **Blink gating** (`BlinkGate`): a frame is a blink when openness drops below 0.65× the slowly tracked open level. Frames are gated while the eyes are closed and for 120 ms after they reopen.
- **Face lost** (`FaceTrackingState`): tracking → lost (HUD warning; M6 freezes the selection) → paused after 2 s without a face. It recovers on the first frame with a face.
- **When the camera runs:** only while the HUD or a calibration is open. M6 will add "while Active and calibrated".

### Gaze model (`GazeKit.GazeModel`)
- **Terms.** Two ridge regressions (screen x and y) over 20 standardised terms:
  - the intercept;
  - iris x and y, their squares and their product;
  - yaw, pitch and roll;
  - head position x and y, and head scale;
  - interactions: iris × yaw/pitch/scale/position;
  - yaw² and pitch².
- **Regularisation** is chosen by cross-validation over a λ grid, with folds grouped **by calibration target**, so a held-out fold is a set of screen points the model never saw.
- **Synthetic tests:** exact recovery of a mapping inside the model's function class (< 0.5 pt); recovery with ±20 pt label noise (< 6 pt); and a realistic, nonlinear simulated eye (< 40 pt held-out with the head moving).

### Calibration (`GazeKit.CalibrationSession`, `GazelleApp/Calibration`)
- **Three phases:**
  1. 9 dots with the head still: wait for an iris fixation (dispersion ≤ 0.03 eye widths for 0.35 s, 3 s at most), then collect 1 s of non-blink samples.
  2. A **head-motion phase on all 9 dots** (2 s each) while the user keeps looking at the dot and moves their head.
  3. 5 validation dots placed *between* the grid points, so they are genuinely held out.
- **Why all 9 dots in phase 2.** With the head-motion phase on only the centre and corners, the simulated user's held-out error with the head moving was 47 pt, against 18 pt with the head still (2.6×). With all nine dots it was 21 pt against 16 pt (1.3×). This costs about 15 s more; a run takes about 40 s.
- **Validation** reports, per point and on average, the error in points and in **degrees**. Point size comes from `CGDisplayScreenSize`, and distance from the interocular estimate. It also reports the jitter of predictions while fixating.
- **Profiles** are saved as JSON per display UUID and camera ID in `~/Library/Application Support/Gazelle/`. They hold the model, normalisation, samples (numbers only, kept as the M8 anchor set) and validation, and are restored at launch.
- **Filtering:** a One Euro filter (min cutoff 0.8 Hz, β 0.004) on the gaze point, and an I-DT fixation detector (60 pt dispersion, 150 ms) with a saccade threshold of 1,500 pt/s.

## Consequences
- **Calibration covers the main display only.** Other displays need their own profile, which will come with M9's multi-display work.
- **Degrees are approximate.** The viewing distance is estimated, so errors in degrees carry the ±20 % uncertainty of that estimate.

## To measure (fill in when run with the user)
| Item | Result |
|---|---|
| HUD fps | 30–31 ✔ |
| CPU % incl. WebKit helpers, 640×480 vs 1280×720 | 46 % vs 50 % (target ~25 % not met) |
| Blink: gaze/iris output stays put | not yet checked by hand |
| Camera covered: lost → paused after 2 s, recovers | not yet checked by hand |
| Calibration: validation error ° / pt, jitter ° | 1.59° / 103 pt (run 3), then 0.92° / 62 pt, jitter 0.99° (run 4). Eye-region model chosen (held-out 100 pt vs compact 106 pt in run 3). |

## Revision after the first real calibrations (2026-10-11)
**What happened.**
- Run 1 was fitted to a frozen camera image (see above).
- Run 2 had live data but reached only 5.5°.
  - The horizontal iris offset was not monotonic across rows: the top row decreased left to right, the bottom row increased.
  - The noise was a quarter of the screen range.
  - Head pitch was about −27°, looking down at the screen.
  - The fit chose the largest λ on offer and predicted near the centre.
- Offline, no subset of the compact features beat about 470 pt leave-one-target-out.

**Why, from the reference repos.** Per PLAN.md's reuse map, these were studied before going further.
- `shaal/eye-tracker` ADR-0019: my λ grid was absolute and capped at 10. With about 700 samples that is effectively no regularisation, which is the same failure they diagnosed, where head terms drowned the gaze signal.
- `shaal/eye-tracker` ADR-0025: their vertical gaze measured from iris landmarks collapsed to an intercept on real hardware. The lids track the eye, so vertical information lives in lid and brow movement relative to the face, not in the iris within the lid opening.
- `ck-zhang/EyeTrax`: it uses ~160 eye-region landmarks in 3D, in a head-aligned frame (iris, lids, brows, cheeks), plus pose, in one ridge regression. Its Lissajous pursuit calibration supplies many distinct targets.

**New decision.**
- `GroupedRidge`:
  - weighted standardisation;
  - λ = ratio × Σw over 10⁻⁶ … 10²;
  - λ chosen **per axis by leave-one-target-out**, scoring each held-out fixation as one observation;
  - per-group sufficient statistics accumulated once with BLAS, and one eigendecomposition per fold so the whole λ grid is cheap (a 486-feature fit takes ~1 s in a debug build).
  - GazeKit now uses Accelerate; it is still pure computation.
- `GazeModel` fits two feature sets and keeps the one with the lower held-out error:
  - `.compact`: eye-tracker's 18 terms, adding vergence and inverse distance;
  - `.eyeRegion`: EyeTrax's landmark vector, 161 × 3 + 3.
  The comparison is stored in the profile and logged.
- Calibration gains a **12 s Lissajous pursuit phase**. It is paired with the target 120 ms earlier and split into 8 groups for cross-validation. Validation samples are now saved in the profile for offline comparison.
- Synthetic tests:
  - exact recovery;
  - the noise floor;
  - pure-noise features shrinking to the mean, with a high held-out error reported (the stalled-camera case);
  - eye-region features chosen when they carry the signal.
