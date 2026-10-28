# FlowGesture

[English](README.md) | [简体中文](README.zh-CN.md)

A native macOS menu-bar app for mouse gestures, scrolling, touch gestures and everyday automation.

**Development preview:** the app builds and launches, but real-device acceptance testing is still in progress. This is an independent implementation, not a modified BAB binary. It has no account requirement, subscription, mandatory updater or telemetry.

## Features

- Draw gestures with mouse buttons, with a visible trail and replay of unmatched clicks.
- Map side buttons and keyboard shortcuts; trigger actions from screen corners.
- Reverse mouse scrolling independently, adjust speed and smooth discrete wheel input. Device identity keeps trackpads unchanged by default; unidentified sources are left untouched.
- Recognize multi-finger taps, swipes and pinches from supported touch devices, including trackpads and touch mice.
- Choose global or per-app rules, modifier keys, priorities and excluded apps.
- Run shortcuts and AppleScript, open URLs/files/apps, select menu items, arrange windows and perform media/system actions.
- Edit rules in English or Chinese; import/export JSON, restore backups and synchronize through a folder you choose.

Touch-device compatibility and interference with macOS's own gestures still need hardware verification. Not every BAB gesture/action is implemented yet; see the [acceptance matrix](docs/ACCEPTANCE.md) for the remaining scope.

## Install and use

Requires **macOS 13 or later**. Development builds contain both Apple Silicon and Intel executables.

1. Open a successful [GitHub Actions run](https://github.com/AaronJny/flowgesture/actions), download the `FlowGesture-macos` artifact, and extract its ZIP files.
2. Move `FlowGesture.app` to Applications and open it. Development builds are ad-hoc signed, not notarized; macOS may ask you to confirm opening the app in Privacy & Security.
3. Open **FlowGesture Settings** from the menu bar. Grant **Accessibility** and **Input Monitoring** in System Settings → Privacy & Security, then refresh permissions or reopen the app.
4. Click **Add examples** or **Add rule**, choose a trigger and its actions, and enable FlowGesture. The touch example is initially disabled so you can choose how it interacts with your system gestures.

AppleScript controlling another app can separately request Automation permission. Pause monitoring from the menu bar whenever needed. There is no forced update mechanism.

## Configuration and sync

Rules live in `~/Library/Application Support/FlowGesture/rules.json`. Import and export use JSON; a previous configuration is backed up before replacement. Imported or incoming synchronized rules are paused for review before execution.

For synchronization, select an iCloud Drive or another synchronized folder in Settings. FlowGesture checks that folder while it is running, detects conflicting edits, and lets you choose which version to keep. It does not run after you quit, create a cloud account, or silently overwrite a conflict.

## Build from source

Install Xcode command-line tools and Swift 5.9 or later on macOS:

```sh
swift test
bash scripts/test-native-bridge.sh
bash scripts/build-app.sh
open build/FlowGesture.app
```

The build script creates a universal app and `build/FlowGesture-macos.zip`.

## Project structure

- `FlowGestureCore`: rule models, validation, matching and deterministic gesture recognition.
- `FlowGestureNative`: optional system touch capture and device identity, with explicit unavailable states.
- `FlowGestureApp`: SwiftUI settings, event handling, lifecycle and queued actions.

No third-party implementation or binary is bundled. A distribution license will be selected before the project is made public. Implementation and hardware-validation details are in [touch/device notes](docs/touch-device-validation.md).
