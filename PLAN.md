# GazeKeys — Build Plan for Claude Code

A macOS menu-bar app. Your webcam estimates where you are looking; the app snaps that to the nearest clickable UI element, outlines it, and lets the keyboard move to neighbouring elements and activate the one you want. No trackpad needed. It must stay accurate when your head moves and must not need repeated recalibration.

---

## 0. How to use this file

Give this file to Claude Code at the root of a new repo, then work **one milestone at a time**.

- Do not start milestone N+1 until every acceptance check of milestone N passes.
- Commit at the end of each milestone with the milestone name in the message.
- Keep all logic that does not need the camera, the screen, or the Accessibility API inside the pure Swift package `GazeKit` (section 3). Test it with `swift test`.
- The camera, Accessibility API, overlay and key interception cannot be unit-tested because they need macOS permissions. Put them behind protocols with mock implementations, and add each one's manual check to `docs/MANUAL_CHECKS.md`.
- Record every non-obvious decision in `docs/adr/NNNN-title.md` (context, decision, consequences). The reference repo `shaal/eye-tracker` does this and it is worth copying.
- Where this plan says "target", that is a goal to measure against, not a result already achieved.

---

## 1. Product spec

### Core behaviour
1. **Element map.** Read every clickable element on screen (frontmost window, menu bar, Dock, system UI) with its bounding box and role.
2. **Gaze snap.** Estimate the gaze point, rank candidate elements by how likely each is the target, and mark the top one as *selected*.
3. **Outline.** Draw a clean outline around the selected element in a click-through overlay.
4. **Keyboard.** Arrow keys move the selection to the nearest element in that direction. Another key activates the selection. Keys act on the selection, never on the raw gaze point.
5. **Actions.** Left click, right click, double click, and (stretch) drag and scroll.
6. **Head robustness.** Accuracy must hold when the head moves, turns or changes distance.
7. **No recalibration.** One short initial calibration, then the system keeps correcting itself while you work.

### Required supporting features
- Global kill switch that always works, even if gaze goes wrong, and automatic pause when the face is lost.
- Calibration with a validation step that reports error in degrees.
- Persisted calibration profile, restored on launch.
- Multi-display support.
- Debug HUD (gaze point, confidence, error estimate, candidate scores).
- Permission onboarding (Camera, Accessibility, Input Monitoring, Screen Recording).
- Privacy: no network code, camera frames never written to disk, optional local recording of feature data only.

### Engagement model (default, configurable)
- A global hotkey toggles **Active**. When Active, the outline follows gaze.
- Pressing any navigation key **locks** the selection to the keyboard. Gaze takes over again only after a deliberate large eye movement away from the locked element or after a short idle time.
- Gaze never clicks. Only an explicit key activates. This avoids the "Midas touch" problem where looking at something triggers it.

---

## 2. Technical decisions and what is verified

### Decided
- **Language and UI:** Swift, SwiftUI for settings and onboarding, AppKit for the overlay and event handling. Project generated with **XcodeGen** (`project.yml`) to avoid `.pbxproj` merge conflicts.
- **Not Electron.** `shaal/eye-tracker` uses Electron plus Rust; this app needs the Accessibility API, overlay panels and global key events, which are all simpler natively.
- **App is not sandboxed** (Accessibility control is incompatible with the App Store sandbox). Use hardened runtime and distribute with Developer ID.
- **Permissions reset on rebuild** unless the app is signed with a stable certificate. Vimac's README documents re-granting Accessibility permission after clean builds. Sign every dev build with the same Apple Development certificate from day one.

### Vision backend: decided by milestone M0, not assumed
| Option | Known facts | Unknowns to measure in M0 |
|---|---|---|
| Apple Vision (`VNDetectFaceLandmarksRequest`) | `leftPupil` and `rightPupil` exist from macOS 10.13. Apple documents that pupil values "may be inaccurate if the eye is blinking". Yaw, pitch and roll are available on the face observation. | Pupil stability, jitter, whether accuracy is enough for gaze, no 3D iris. |
| MediaPipe Face Landmarker | 478 landmarks, 52 blendshapes, and a facial transformation matrix (head pose). Live-stream mode available. The official Swift docs cover **iOS only**, installed via Swift Package Manager (`MediaPipeTasksVision`). | Whether it runs on macOS natively. If not: run it inside a `WKWebView` using the WASM build (as `shaal/eye-tracker` does in Electron), or in a helper process. |
| Appearance-based CNN (L2CS-Net, ETH-XGaze baseline) converted to CoreML | ETH-XGaze was built for extreme head poses. | Conversion effort, latency, accuracy on a laptop webcam. |

