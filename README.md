# FlowGesture · 行云手势

Native macOS input customization. 原生 macOS 鼠标、触控板与快捷操作工具。

A new independent implementation, not a modified BAB binary. No account, subscription,
mandatory updater, telemetry or remote rule execution. Private development build;
feature parity and real-device validation are work in progress.

## Build / 构建

Requires macOS 13+, Xcode command-line tools / Swift 5.9+.

```sh
swift test
bash scripts/build-app.sh
open build/FlowGesture.app
```

Grant **Accessibility** and **Input Monitoring** in System Settings → Privacy & Security.
Then reopen the app or press Resume. AppleScript controlling other apps may separately
request Automation permission. Local bundles are ad-hoc signed, not notarized.

The menu-bar app opens bilingual settings. Add a rule, select its trigger and actions,
optionally scope it to application bundle identifiers, then enable monitoring. Rules are
stored at `~/Library/Application Support/FlowGesture/rules.json`. Import/export uses JSON;
folder sync supports a user-selected iCloud Drive or other synced folder, detects conflicts,
and does not require an account or change cloud entitlements.

## Implemented paths / 已实现链路

- Mouse-button mappings and directional right-button drawings with unmatched-click replay.
- Mouse scroll inversion, speed and smoothing; trackpad input must be left untouched by default.
- Keyboard shortcut and screen-corner triggers; per-app/global rules, modifiers and exclusions.
- Touch contact capture + tap/swipe/pinch recognizers, with per-device session state.
- Shortcuts, AppleScript, URL/file/app opening, accessibility menus and window layouts,
  media/system actions and action sequences.
- Editable rules, bilingual UI, atomic persistence, backup, import/export and folder sync.

See [acceptance matrix](docs/ACCEPTANCE.md) for the difference between implemented,
CI-checked and hardware-verified. Touch capture uses optional dynamically resolved system
interfaces; availability, gesture arbitration and device identity require real-Mac testing.
Missing capability is reported rather than represented as a working feature.

## Architecture / 架构

`FlowGestureCore` contains pure value models, validation, matching and deterministic
recognizers. `FlowGestureNative` owns the system contact ABI boundary and device identity.
`FlowGestureApp` owns SwiftUI settings, a short-running event tap, queued action execution,
and lifecycle. Synthetic events are tagged to prevent feedback loops. No third-party code
or binary is bundled. Original source; license will be selected before public release.
