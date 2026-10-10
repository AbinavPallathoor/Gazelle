# 0003 — Global hotkeys and the kill switch

Status: accepted (M1, 2026-10-11)

## Context
PLAN.md requires two things:
- a global hotkey that toggles Active;
- a separate kill switch that "always works" and disables all input interception. If the kill switch cannot be registered, the app must refuse to activate.

## Decision
- **Carbon `RegisterEventHotKey`** is used for both hotkeys (`Input/Hotkeys.swift`), not an event tap or `NSEvent` global monitors:
  - It needs no Accessibility or Input Monitoring permission, so the kill switch works before any permission is granted and even if those grants are revoked.
  - It reports registration failure (for example, when another app owns the combo). That is the signal behind "refuse to activate".
  - It is delivered regardless of which app is frontmost.
- **Defaults:** ⌃⌥G toggles Active, and ⌃⌥K is the kill switch. Both become configurable in the M9 settings. The kill switch was first ⌃⌥⌘K, but in M1 testing it registered fine yet did not fire for real key presses on the dev Mac, so it was moved to the same modifiers as the toggle.
- **Engagement rules** live in pure `GazeKit.ActivationState`, which is unit-tested:
  - Activation is refused while the kill switch is unregistered or tripped.
  - Killing forces Inactive.
  - A tripped kill switch stays tripped until re-armed from the menu, so a panicked double-press cannot re-activate.
- **Interception:** `AppController` enables the `InputInterceptor` only while `interceptionAllowed`, and disables it on kill and on quit. M1 ships a no-op interceptor; the M3 CGEventTap plugs in behind the same protocol.

## Consequences
- **Registration success does not prove ownership.** Tested in M1: a second process registered ⌃⌥K via `RegisterEventHotKey` and got `noErr`, and Gazelle, launched afterwards, also got `noErr`. Carbon only rejects duplicates within a process and system-reserved combos. "Refuse to activate if the kill switch cannot be registered" therefore catches those cases only. It does not catch another app claiming the same combo, and it is unclear which process receives the press. **M3 requirement:** the keyboard CGEventTap must recognise ⌃⌥K itself and disable interception directly. The tap sees key events before hotkey dispatch, so the kill switch then works however hotkey delivery resolves.
- **Secure Event Input.** Carbon hotkeys do not fire while another app has Secure Event Input on, for example while a password field is focused. Gazelle' own interception is also blind in that state, so nothing is swallowed. Still, M3 should check `IsSecureEventInputEnabled()` and show it in the HUD.
- **Main-thread hangs.** The hotkeys are handled on the main thread, so a hung main thread would delay the kill switch. Planned mitigations:
  - **M3:** the event tap callback itself recognises the kill combo and disables the tap without touching the main thread.
  - **M3:** the tap is always created with the system's auto-disable-on-timeout behaviour.
  - **M9:** a watchdog thread disables the tap if the main run loop stalls.