Define a `FaceFeatureProvider` protocol in `GazeKit` so the backend can be swapped without touching anything else.

### Reuse map
| Need | Source | How |
|---|---|---|
| Gaze mapping design: ridge regression, fixation vs saccade filtering, head-motion calibration phase, cross-validated error in degrees | `shaal/eye-tracker` (MIT) | Read `docs/adrs/` and re-implement in Swift. Do not import the Electron or Rust code. |
| Accessibility element discovery, hint generation, Vision OCR fallback | `y3owk1n/neru` (MIT, Go and Objective-C) | Read how it walks the AX tree and which roles it keeps. Port the logic to Swift. |
| Calibration routines, Kalman, KDE filters | `ck-zhang/EyeTrax` (MIT, Python) | Reference only. |
| Self-calibrating from user interactions | `brownhci/WebGazer` | Concept only. License terms differ by company size, so do not copy code. |
| Head-pose-robust gaze models and data | `xucong-zhang/ETH-XGaze`, L2CS-Net | Optional fallback model (milestone M7). |
| Native Swift pipeline example | `Geltrax69/EyeTracker` | **Reference at most.** Verified on 2026-10-11: 4 commits, 0 stars, no licence file, and its README says it was never compiled. Do not use it as a base and do not copy code from it. |

Clone references into `reference/` (git-ignored). Never copy source from a repo without checking its licence first.

---

## 3. Repository layout

```
GazeKeys/
  project.yml                 XcodeGen spec
  Package.swift               GazeKit local package
  CLAUDE.md                   section 9
  PLAN.md                     this file
  docs/
    adr/                      decision records
    MANUAL_CHECKS.md          checks that need real permissions
    EVAL.md                   evaluation protocol and results
  reference/                  git-ignored clones of other repos
  Sources/
    GazeKit/                  PURE SWIFT, no AppKit. Fully unit-tested.
      Features/               FaceFeatures, eye-local coordinates, head pose
      Mapping/                ridge regression, polynomial features, RLS update
      Filtering/              One Euro, fixation detector, blink gating
      Snap/                   candidate scoring, hysteresis
      Navigation/             directional nearest-element search, reading order
      Calibration/            targets, sample collection, validation, profile
      Geometry/               px, points, degrees, display conversions
    GazeKeysApp/              app target (AppKit and SwiftUI)
      Camera/                 AVFoundation capture, FaceFeatureProvider backends
      Elements/               AX tree walker, observers, OCR fallback
      Overlay/                click-through outline panel, calibration screen
      Input/                  CGEventTap, hotkeys, action dispatch
      Permissions/            onboarding and status checks
      Settings/               SwiftUI preferences
      Debug/                  HUD
  Tests/
    GazeKitTests/             unit tests, synthetic data
    Fixtures/                 recorded feature streams (no video)
```

---

## 4. Data flow

```
camera frame
  → FaceFeatureProvider      landmarks, iris, head pose
  → Features                 eye-local iris offsets, openness, head pose, head distance
  → Mapping                  calibrated regression → raw gaze point (screen px)
  → Filtering                blink gate, One Euro, fixation detection
  → Snap                     candidate elements scored against gaze + error estimate
  → Selection state machine  gaze-driven vs keyboard-locked
  → Overlay                  outline on selected element
Keyboard → Navigation → Selection state machine → Action (AXPress or CGEvent click)
Confirmed action → Learn    adds a labelled sample, updates Mapping online (M8)
AX tree → ElementStore      always current set of elements with boxes and roles
```

---

## 5. Milestones

Each milestone lists the work, then acceptance checks. "Claude Code task" is the instruction to give it for that milestone.

### M0 — Spike: pick the vision backend (2–3 days)
**Claude Code task:** "Build a throwaway command-line target that captures the webcam and prints, for each backend, per-frame face features. Compare backends on my Mac."

