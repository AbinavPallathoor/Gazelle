# Gazelle

**Look at it, press a key.** Gazelle is a macOS menu-bar app that lets you use your Mac without a trackpad. Your webcam estimates where you are looking, Gazelle snaps that to the nearest clickable thing on screen and outlines it, and the keyboard finishes the job: arrow keys move to neighbouring elements and Return clicks.

- **Gaze never clicks.** Only an explicit key press activates anything.
- **It runs entirely on your Mac.** It has no network code, and camera frames are never written to disk.
- **There is one short calibration,** after which Gazelle keeps correcting itself from the clicks you make.

> **Status:** work in progress. Milestones M0–M6 and M8 of [PLAN.md](PLAN.md) are done and run on the developer's Mac: element map, keyboard navigation, camera pipeline, calibration, gaze-driven selection and online learning. Head-movement robustness (M7), hardening and a signed release (M9) are next.
> Measured held-out gaze error on a MacBook Air webcam: **0.92°** (≈ 62 pt). Details in [docs/EVAL.md](docs/EVAL.md).

---

## How it works

```
webcam ─► MediaPipe Face Landmarker (WASM, in a hidden WKWebView)
        ─► eye features: head-aligned eye-region landmarks + iris + head pose
        ─► gaze model: ridge regression fitted at calibration, refined from your clicks
        ─► smoothing: One Euro filter + fixation detection
        ─► snapping: most likely clickable element, given the gaze point and its error σ
        ─► yellow outline ─► arrow keys / Return ─► Accessibility press or synthesised click
Accessibility API ─► element map: every clickable element on screen, kept current
```

- **Element map.** Gazelle reads the Accessibility tree of the frontmost app, the menu bar, menu extras and the Dock, keeping buttons, links, fields, tabs, rows and so on. It refreshes on Accessibility notifications rather than polling, typically 35–160 ms after a change. Elements behind other windows are dropped. Electron and Chromium apps are supported.
- **Keyboard navigation.** Arrow keys move to the nearest element in that direction, preferring the same row or column. Tab moves in reading order. Actions use Accessibility first (`AXPress`, `AXShowMenu`), so the pointer doesn't move, and fall back to a real click.
- **Gaze.** Calibration takes about a minute:
  - 9 dots with your head still;
  - a moving dot to follow;
  - 9 dots while you move your head;
  - 5 check dots that report the error in degrees.
  The model compares two feature sets and keeps the better one on held-out targets.
- **Snapping.** Candidates are scored by distance ÷ σ, with hysteresis so the outline doesn't flicker. Any arrow key locks the selection to the keyboard until you look clearly elsewhere.
- **No recalibration.** Every click on a button or link becomes a training sample. Strict safeguards reject wrong or noisy clicks, and your original calibration stays as an anchor.

## Requirements

- macOS 14 or later (developed on macOS 26, Apple silicon).
- Xcode (used through `DEVELOPER_DIR`; `xcode-select` can stay on the Command Line Tools) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- An Apple Development signing certificate. A free Apple ID works. Without a stable certificate, macOS forgets the app's permissions on every rebuild. See [docs/SIGNING.md](docs/SIGNING.md).
- A webcam: the built-in camera is fine.

## Build and run

```sh
make signing   # once: writes Config/Local.xcconfig with your Apple Development identity
make run       # generate the Xcode project, build, and launch the menu-bar app
make test      # GazeKit unit tests (swift test) + app tests (xcodebuild test)
```

On first launch, Gazelle shows a permissions window. Grant **Camera** and **Accessibility**, and **Input Monitoring** for keyboard navigation. **Screen Recording** is optional; it's for a planned fallback for apps with poor accessibility support.

## Using it

| Shortcut | What it does |
|---|---|
| **⌃⌥G** | Toggle **Active**: the outline follows your gaze, and keys act on it |
| **⌃⌥K** | **Kill switch**: stops everything immediately; re-arm it from the menu |
| ← → ↑ ↓ | Move to the nearest element in that direction (while Active) |
| Tab / ⇧Tab | Next / previous element |
| Return | Click |
| ⇧Return / ⌥Return / ⌘Return | Right-click / double-click / focus without clicking |
| Esc | Leave Active |
| **⌃⌥D** | Show the gaze dot (starts a calibration if there is none) |
| **⌃⌥H** | Debug HUD: fps, CPU, eye features, accuracy, learning |
| **⌃⌥B** | Debug overlay: boxes around every detected element |
| **⌃⌥R** | Quick one-dot re-centre when accuracy drifts |

Start with menu → **Calibrate…**. Sit as you normally do, ideally facing the screen.

## Repository layout

```
Sources/GazeKit/       Pure Swift (Foundation + Accelerate), fully unit-tested:
                       features, mapping, filtering, calibration, snapping, navigation, learning
Sources/GazeVision/    Camera backends: MediaPipe in WKWebView (chosen), Apple Vision (comparison)
Sources/GazelleApp/    The app: menu bar, permissions, Accessibility element map, overlays,
                       event tap, calibration UI, HUD
Sources/gazespike/     Developer tool: record/analyse backends, replay-tune the gaze filter
Tests/                 GazeKitTests (Swift Testing), GazelleAppTests (XCTest), recorded fixtures
docs/adr/              Architecture decision records: every non-obvious choice, with measurements
docs/                  EVAL.md (results), MANUAL_CHECKS.md, SIGNING.md, THIRD_PARTY.md
PLAN.md                The build plan, milestone by milestone
```

Only numeric features are ever recorded. Calibration profiles live in `~/Library/Application Support/Gazelle/`.

## Privacy and safety

- **No network code.** The bundled MediaPipe page is additionally blocked from making http(s) or ws(s) requests.
- **Camera frames stay in memory** inside the web view. Only landmark numbers reach the app.
- **The camera runs only when something uses it:** Active with a calibration, the HUD, the gaze dot, or a calibration in progress.
- **Gaze never triggers an action.** The keyboard tap swallows only Gazelle's keys, and only while Active. The kill switch works from any app, and the tap also recognises it directly.

## Credits

Gazelle builds on ideas and measurements from open-source projects (details in [docs/THIRD_PARTY.md](docs/THIRD_PARTY.md)):

- [shaal/eye-tracker](https://github.com/shaal/eye-tracker) (MIT): its architecture decision records on ridge mapping, λ selection by held-out target, head-motion calibration and vertical-gaze pitfalls shaped Gazelle's model.
- [ck-zhang/EyeTrax](https://github.com/ck-zhang/EyeTrax) (MIT): eye-region landmark features and Lissajous pursuit calibration.
- [MediaPipe Face Landmarker](https://ai.google.dev/edge/mediapipe/solutions/vision/face_landmarker) (Apache-2.0): vendored WASM build and model.

## License

No license has been chosen yet; all rights reserved until one is added.
