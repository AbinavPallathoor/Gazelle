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

## M1 — Scaffold, permissions, kill switch
- [x] `make build` produces an app signed with Apple Development, hardened runtime, and a designated requirement without a cdhash (`codesign -d -r-`). (2026-10-11)
- [x] `make test` passes: SwiftPM tests plus the Xcode app tests (mocks for hotkeys, interceptor, permissions). (2026-10-11)
- [x] `make run`: an eye icon appears in the menu bar and there is no Dock icon. (2026-10-11)
- [x] On first launch the permissions window lists Camera, Accessibility, Input Monitoring and Screen Recording (optional), each with the correct status. (2026-10-11)
- [x] Each "Allow…" / "Open Settings…" button opens the matching system prompt or System Settings pane, and the status turns green within about 1 s of granting. (2026-10-11)
- [x] Survives a rebuild: grant Camera and Accessibility, then `touch Sources/GazelleApp/App/AppDelegate.swift && make run`. Both still show Granted. (2026-10-11)
- [x] From another app (e.g. Safari focused), ⌃⌥G toggles Active: the icon changes between eye and filled eye, and a "Gazelle Active/Inactive" message shows briefly. (2026-10-11)
- [x] From another app, ⌃⌥K trips the kill switch: the icon shows a slashed eye, ⌃⌥G beeps and stays inactive, and the menu's "Re-arm Kill Switch" restores it. (2026-10-11)
- [x] Another process holding ⌃⌥K: tested 2026-10-11. Both registrations succeed (Carbon allows cross-process duplicates), so Gazelle cannot detect the conflict. The refusal path is covered by `testRefusesToActivateWhenKillSwitchCannotRegister`. The event-tap fallback is an M3 requirement (ADR 0003).