- Build minimal harnesses for: Apple Vision pupil landmarks; MediaPipe (try native macOS first, then WKWebView WASM).
- Record 60 s of me looking at a fixed point with the head still, then 60 s with the head moving. Compute landmark jitter (std dev) and processing latency, frame rate and CPU.
- Write `docs/adr/0001-vision-backend.md` with the numbers and the choice.

**Acceptance:** a table of jitter, latency, fps and CPU for each backend; a recorded decision; a working `FaceFeatureProvider` for the chosen backend producing eye corners, iris centres and head pose at 30 fps.

### M1 — Scaffold, permissions, kill switch
**Claude Code task:** "Create the XcodeGen project, the GazeKit package, a menu-bar app with permission onboarding, and the global kill switch."

- Menu-bar app with status item; onboarding screens that check Camera, Accessibility, Input Monitoring and Screen Recording and deep-link to System Settings.
- Hardened runtime, entitlements for camera, stable signing identity documented in `docs/SIGNING.md`.
- Global hotkey to toggle Active, and a separate kill switch that disables all input interception. If the kill switch cannot be registered, the app refuses to activate.
- CI-free local scripts: `make build`, `make test`.

**Acceptance:** app launches, shows correct permission status, survives a rebuild without losing permissions, kill switch toggles from any app.

### M2 — Element map
**Claude Code task:** "Build the Accessibility-based element store and a debug overlay that draws every clickable element's box."

- Walk `AXUIElement` trees for the frontmost app's windows, the menu bar, the Dock and system UI. Keep elements that are pressable or editable (buttons, links, checkboxes, radio buttons, pop-ups, menu items, tabs, text fields, rows, sliders) and are visible and on screen.
- Handle coordinates: AX uses top-left global points; AppKit uses bottom-left. Convert correctly on multiple displays.
- Performance: set messaging timeouts, limit depth, cache, and refresh with `AXObserver` notifications (window moved, resized, focus changed, value changed) instead of polling the whole tree.
- Electron and Chromium apps: set `AXManualAccessibility = true` on the app element (documented by Electron for assistive tools) and test Chrome separately; record findings in an ADR.
- Occlusion: drop elements hidden behind other windows.
- Debug overlay: boxes coloured by role, toggled by a hotkey.

**Acceptance:** boxes match visible controls in Finder, Safari, System Settings, Terminal, VS Code (Electron) and Chrome; refresh latency after a window change under ~200 ms; no UI freezes in the target app.

### M3 — Keyboard-only navigation and actions
**Claude Code task:** "Add the selection model, directional navigation, the outline overlay and click actions, with no camera involved."

- Selection outline: rounded, high-contrast, animated between elements, drawn in a non-activating click-through `NSPanel` that appears over full-screen apps and on all Spaces.
- Directional move: from the selected element, search in a cone toward the pressed direction and pick the best by distance and alignment (same idea as spatial focus navigation). Also next/previous in reading order.
- Intercept keys with a `CGEventTap` only while Active, and swallow only the navigation and action keys.
- Actions: prefer `AXPress` (no cursor movement); fall back to a synthesised `CGEvent` click at the box centre. Right click, double click, and a modifier for "focus only".
- Start selection from the keyboard-focused element or the element nearest the mouse pointer.

**Acceptance:** the whole app is usable with keyboard only, no camera running. Unit tests for directional navigation on synthetic layouts (grids, rows, overlapping, ragged edges). This milestone is already a useful mouseless tool.

### M4 — Camera pipeline and live HUD
**Claude Code task:** "Run the chosen FaceFeatureProvider continuously and show features in the debug HUD."

- Capture on a dedicated queue; drop frames instead of queuing; timestamp each frame.
- Compute eye-local features: iris position within each eye in a coordinate system aligned to the line between the eye corners (removes head roll), eye openness (blink detection), head pose, and head distance estimated from face size.
- Blink gating: ignore frames while the eye is closing or opening.
- Face-lost handling: freeze selection, show a warning, and pause if lost longer than a set time.

**Acceptance:** HUD shows stable features at ≥ 25 fps; CPU under ~25% on my Mac (target); blinks produce no jumps downstream; covering the camera pauses the app cleanly.

