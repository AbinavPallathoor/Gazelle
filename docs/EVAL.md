# Evaluation

Targets are goals to measure against, not results already achieved (PLAN.md §6).

| Metric | How measured | Target | Measured |
|---|---|---|---|
| Held-out gaze error, head still | validation dots (M5) | ≈ 1.5° or better | – |
| Error under head movement | M7 protocol | within ≈ 1.5× the still error | – |
| Top-1 and top-3 snap accuracy | look at a named target, press activate (M6) | set after first measurement | – |
| Drift over 30 min | rolling σ (M8) | does not grow | – |
| Recalibrations per day | counter (M8) | 0 after the first calibration | – |
| Latency, gaze to outline | high-speed screen recording | < ≈ 100 ms | – |
| CPU and energy | Instruments | low enough to leave running | – |

## M0 — Vision backend comparison

Protocol: `make m0-record` then `make m0-analyze`. Each backend gets 60 s looking at a centred dot with
the head still, then 60 s looking at the dot while moving the head. Both use 1280×720 at 30 fps from the
built-in camera. See `docs/adr/0001-vision-backend.md` for how to read the columns.

Measured 2026-10-11, Apple M4 MacBook Air, built-in camera, indoor light. Decision: MediaPipe (ADR 0001).

| backend | label | fps | latency p50/p95 ms | CPU % | face % | iris frame jitter (ew) | iris residual after head regression (ew) | yaw/pitch/roll std ° |
|---|---|---|---|---|---|---|---|---|
| vision | still | 30.0 | 19.1 / 24.0 | 41 | 100.0 | 0.0094 | 0.0152 | 0.5 / 1.1 / 0.6 |
| vision | moving | 30.0 | 19.8 / 24.5 | 42 | 99.9 | 0.0237 | 0.0440 | 8.4 / 4.7 / 7.3 |
| mediapipe (GPU) | still | 30.0 | 13.0 / 15.0 | 48 | 100.0 | 0.0016 | 0.0066 | 0.2 / 0.9 / 0.3 |
| mediapipe (GPU) | moving | 30.0 | 14.0 / 15.0 | 48 | 100.0 | 0.0064 | 0.0215 | 7.0 / 5.1 / 6.3 |

0.01 eye widths (ew) is roughly 1.4° of eye rotation. Recordings: `Tests/Fixtures/m0/`.
