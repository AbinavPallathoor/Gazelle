# 0005 — Keyboard navigation, selection and actions

Status: accepted (M3, 2026-10-11)

## Context
M3 makes Gazelle usable without a pointer. Arrow keys move a selection between elements, and keys act on that selection. Key interception must be safe: only the listed keys may be swallowed, and only while Active.

## Decision
- **Bindings** (pure `GazeKit.KeyMap`, unit-tested; only these keys are swallowed, and only while Active):

  | Key | Command |
  |---|---|
  | ← → ↑ ↓ | move to the nearest element in that direction |
  | Tab / ⇧Tab | next / previous in reading order (wraps) |
  | Return or keypad Enter | press |
  | ⇧Return | right-click |
  | ⌥Return | double-click |
  | ⌘Return | focus only |
  | Esc | leave Active |

  Arrows with ⌘, ⌃ or ⌥ and every other key pass through. Holding an arrow or Tab repeats the move; holding Return does not click repeatedly. The release of a swallowed key is also swallowed.

- **Directional move** (`SpatialNavigator`):
  - A candidate must lie further in the pressed direction: its centre, near edge and far edge are all beyond the current element's.
  - Containers of the current element are never candidates.
  - **Elements sharing the current row (for ←/→) or column (for ↑/↓) win first.** Otherwise a fallback candidate must lie within a ~37° cone and no further to the side than twice the current element's size (minimum 40 pt). This stops jumps across the window. For example, "right" from a Finder list item used to land on a toolbar button 300 pt above it.
  - Scores are the gap along the direction plus 3× the sideways gap, with small tie-breakers.
  - If nothing qualifies, the selection stays put and Gazelle beeps; Tab still reaches every element.
- **Reading order:** lines from top to bottom, then left to right within a line. Two elements share a line when they overlap vertically by at least half the smaller height.
- **Selection** (`SelectionModel`):
  - It starts on the keyboard-focused element (matched by AX hash, then by nearest frame), else the element nearest the pointer, else the first in reading order.
  - Across refreshes it follows the same element by ID. If that element disappears, it moves to the element nearest its old position.
- **Element model fixes found in live testing:**
  - Text fields inside rows, cells and list items are labels (for example, Finder file names), so they are not targets.
  - `AXGroup`s directly inside a native `AXList` (Finder's column view) are list items. Web lists (`AXContentList`) are excluded, because their links are the targets.
  - Web views trigger a rescan on `AXLoadComplete` and `AXElementBusyChanged`. Before this, pages that finished loading after the first scan had no content in the map.
- **Actions** (`ActionPlanner` is pure and unit-tested; `ActionPerformer` carries them out):
  - The performer tries each planned step in order until one succeeds.
  - Press uses `AXPress`, `AXOpen`, `AXPick` or `AXConfirm`, falling back to a click at the box centre. On a text field it sets `AXFocused`, falling back to a click.
  - Right-click uses `AXShowMenu`, falling back to a right-click. Double-click is always a synthesised click with click state 2.
  - Focus-only sets `AXFocused`, falling back to moving the pointer.
  - Synthesised clicks put the pointer back afterwards.
  - Pressing a text field leaves Active, because typing needs the keys Gazelle would otherwise swallow. The HUD says why.
- **Event tap** (`KeyboardTap`, the `InputInterceptor` from M1):
  - It runs at the session level on its own thread and run loop. It exists only while `interceptionAllowed` is true, and is removed entirely otherwise.
  - It recognises ⌃⌥K itself: it disables itself first, then trips the kill switch on the main thread. This closes the gap found in M1, where Carbon accepts duplicate hotkey registrations.
  - If macOS disables the tap (timeout or user input), it is re-enabled only while still wanted.
- **Outline:** a ring with two strokes (dark outer, yellow inner, with a glow), animated over 120 ms between elements on the same display. It is drawn in non-activating, click-through panels on all Spaces, including over full-screen apps, one level above the debug boxes.

## Consequences
- The element store now runs while Active as well as while the debug boxes are visible. `@Published` emits *before* the property changes, so subscribers must use the emitted value instead of re-reading the property (this was a bug in M3).
- `ActionPlanner` stops at the first successful step, so a text field that accepts `AXFocused` is not also clicked. That is enough for Safari's address field. Fields that need a real click to place the caret will be handled when a case shows up.
- In-window popovers are still not occluders (ADR 0004). Navigation can reach elements hidden under them.