### M5 — Calibration, mapping, filtering, validation
**Claude Code task:** "Implement calibration, the regression mapping and filters in GazeKit with tests, then a calibration UI."

- Calibration UI: full-screen dots (9 points; option for 13 or 25), each requires a stable fixation before samples are accepted. Reject samples taken during blinks.
- Add a **head-motion phase**: the user fixates each dot while slightly moving the head. This is what makes head movement tolerable; `shaal/eye-tracker` documents head turning being unreliable without it.
- Mapping: ridge regression on polynomial features of the eye-local iris offsets **plus head pose and head position terms**, so head movement is part of the model, not an afterthought. Choose regularisation by cross-validation.
- Filter: One Euro filter, a fixation detector (stay stable inside a small radius) and a saccade detector, so the output is steady during fixations and fast during jumps.
- Validation pass after calibration: show dots, measure held-out error in **degrees** and px. Convert using display physical size (`CGDisplayScreenSize`) and the estimated viewing distance.
- Persist the profile per display and camera.

**Acceptance:** unit tests recover a known synthetic mapping with added noise; the app reports held-out error in degrees; steady-fixation jitter is below a threshold written into `docs/EVAL.md`.

### M6 — Gaze drives the selection
**Claude Code task:** "Connect gaze to snapping using a probabilistic candidate score and a selection state machine."

- Score each candidate by the likelihood that the true target is that element, given the gaze point and the current error estimate σ: use the distance from the gaze point to the element's box (0 if inside), divided by σ, so large uncertainty spreads probability across neighbours instead of making hard wrong choices.
- Add hysteresis: the current selection gets a bonus, and a new element must win by a margin for a minimum time before the outline moves. This stops flicker.
- Prefer elements in the window being looked at; apply small priors for recently used elements.
- State machine: `gazeDriven → keyboardLocked → gazeDriven`, with the rules from section 1.
- When the top two candidates are close, keep the outline on the best and let arrow keys step to the runner-up. Never auto-activate anything.

**Acceptance:** with a decent calibration, looking at a button outlines it without flicker; arrow keys correct a wrong pick; unit tests cover hysteresis and the state machine with scripted gaze traces.

### M7 — Head-movement robustness
**Claude Code task:** "Build the head-movement test protocol, measure, then improve until the targets are met."

- Add a repeatable protocol to `docs/EVAL.md`: fixate a fixed set of screen dots while (a) sitting still, (b) moving the head sideways, (c) leaning closer and further, (d) yawing and pitching moderately. Log error for each condition.
- Improve features and model until error under head movement is close to error when still. Options in order: richer pose terms in the regression; separate models per head-pose bucket blended smoothly; a head-pose-robust appearance model (ETH-XGaze or L2CS-Net converted to CoreML) fused with the landmark model.
- Detect head poses outside the calibrated range and lower confidence (σ grows), so snapping gets more tolerant instead of wrong.

**Acceptance:** `docs/EVAL.md` contains a before and after table per condition. Targets: error with moderate head movement within ~1.5× of the still error; confidence correctly rises in error when the pose leaves the calibrated range.

### M8 — Online learning and drift control (the "no recalibration" part)
**Claude Code task:** "Implement implicit calibration from confirmed selections with safeguards, and a drift monitor."

- Every activation is a free labelled sample: the gaze fixation just before the key press versus the activated element's centre.
- Update the regression online with recursive least squares and a forgetting factor so recent samples matter more.
- **Safeguards against poisoning:** accept a sample only if (a) there was a stable fixation shortly before the key, (b) the activated element was within the top-k candidates or within a radius of the gaze estimate, (c) the face was tracked with good confidence, and (d) the sample is not an outlier relative to recent residuals. Weight by confidence.
- Keep a rolling error estimate σ from these residuals. Feed σ to the snapping step (M6) and to the HUD.
- If σ stays high, offer a quick one-point re-centre, not a full calibration.
- Keep a small reserve of the original calibration samples so the model cannot drift far from its anchor.
- Persist the learned state.

**Acceptance:** a 30-minute session in `docs/EVAL.md` shows error not growing; deliberately shifting the laptop screen angle mid-session, error recovers after a bounded number of confirmations; synthetic tests show poisoned samples (wrong clicks) do not corrupt the model.

