# 0007 — Gaze drives the selection

Status: accepted (M6, 2026-10-11). User verdict on hardware: "works decently well, not precise yet."

## Decision
- **Scoring** (`SnapScorer`):
  - The likelihood of each element is `exp(−½ (d/σ)²)`, where d is the distance from the gaze point to the box (0 inside), so a large σ spreads probability across neighbours instead of making a hard wrong choice.
  - Only elements within 3σ are considered.
  - Priors: ×1.5 for elements in the app whose window is under the gaze point; ×1.2 for elements activated recently; a gentle preference for smaller boxes among overlapping ones (a button over its row).
- **σ** is the calibration's mean validation error, at least 40 pt. M8 replaces it with a rolling estimate.
- **Hysteresis** (`GazeSelector`): only samples during a fixation can change the selection. A challenger must beat the current element's probability by 1.6× for 150 ms. The runner-up is kept whenever it reaches at least half the best probability.
- **Engagement** (`EngagementState`, PLAN.md §1):
  - The selection starts gaze-driven; any navigation key locks it to the keyboard.
  - Gaze takes over again after a fixation at least max(3σ, 150 pt) from the locked element held for 300 ms, or after 2 s without a key.
  - An arrow pressed right after a gaze pick goes to the runner-up if it lies in that direction; otherwise normal spatial navigation applies.
  - A lost face freezes the selection.
  - **Gaze never activates anything.**
- **When the camera runs:** while Active and calibrated, as well as while the HUD, the gaze dot or a calibration is open.

## Consequences
- With ~1.5–2° error (~80–100 pt at laptop distance), gaze picks the right *area*, and arrows finish the job. That is the design PLAN.md §6 calls for.
- Gaze-driven selection is only as good as the calibration. The HUD and the gaze dot (⌃⌥D) make that visible.
