# Daily-use compatibility review

Reviewed baseline: `cc654e6` on `main`, following the v0.1.3 release.
This is a source review and an isolated test-branch implementation, not a new release or physical-device certification.

## Main functions and gaps

| Area | Implemented | Remaining compatibility boundary |
|---|---|---|
| Mouse mappings | Buttons 1–8, single/double/triple click, directional and free-form drawing | Physical button order, click/drag replay, and device-driver combinations need real-device checks. |
| Scrolling | Smoothing, speed, independent axis reversal, mouse/trackpad classification | Unknown/virtual/composite device identities need conservative behavior and physical verification. |
| Touch | Per-device raw frames, 1–5-finger taps/swipes, two-finger pinch, device-scoped rules | Private ABI and actual device classification remain unverified on hardware. Rotate, pressure, region and edge families are not implemented. |
| Native gesture interaction | Passive diagnostics and user-facing potential-overlap guidance | No suppression of Mission Control, App Exposé, Spaces, browser navigation, scrolling or pinch is established. Observing touch does not reserve a gesture. |
| Application scope | Global and app-specific rules, exclusions, priority and saved-order matching | Interruption and asynchronous input delivery need separate tests; a shortcut's effect also depends on the target application's shortcuts. |
| Actions | Shortcut, script, URL/app/file, menu, window and media/system actions | AX/Automation permissions, missing menus, sandbox/secure-input behavior and application-specific window support need a real macOS session. |
| Device lifecycle | Device enumeration, separate identities, wake refresh, topology polling, bounded callback queue, isolated failed-device retries | Capture restart with fingers down, Bluetooth reconnect and simultaneous devices require physical testing. |
| Configuration | Validation, import/export, backups, folder sync, bilingual settings | Corrupt/imported configs are guarded; simultaneous sync edits and actual UI interactions still need macOS acceptance. |
| Distribution | macOS 13+, arm64/x86_64 packaging and macOS CI | See the dated CI results below for tested OS/architecture combinations; hardware certification remains separate. |

## Changes in this patch

### Prevent a lost first gesture after app/configuration changes

Previously, `EventEngine` retained a recognizer after all fingers lifted, then
blocked **every remembered device** on app activation or configuration changes.
If a device did not send further empty frames while idle, the next complete
gesture was consumed merely to clear that block.

`TouchGestureSessions` now tracks active contacts separately from remembered
recognizers. Only active sessions are blocked until release. Idle devices can
recognize their next gesture immediately. State remains independent per device,
and a fired swipe remains active until its contacts lift. Cancellation frames
with no contacts do not count as a genuine release.

Eleven deterministic regression tests cover idle transitions, active interruption,
two devices, repeated cancellation, already-fired gestures, repeated interruptions
and capture-generation reset. Invalid (backward or non-finite) all-up timestamps
cannot clear interruption protection; device timestamps survive app/configuration
changes and restart only with a new capture generation.

### Make native overlaps understandable before saving a rule

The touch editor now describes likely overlaps for the selected gesture and
device: taps, scrolling, page navigation, Spaces, Mission Control, App Exposé or
pinch zoom. Trackpad and Magic Mouse use separate settings guidance; an “Any”
scope can show both. Seven tests cover these mappings, including diagonals and
modifier requirements.

These are **potential overlaps**, not detected preferences. The editor explicitly
states that assignments have not been checked and that modifiers/app scopes do
not suppress macOS behavior. Users can choose another gesture, manually change a
system assignment or accept coexistence. This guidance does not read/write system preferences or seize devices. The separate
experimental decoder uses source-verified private fields, but remains disconnected
from production event interception.

## Follow-up implementation

- **Partial device-start recovery:** failed records retry with 3–60 second
  exponential backoff without stopping healthy devices. Each retry gets a new
  session identity, callbacks before successful start are rejected, and obsolete
  queued identities cannot execute. Fake-runtime C tests exercise the production
  lifecycle, mixed failures, recovery and healthy-device preservation.
- **Finger-count commitment:** motion waits for the inclusive 80 ms joining
  interval to close. Early movement is retained, joining invalidates the smaller
  cohort's candidate, and a short flick can finish on all-up. Thirteen new tests
  cover joins, short swipes/pinches, reversal, staggered lift and cancellation.
  This deliberately adds up to the remaining join-window delay for early motion.
