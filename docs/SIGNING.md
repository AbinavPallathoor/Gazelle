# Signing

macOS ties Camera, Accessibility, Input Monitoring and Screen Recording grants to the app's
*designated requirement*. An ad-hoc signature changes with every build, so the system forgets those
grants after each rebuild. Every dev build is therefore signed with the same Apple Development
certificate.

## One-time setup
1. Xcode → Settings → Accounts → add your Apple ID (a free account works).
2. Select the account → Manage Certificates → **+** → Apple Development.
3. `make signing`. This writes `Config/Local.xcconfig` (git-ignored) with the identity's SHA-1 and team ID.
4. `make build`, then check:
   ```
   codesign -d -r- .build/xcode/Build/Products/Debug/Gazelle.app
   # designated => identifier "dev.gazelle.Gazelle" and anchor apple generic and
   #               certificate leaf[subject.CN] = "Apple Development: …" …
   ```
   The requirement names only the bundle ID and the certificate, not a code hash, so grants survive rebuilds.

Without `Config/Local.xcconfig` the build falls back to ad-hoc signing (`Config/Base.xcconfig`). It still builds and tests, but permissions reset on every build.

## Troubleshooting
- **`security find-identity -v -p codesigning` shows "0 valid identities" even though the certificate exists.**
  The Apple WWDR **G3** intermediate is missing. Older Macs only have the G1 intermediate, which expired in 2023.
  Install it from https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer:
  `security import AppleWWDRCAG3.cer -k ~/Library/Keychains/login.keychain-db`
  (This was needed on the dev Mac on 2026-10-11.)
- **Xcode isn't selected.** The Makefile exports `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, so `xcode-select` can stay on the Command Line Tools.

## Build settings
- Hardened runtime is on (`flags=0x10000(runtime)`).
- The app is not sandboxed, because Accessibility control needs that.
- Entitlements: `com.apple.security.device.camera`. Debug builds also get `get-task-allow`, which Xcode adds automatically.
- Release builds will move to a Developer ID Application certificate plus notarisation in M9.
