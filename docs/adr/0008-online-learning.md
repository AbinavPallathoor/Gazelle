# 0008 — Online learning from confirmed selections

Status: accepted in code and tests (M8, 2026-10-11). The live 30-minute session is pending.

## Context
PLAN.md asks for one short calibration and then no recalibration. The system has to correct itself from normal use, without being poisoned by wrong clicks.

## Decision (`GazeKit.OnlineCalibrator`, wired in `GazePipeline`)
- **The sample:** every successful activation (Return, ⇧Return, ⌥Return or ⌘Return via Gazelle). The features are the mean of the fixation in the 0.6 s before the key (until 50 ms before it). The label is the activated element's centre.
- **Safeguards** (all must pass):
  1. A stable fixation: at least 6 fixating frames in the window.
  2. The face tracked and the camera not stalled for the *whole* window.
  3. The target has a clear centre: at most 220 pt on each side. Rows, text areas and web views never teach the model.
  4. The target is plausible: within 3σ of the gaze estimate, or among the top 3 gaze candidates at that moment.
  5. Not an outlier: the residual is at most 3× the median residual of recent *plausible* samples, rejected ones included. A one-off wrong click stands out; a real, sustained drift raises the reference after about 5 clicks, so learning can follow it. (A first version used only *accepted* residuals; a synthetic screen-tilt test then rejected every sample and never recovered.)
  - Samples are weighted by fixation confidence: frames ÷ 10, capped at 1.
- **Update:** an exact refit, not incremental RLS. The model is refitted on:
  - the original calibration samples, as a permanent **anchor**, at weight 0.25 per frame;
  - accepted click samples at weight 20 × confidence × 0.97^age (a forgetting factor), keeping the newest 200.
  The λ ratios stay those chosen at calibration (`GroupedRidge` with `fixedRatios`), so a refit is one weighted ridge solve: milliseconds, run on a background queue. This minimises the same exponentially weighted objective that RLS with forgetting approximates, and the anchor is explicit.
  With about 1,500 anchor frames at 0.25, roughly 20 recent clicks weigh as much as the whole calibration. A synthetic tilt went from 136 pt to below 1.5× the baseline error within 25 clicks, while 30 % subtly wrong clicks moved the error by less than 25 pt.
- **σ:** the RMS of the last 20 accepted residuals, at least 30 pt. Before 5 samples exist, it is the calibration's validation error. It feeds snapping (ADR 0007) and the HUD.
- **Re-centre:** if σ stays above 1.8× the calibration σ for 8 accepted samples, the HUD suggests **⌃⌥R**. That shows a dot at the screen centre, collects about 1.5 s of predictions, and adds the mean error as an offset. Labels are stored without the offset, so later refits absorb the correction.
- **Persistence:** the learned state (samples, residuals, offset, counts) and the current model are saved into the profile 3 s after an update and when the camera stops. They are restored at launch.

## Also in this change: filter tuning
`gazespike tune <profile>` replays a profile's held-out validation fixations through a grid of One Euro settings.
- On the dev Mac: raw within-fixation jitter was 30.5 pt; the best setting with lag ≤ 250 ms is 0.2–0.3 Hz / β 0.0005–0.001, giving ≈ 25–26 pt at ≈ 90–120 ms. The old setting (0.8 / 0.004) was ≈ 28 pt.
- Most of the residual is slow wander within a fixation, which no causal filter removes without lag. The shipped setting is 0.3 / 0.001.

## Consequences
- **Keyboard-only picks still teach the model.** Activations of elements the keyboard chose, far from gaze, are rejected by safeguard 4, so arrow-key corrections do not teach the model wrong labels. An arrow move to an adjacent element (rank 1–2) does teach it: that is the "gaze picked the neighbour, user corrected" case and is the most valuable label.
- **Profile size grows.** Each online sample carries the 486-value eye-region vector, about 9 KB of JSON; at most 200 are kept.
