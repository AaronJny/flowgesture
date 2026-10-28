# Passive gesture diagnostics

`Sources/FlowGestureApp/GestureDiagnostics.swift` is an independently authored, **disabled-by-default, observation-only** diagnostic. It does not suppress native gestures or establish that Mission Control can be suppressed. The research and proposed hardware gate are in [gesture-arbitration-research.md](gesture-arbitration-research.md).

## Integration API

All methods and `onStatus` execute on the main thread:

```swift
let diagnostics = GestureDiagnostics()
diagnostics.onStatus = { status in /* display status */ }
diagnostics.start(maxDuration: 60) // positive finite duration; capped at 60 seconds
// At the engine's raw-frame delivery hook:
diagnostics.recordTouchFrame(deviceID: deviceID, contacts: activeCount, cancelled: cancelled)
// At the recognizer output hook; never use a user-supplied rule name:
diagnostics.recordRecognition("swipe.3.up")
diagnostics.stop()                // also call when the engine pauses/stops
let json = try diagnostics.snapshotData() // returns bytes; does not write/export
```

Accepted recognition names are `tap.1` through `tap.5`, `swipe.N.DIRECTION` for `N=1...5` and core direction names (`up`, `down`, `left`, `right`, `upLeft`, `upRight`, `downLeft`, `downRight`), and `pinch.inward` / `pinch.outward`. Arbitrary text, rule names, URLs, scripts, keyboard labels, or malformed recognition strings are rejected. Touch counts outside `0...64` are ignored.

A successful new explicit start replaces the previous in-memory trace. Repeated Start while already running does not restart the clock. A failed start preserves the prior trace. `snapshotData()` can be called before, during, or after a session; it does not activate capture. The caller must make any local file export an explicit user action (for example, a save panel). The diagnostic has no network or file-writing code.

## What is observed

The independent Quartz tap uses `.listenOnly` and a session tap. It starts from the public all-events mask and removes public keyboard events, modifier-flag changes, pointer movement, mouse buttons/drags, tablets, and null events. It does **not** maintain a guessed private gesture-type allowlist. It returns the original event on every callback path; no event fields are changed.

- Unknown/non-scroll event: only `receiptTime` and `rawType`. No sender lookup, `NSEvent` conversion, private-field lookup, flags, coordinates, deltas, key data, or gesture-name guess.
- Public scroll-wheel event: those two fields plus the public scroll and momentum phase values and an optional sender ID from the existing identity bridge. Sender absence stays unknown. No scrolling distances or pointer path are recorded.
- Touch hook: `receiptTime`, opaque session-local `touchDeviceID`, active `contactCount`, and `cancelled`. A touch-device ID is never relabeled as a Quartz sender ID.
- Recognition hook: `receiptTime` and the validated fixed-vocabulary recognition name.

Apple documents the [all-events mask](https://developer.apple.com/documentation/coregraphics/cgeventmask?language=objc) and that [listen-only callbacks cannot affect the stream](https://developer.apple.com/documentation/coregraphics/cgeventtapcallback?language=objc). Observing an undocumented raw type says only that this number reached this tap; it is not a supported semantic interpretation or proof that every system gesture is visible.

## Lifetime, privacy, and timing limits

- Requires a positive `CGPreflightListenEventAccess()` result. It does not call a permission-request function or alter privacy settings; permission errors are reported for user review. Accessibility is not silently treated as equivalent to Input Monitoring. [Apple preflight API](https://developer.apple.com/documentation/coregraphics/cgpreflightlisteneventaccess())
- Stops at the requested limit (maximum 60 seconds), on Stop/engine pause, sleep, session deactivation, permission-preflight loss, or tap-disabled notification. It never automatically re-enables an interrupted diagnostic tap.
- Every record path checks the deadline. If the main loop delays a timer, no later record is accepted after the deadline when handling resumes. This cannot guarantee a wall-clock teardown while the process/main thread itself is suspended.
- Uses a fixed ring of **512 records**, retaining the most recent records in chronological order. The JSON reports the number overwritten. At high event rates this may represent only the tail of the session, **not a complete 60-second history**.
- Times are monotonic seconds relative to session start, sampled at the observer or engine hook. Touch records arrive after the existing asynchronous main-queue touch delivery. These are **not hardware acquisition timestamps**; comparing them does not prove which system recognizer consumed an event first. Private MT clocks are not subtracted from CG event clocks.
- Records remain in process memory until replaced or the instance is destroyed; stopping preserves them for an explicit local export. There is no automatic disk persistence or upload.

## Verification

`Tests/FlowGestureAppTests/GestureDiagnosticsTests.swift` contains seven no-hardware checks: ring order/overflow, unknown-record payload minimization, identity namespace separation, duration bounds, public event-mask exclusions, recognition-name allowlisting, and an idle empty snapshot. They never call `start()`, create an event tap, request permissions, or modify system state.

At authoring time this executor has no Swift compiler or physical Mac. `git diff --check` passed; these new Swift tests require the parent-run macOS CI. A CI compile/test pass still does not establish private event visibility, real sender correlation, permission behavior on hardware, native gesture suppression, or physical timing.

Before any future active-consumption work, obtain a separate authorized physical-machine observation session and follow the [research acceptance gates](gesture-arbitration-research.md#5-physical-machine-validation-plan-and-acceptance-gates). No guessed private packet or event-consumption implementation is included here.
