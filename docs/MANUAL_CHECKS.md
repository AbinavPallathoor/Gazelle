# Manual checks

Checks that need real hardware or macOS permissions and cannot run in `swift test`.
Tick each one on the development Mac at the end of its milestone.

## M0 — Vision backend spike
- [x] `make m0-record` uses the camera (access attributed to the terminal app) and records all four runs. (2026-10-11)
- [x] The fixation window shows the dot, the instruction, the countdown and live fps. (2026-10-11)
- [ ] Esc during a run aborts and deletes the partial recording.
- [x] The chosen backend (MediaPipe) sustains 30 fps with a face in view: 1808–1823 frames per 60 s run. (2026-10-11)
- [ ] Covering the camera gives face-lost frames (`face %` drops), not a crash.
- [x] The MediaPipe web view cannot reach the network: a temporary `fetch('https://example.com')` was blocked ("Load failed"). (2026-10-11)
- [x] `recordings/` and `Tests/Fixtures/` contain only numeric `.jsonl`; no images or video in the repo. (2026-10-11)
