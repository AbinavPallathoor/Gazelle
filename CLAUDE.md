# Gazelle
macOS gaze + keyboard navigation app. Read PLAN.md first and work one milestone at a time.
PLAN.md calls the app "GazeKeys"; its name is **Gazelle** (bundle ID `dev.gazelle.Gazelle`).

## Rules
- Pure logic lives in Sources/GazeKit (no AppKit, no AVFoundation; Foundation and Accelerate only). Everything there needs unit tests.
- Before inventing an approach, check the reference repos in reference/ (shaal/eye-tracker ADRs, EyeTrax) and build on what they learned.
- Camera, Accessibility, overlay and key interception sit behind protocols with mocks.
- Never copy code from another repo without checking its licence. Reference repos live in reference/ (git-ignored).
- Record non-obvious decisions as ADRs in docs/adr/.
- Gaze must never trigger an action. Only an explicit key press activates.
- No network code. No camera frames written to disk.
- After each milestone: run `make test`, tick docs/MANUAL_CHECKS.md items, commit.

## Commands
- make build   # generate project with XcodeGen, build (Xcode via DEVELOPER_DIR, no xcode-select needed)
- make test    # swift test + xcodebuild test
- make run     # build and (re)launch the menu-bar app
- make signing # write Config/Local.xcconfig with the Apple Development identity (docs/SIGNING.md)