- **Queued frame/application boundary:** the callback lock now protects an
  acquisition-time contact snapshot and atomic queue invalidation. App/config
  transitions drop old queued frames, interrupt any in-flight delivery generation
  and wait for genuine release only on still-active devices. Already acquired
  but undelivered all-up does not sacrifice the next gesture. Pending main-queue
  action dispatch also checks foreground generation. Already executing actions
  are not forcibly interrupted.
- **Native horizontal interception foundation:** an exact-field Quartz decoder
  and independently authored ownership state machine now have source-pinned
  tests. They are deliberately not connected to an active production tap.
  No complete-stream capability profile is validated. See
  [the implementation contract and remaining activation gates](native-horizontal-arbitration.md).

### Keep editor actions reachable on small displays

The macOS 15 CI runner exposed a genuine layout failure after the test's old fixed
click coordinates were replaced with native control geometry. A 690-point minimum
editor content height produced a 718-point window on a 768-point screen. The Save
control was positioned outside the usable screen area, and its click lost app
focus instead of saving.

The editor now permits a 600-point minimum height, keeps the footer fixed while
the form scrolls, and constrains the settings window to the screen's visible
frame. Shortcut UI checks require both the window and target point to fit that
usable area. They still click actual Record and Save controls, require native
capture ownership to end after key-up, and verify all three persisted shortcuts.
No synthetic reactivation or skipped assertion masks a failed Save.

## Remaining acceptance priorities

1. **Retain the full macOS CI gate.** The isolated branch
   `dot/touch-compatibility-20261108` was pushed with explicit approval. The old
   macOS 14 runner was retired, so the initial repaired CI used `macos-15`. Actual native control
   geometry replaced brittle fixed-coordinate clicks; that revealed and led to
   fixing the small-screen Save defect above. That complete macOS 15 suite passed on November 8; the November 9 section below records expanded matrix results.
   No interactive personal Mac is used for this work.
2. **Verify production fixes physically.** Exercise app/config changes during
   callback backlog, short/fast gestures, mixed devices, and real start failures.
3. **Complete native-gesture arbitration.** Follow the existing
   [research and acceptance gates](gesture-arbitration-research.md). Investigate
   horizontal Spaces separately from vertical gestures and pinch. Do not ship
   guessed suppression or treat passive traces as proof of successful blocking.
   Horizontal source evidence does not establish vertical Mission Control,
   App Exposé or pinch suppression. The active adapter still needs verified
   companion/terminal handling and raw-action de-duplication on a real Mac.

## Validation performed here

- `git diff --check`: passed.
- `bash scripts/test-native-bridge.sh`: passed on Linux; this covers the decoder,
  non-macOS unavailable/unknown stubs and the production lifecycle with a fake
  runtime. It does not exercise Apple's framework or physical devices.
- ASan/UBSan native run: passed with `ASAN_OPTIONS=detect_leaks=0 SANITIZE=1`.
  The initial leak-enabled run failed because LeakSanitizer does not support the
  environment's ptrace setup. Leak checking is therefore **not** validated.