### M9 — Hardening and release
**Claude Code task:** "Work through the hardening checklist and prepare a signed, notarised build."

- Multiple displays and mixed scaling; Spaces and full-screen apps; display changes while running.
- Apps with poor accessibility trees: Screen Recording permission plus Vision text and rectangle detection as a fallback element source, merged with AX results.
- Performance and energy: lower frame rate when idle, pause when the screen is locked, profile with Instruments.
- Safety: hard failure modes never leave the keyboard swallowed; watchdog disables the event tap if the main loop stalls.
- Privacy statement; verify there is no network code (add a test that greps the target for network APIs).
- Settings UI for hotkeys, engagement model, outline style and sensitivity.
- Developer ID signing, hardened runtime, notarisation, a DMG.

**Acceptance:** `docs/MANUAL_CHECKS.md` fully ticked on my Mac; one full day of normal use without needing recalibration.

### M10 — Stretch (only after M9)
Scroll mode, drag and drop, text caret placement, per-app sensitivity profiles, an optional UI-element detector model for canvas apps, voice or dwell activation as alternatives to the activate key.

---

## 6. Quality bar and evaluation

Put these in `docs/EVAL.md` and fill in measured numbers as work proceeds.

| Metric | How measured | Target (goal, not a result) |
|---|---|---|
| Held-out gaze error, head still | validation dots | around 1.5° or better (the `shaal/eye-tracker` README calls ~1.5° the practical ceiling for a webcam without infrared) |
| Error under head movement | M7 protocol | within ~1.5× the still error |
| Top-1 and top-3 snap accuracy | tasks: look at a named target, press activate | measure first, then set target per UI density |
| Drift over 30 min | rolling σ | does not grow |
| Recalibrations per day | counter | 0 after the first calibration |
| Latency, gaze to outline | high-speed screen recording | under ~100 ms (target) |
| CPU and energy | Instruments | low enough to leave running |

Build a **replay harness** early: save sessions as feature streams (never video), with ground truth from calibration and validation targets, and run algorithm changes against them deterministically in `swift test`. This is what lets you improve the system without re-doing your own eye movements every time.

Be honest about the limit: with ~1.5° error, dense UIs (menu bars, toolbars with small icons) cannot be targeted by gaze alone. The design intentionally relies on gaze for rough position and the keyboard for the last step.

---

## 7. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Webcam accuracy too low | M0 measures before building; snapping and keyboard absorb error |
| Head movement degrades mapping | Head terms in the model, head-motion calibration phase, confidence widening, optional CoreML appearance model |
| Online learning drifts the wrong way | Strict sample filters, forgetting factor, anchor samples, tests with poisoned data |
| AX trees missing or slow in some apps | OCR and rectangle fallback, timeouts, caching, per-app overrides |
| Keyboard swallowed after a crash | Kill switch, watchdog, event tap auto-disable |
| Permissions lost on rebuild | Stable signing identity from M1 |
| Licence problems | Check before copying; only reference or port ideas from MIT repos |
| Poor lighting | Detect low confidence, show a warning, avoid learning from bad frames |

---

## 8. Privacy and safety rules (non-negotiable)
- No network code in the app.
- Camera frames are processed in memory and discarded. Optional recordings contain only numeric features, are off at launch, and are clearly indicated while running.
- Gaze never triggers an action by itself.
- The kill switch must work even when the app is misbehaving.

---

## 9. CLAUDE.md starter (copy into the repo root)

```markdown
# GazeKeys
macOS gaze + keyboard navigation app. Read PLAN.md first and work one milestone at a time.

## Rules
- Pure logic lives in Sources/GazeKit (no AppKit, no AVFoundation). Everything there needs unit tests.
- Camera, Accessibility, overlay and key interception sit behind protocols with mocks.
- Never copy code from another repo without checking its licence. Reference repos live in reference/ (git-ignored).
- Record non-obvious decisions as ADRs in docs/adr/.
- Gaze must never trigger an action. Only an explicit key press activates.
- No network code. No camera frames written to disk.
- After each milestone: run `make test`, tick docs/MANUAL_CHECKS.md items, commit.

## Commands
- make build   # generate project with XcodeGen, build
- make test    # swift test + xcodebuild test
```
