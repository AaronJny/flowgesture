# Daily-use compatibility review

Reviewed baseline: `cc654e6` on `main`, following the v0.1.3 release.
This is a source review and a local patch, not a new release or physical-device certification.

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
| Distribution | macOS 13+, arm64/x86_64 packaging and existing macOS CI | This patch has not been compiled on macOS. Notarization and wider OS/hardware certification remain separate. |

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
system assignment or accept coexistence. This patch does not read/write system
preferences, seize devices, add private event constants or intercept new events.

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

## Remaining acceptance priorities

1. **Run macOS tests and build.** The environment catalog has no Mac, and there
   are no saved cloud configurations. A local test branch exists; remote push
   and GitHub Actions have not run because push approval is pending.
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
- Swift tests, the macOS app build, UI/layout and launch smoke tests: **not run**;
  this environment has no Swift toolchain, Xcode, AppKit or connected Mac.
- Hardware, permissions, native overlap outcomes and app compatibility: **not
  tested**. No native suppression claim is made.

Before release, run the complete development/CI checks on macOS. Then reproduce
the idle and mid-contact app/configuration changes on built-in and external
trackpads and Magic Mouse, verify two-device isolation, and check the advice in
English and Chinese at the minimum editor size. Touch-editor screenshots are now
part of CI's review artifacts. Source changes remain local pending push approval;
no remote branch, PR, release or system setting was changed.
