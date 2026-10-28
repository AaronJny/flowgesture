# Development guide

## Requirements and build

macOS 13+, Xcode command-line tools, and Swift 5.9+:

```sh
swift test
bash scripts/test-native-bridge.sh
bash scripts/build-app.sh
bash scripts/smoke-test-app.sh
```

The build script creates a universal arm64/x86_64 application at
`build/FlowGesture.app` and a disk image at `build/FlowGesture-macos.dmg`.
It validates the plist and applies/verifies an ad-hoc signature. It does not
notarize the app or configure a Developer ID identity.

## Architecture

- `FlowGestureCore`: Codable rule models, schema migration, validation, matching,
  deterministic recognition, click resolution, scrolling and bounded file reads.
- `FlowGestureNative`: optional dynamically loaded system touch interfaces and
  HID sender classification. Unknown device identity remains explicit.
- `FlowGestureApp`: SwiftUI settings, event handling, lifecycle, queued action
  execution and local configuration/sync.

No third-party runtime code or binary is bundled. GitHub Actions dependencies
are pinned to verified official commit SHAs. Distribution licensing is a
separate owner decision before public release.

## Verification boundaries

Core tests and native decoder tests do not exercise physical devices. The launch
smoke test checks that the settings window appears in WindowServer, then closes
and reopens the same window, without granting input permissions. Real-device
acceptance must separately cover permissions, native system-gesture interactions,
hotplug/wake, input pass-through, and per-device identity.

See the [acceptance matrix](../ACCEPTANCE.md) and
[touch/device implementation notes](../touch-device-validation.md).

## Data and execution

Configuration is stored in `~/Library/Application Support/FlowGesture/rules.json`.
Schema 1 is migrated to schema 2 on decoding; future schemas are rejected by
validation. Imported/synchronized rules are paused, and enabling them requires
review confirmation. Files are read with size bounds and same-descriptor regular
file checks. Backups and conflict handling preserve existing data.

Pause/configuration changes invalidate queued action batches between steps.
An already running NSAppleScript is not forcibly interrupted. Synthetic input
is tagged to avoid feedback. The application's own frontmost UI is excluded
from input rules so settings remain usable.

## CI storage

Only the app DMG is uploaded, retained for seven days.
The uploaded image is downloaded again, byte-compared, verified, mounted read-only,
then its copied app is signature/architecture-checked and launched.
Concurrency cancels superseded runs on the same ref. Historical run/artifact
deletion is not automatic; useful diagnostic logs and the current build are retained.
