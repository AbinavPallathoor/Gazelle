# 0004 — Element map: AX walking, refresh, occlusion, Electron/Chromium

Status: accepted (M2, 2026-10-11)

## Context
Gazelle needs an always-current list of clickable elements, each with an accurate on-screen box. The list must cover the frontmost app, the menu bar, menu extras and the Dock. It must refresh within about 200 ms of a change and never freeze the target app.

## Decision
- **The walk is pure and lives in GazeKit** (`TreeWalker`, `ElementClassifier`, `Occlusion`), written against an `ElementNode` protocol. The app's `AXNode` implements that protocol with `AXUIElement`, and the tests use in-memory trees.
- **One IPC call per node.** `AXUIElementCopyMultipleAttributeValues` fetches role, subrole, position, size, title, description, hidden and selected together. `AXActions` is only fetched for `AXImage` and `AXCell`.
- **Pruning.** The walk is breadth-first and capped at 48 levels and 6,000 nodes. Beyond that:
  - Windows, scroll areas, sheets and drawers narrow the clip rectangle, so off-screen subtrees are skipped.
  - Tables, outlines and lists use `AXVisibleRows` or `AXVisibleChildren`. **Chromium returns these as empty arrays on web elements, so an empty answer falls back to `AXChildren`.** Before this fix, web navigation lists were missed.
  - `AXStaticText`, `AXImage`, scroll bars and splitters are never descended into. Chromium nests inline text boxes under every text node: on one docs page, 1,165 of about 3,500 nodes were text.
  - Menus under closed menu bar items are not walked.
- **Refresh is event-driven.**
  - `AXObserver` on the frontmost app, for window, focus, value, layout, menu and destroy notifications.
  - Workspace activation, launch and termination, and display changes.
  - Global scroll-wheel and mouse-up monitors, because many apps post no AX notification on scroll.
  - A scan runs a fixed 30 ms after the first unserved change, so a burst of notifications cannot keep postponing it.
  - Scans run on a background queue.
  - Menu extras and the Dock (one round trip per running app, about 700 ms) refresh on their own queue: on app launch or quit, on display change, and every 10 s.
  - A just-launched app answers nothing at first, so near-empty scans and failed observer registration are retried after 0.25, 0.5, 1 and 2 s.
- **Timeouts.** A global messaging timeout of 150 ms (`AXUIElementSetMessagingTimeout` on the system-wide element) bounds how long a hung app can stall a scan.
- **Occlusion** uses the CGWindowList stack, whose bounds need no Screen Recording permission.
  - A window element is kept if the topmost window at most of five sample points belongs to its own process.
  - It is trimmed where another app's window covers one full side of it.
  - Gazelle's own windows are ignored.
  - Menu bar, menu-extra and Dock elements only need to be on a screen.
- **Electron and Chromium.** Gazelle sets `AXManualAccessibility = true` on each frontmost app once. It retries while the app answers `.cannotComplete`. This is Electron's documented switch for assistive tools; apps that don't support it return an error and are unaffected. `AXEnhancedUserInterface` is deliberately not used, because it is known to break window animations and positioning in some apps.

## Measurements (dev Mac, M2)
| App | Elements | Nodes | Scan | Change → boxes |
|---|---|---|---|---|
| Finder (home window) | 109 | 197 | 32–60 ms | 92–130 ms (before the debounce fix) |
| Finder (window moved ×6) | – | 12 | 6–11 ms | 38–43 ms |
| Safari, en.wikipedia.org/wiki/Gazelle | 66 | 199 | 33 ms | 65 ms |
| System Settings, General | 31 | 93 | 17 ms | 48 ms |
| Terminal | 11 | 18 | 4–6 ms | 35–38 ms |
| Discord (Electron) | 40 | 194 | 23 ms | 55 ms |
| Helium (Chromium), docs page | 52 | 1,899 | 126 ms | 157 ms |

All are under the ~200 ms target. The worst case is a large web page in a Chromium browser.

## Consequences and limits
- **Chrome and VS Code** aren't installed on the dev Mac. The Chromium engine was tested with Helium and Electron with Discord. Chrome and VS Code themselves remain manual checks.
- **`AXManualAccessibility` wasn't A/B tested.** We set it unconditionally and haven't compared Discord with and without it.
- **In-window overlays aren't occluders.** Popovers, toasts and in-app modals are drawn inside the same window, so elements under them stay in the map. For example, Discord's DM rows remain while a popover covers them. A later fix could prefer the AX subtree that is focused or modal.
- **Same-app occlusion isn't handled.** An element covered by another window of the *same* app is kept, because occlusion compares processes, not window IDs.
- **Background windows are out of scope.** Only the frontmost app's windows are walked. Elements in visible windows of other apps are not mapped, per PLAN.md M2 scope.
- **Multiple displays:** the coordinate conversion is unit-tested for displays above and beside the primary, but it hasn't been checked on real multi-display hardware.
