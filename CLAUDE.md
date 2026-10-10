# GazeKeys
macOS gaze + keyboard navigation app. Read PLAN.md first and work one milestone at a time.

## Rules
- Pure logic lives in Sources/GazeKit (no AppKit, no AVFoundation). Everything there needs unit tests.
- Camera, Accessibility, overlay and key interception sit behind protocols with mocks.
- Never copy code from another repo without checking its licence. Reference repos live in reference/ (git-ignored).
- Record non-obvious decisions as ADRs in docs/adr/.
- Gaze must never trigger an action. Only an explicit key press activates.
- No network code. No camera frames written to disk.
- After each milestone: run `make test`, tick docs/MANUAL_CHECKS.md items, commit.

## Commands
- make build   # generate project with XcodeGen, build
- make test    # swift test + xcodebuild test