- Full macOS 15.8.2 / Swift 6.1.2 CI at
  `3cee9b4942481b9c0fdde1d216d49490c938f5b2`: **SUCCESS, all steps passed**.
  [Run evidence](https://github.com/AaronJny/flowgesture/actions/runs/42489465736).
  This includes native tests, **185 Swift tests with zero failures**, universal
  arm64/x86_64 app build, launch/reopen, foreground mappings and pause, full-screen
  gesture, native shortcut capture, actual three-shortcut Record/Save persistence,
  click/draw/shape mouse Record/Cancel/Record/Save and Codable round trips, and
  install-image verification before and after artifact upload/download. DMGs were
  mounted read-only, copied to simulate drag installation, and launched.
- All six CI fixture screenshots were visually inspected, including Chinese
  trackpad and English Magic Mouse advice. The 980×681 window fits the runner's
  usable screen frame; Save is reachable and the form content scrolls above a
  fixed footer. This is not a physical-device or accessibility audit.
- Earlier failed runs remain useful evidence: retired runner, obsolete fixed
  click coordinates, then a real oversized editor. No failing assertion was
  skipped to obtain the successful result.
- Hardware, permissions, native overlap outcomes and app compatibility: **not
  tested**. No native suppression claim is made.

Before release, keep the complete development/CI checks passing on macOS. Reproduce
the idle and mid-contact app/configuration changes on built-in and external
trackpads and Magic Mouse, verify two-device isolation, and check the advice in
English and Chinese at the minimum editor size. Touch-editor screenshots are now
part of CI's review artifacts. Only the isolated test branch is being updated;
no main-branch merge, release or system setting was changed.

## Follow-up: verification without a personal computer (2026-11-09)

Cloud verification now covers macOS 15 ARM64, macOS 15 Intel and macOS 26 ARM64.
The new inactive coordinator reserves an explicitly correlated raw session before
returning native consumption, revokes stale queued actions, and admits at most one
action per supplied session. Separate context cancellation preserves already-owned
native streams while cancelling their actions. Independent review added regression
coverage for unidentified senders, duplicate registry associations, unverified
terminal packets and delayed native openings belonging to an earlier raw session.

The replay suite includes 33 coordinator test methods, 330 fixed single-session
channel interleavings, six CoreGraphics decoder-to-admission scenarios and 33
upstream WebKit browser-back packets as negative cases. All positive source/build/
correlation attestations are deliberately simulated; production still constructs
no coordinator and enables no native interception profile. PID zero is no longer
accepted as physical-source proof.

The expanded Intel CI exposed a SwiftUI Canvas/Metal crash in the free-form shape
editor. Its simple preview now uses AppKit/CoreGraphics; recording input remains
with the existing DragGesture. Nine CPU bitmap/view tests cover orientation,
colors, stroke/marker geometry, empty/one-point paths, resize and redraw requests.
The shape screenshot and existing mouse-button capture/save smoke remain enabled.
Those checks do not simulate drawing a physical shape with a real mouse.

### Final cloud verification

Code revision `f3ba61d3dac1c2da2ad321a0a46bead1afb69bb7` passed
[CI run 42557789747](https://github.com/AaronJny/flowgesture/actions/runs/42557789747)
on all three matrix jobs:

| Runner | Actual macOS / build | Swift | Result |
|---|---|---|---|
| `macos-15` (ARM64) | 15.8.2 / 24H232 | 6.1.2 | All steps passed |
| `macos-15-intel` | 15.7.9 / 24G830 | 6.1.2 | All steps passed |
| `macos-26` (ARM64) | 26.7.2 / 25G332 | 6.3.3 | All steps passed |

Each job passed **247 Swift tests with zero failures**, native bridge tests,
universal app build, launch, all seven UI fixture renders, foreground mappings,
text editing and pause, full-screen action, native shortcut capture, actual
shortcut Record/Save persistence, click/draw/shape mouse Record/Cancel/Record/Save,
and both original and downloaded install-image verification and launch. The CPU
shape previews were visually inspected on all three runners at `7896801`; no
renderer/UI code changed afterward. Final smoke checks also passed on all three.

The expanded Intel run exposed a second, test-only timing defect: the complete
side-button action arrived before its deadline, but a delayed poll rejected it.
The smoke now timestamps full predicate observations in the audit callback and a
common-modes timer. The complete 250 ms quiet interval must fit inside the 2 s
stage budget; late first observations and extra/wrong events still fail. Twelve
regressions cover these timing and sequence rules, and an independent 15 s
watchdog bounds the whole probe. In the final Intel run the pair arrived at
+0.320/+0.321 s; the delayed poll accepted that timely evidence, and the exact
four-event sequence, editing and pause assertions all passed.

The Linux native bridge and fake-runtime checks also passed again, including
ASan/UBSan with leak detection disabled for the executor's ptrace limitation.
Only documentation changed after the verified code revision above.

See [the no-connection verification report](no-connection-verification.md) for
public source evidence, the scoped trace-search result and an optional self-run
baseline. No connection, new permissions, security changes or automatic trace
upload are required. Native Spaces/Mission Control suppression remains unverified
and inactive; cloud tests must not be described as physical-device certification.
