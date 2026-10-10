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

## M2 — Element map
Toggle the debug overlay with ⌃⌥B (or menu → Show Element Boxes). The black stats line at the bottom left shows the elements, nodes, scan time and change→boxes latency.
- [x] Finder: sidebar rows, toolbar buttons, file icons and window buttons are outlined and line up. (2026-10-11)
- [x] Safari (Wikipedia page): links, toolbar, address field and tabs line up; change→boxes 65 ms. (2026-10-11)
- [x] System Settings: sidebar rows, search field and content rows line up; rows partly under another app's window are trimmed. (2026-10-11)
- [x] Terminal: window and toolbar controls outlined. (2026-10-11)
- [x] Electron (Discord): server and DM sidebar, buttons and user panel outlined; change→boxes 55 ms. (2026-10-11)
- [x] Chromium (Helium browser): tabs, toolbar, address field and page links, including the docs navigation list; change→boxes 157 ms. (2026-10-11)
- [x] VS Code (Electron) and Google Chrome: not installed; accepted with Discord (Electron) and Helium (Chromium) as substitutes. (2026-10-11)
- [x] Menu bar menus and status items are outlined; elements behind other apps' windows are dropped. (2026-10-11)
- [x] Refresh latency after moving a window is under ~200 ms (Finder: 38–43 ms). (2026-10-11)
- [x] No UI freezes in the target app while boxes are on: user tried it and reported it working. (2026-10-11)
- [ ] Dock items are outlined (the dev Mac auto-hides the Dock: show it and check).
- [ ] Multiple displays: boxes line up on a second display, including one above or left of the primary.

## M3 — Keyboard-only navigation and actions
With Gazelle Active (⌃⌥G):
- [x] Finder: the outline starts at the focused element or the one nearest the pointer; ↑/↓ walk the list items; ←/→ stay in the row or beep; Return presses toolbar buttons. (2026-10-11)
- [x] Safari: Tab cycles toolbar → page; ↓ moves into page content (TOC button, Article link) after the page loads. (2026-10-11)
- [x] ⇧Return on Safari's reload button opens its context menu (via AXShowMenu). (2026-10-11)
- [x] Return on a text field (Safari address field) focuses it and leaves Active with a HUD message, so typing works. (2026-10-11)
- [x] ⌃⌥K while Active removes the keyboard tap and trips the kill switch. (2026-10-11)
- [x] Esc leaves Active; afterwards arrows, Tab and Return reach apps normally (tap removed). (2026-10-11)
- [ ] Outline is visible over a full-screen app and follows across Spaces.
- [ ] ⌥Return double-clicks (e.g. opens a file in Finder's list view) and ⌘Return focuses without clicking.
- [ ] Use the Mac keyboard-only for a few minutes: menu bar menus (↑ from the window into the menu bar, Return opens a menu, arrows inside it), Dock items, a System Settings pane.
