# Experimental native horizontal arbitration foundation

Research and implementation: 2026-11-08. This is a pure value model, not an enabled event interceptor. It installs no taps, changes no preferences, and does not establish that FlowGesture blocks any native gesture. No physical Mac was available. No third-party implementation was copied.

## Evidence and boundaries

Read current upstream source, pinned to the following revisions:

- strafe `42f69de6007348f7da0f5cba8c5b3ec534f18da2`: [classification and ownership, SwipeInterceptor.swift lines 185–226](https://github.com/rileycx/strafe/blob/42f69de6007348f7da0f5cba8c5b3ec534f18da2/Sources/strafe/SwipeInterceptor.swift#L185-L226), [terminal protocol lines 228–264](https://github.com/rileycx/strafe/blob/42f69de6007348f7da0f5cba8c5b3ec534f18da2/Sources/strafe/SwipeInterceptor.swift#L228-L264), and [C field declarations](https://github.com/rileycx/strafe/blob/42f69de6007348f7da0f5cba8c5b3ec534f18da2/Sources/CStrafe/CStrafe.c).
- Cyclist `cc9d5db2c89a60f86cd89726da9bf145654d46c7`: [native encoding and scope, DockSwipeRecognizer.swift lines 4–41](https://github.com/pszypowicz/cyclist/blob/cc9d5db2c89a60f86cd89726da9bf145654d46c7/Sources/Cyclist/DockSwipeRecognizer.swift#L4-L41), [ownership/terminal handling lines 54–90](https://github.com/pszypowicz/cyclist/blob/cc9d5db2c89a60f86cd89726da9bf145654d46c7/Sources/Cyclist/DockSwipeRecognizer.swift#L54-L90), and [separate active session taps](https://github.com/pszypowicz/cyclist/blob/cc9d5db2c89a60f86cd89726da9bf145654d46c7/Sources/Cyclist/EventTap.swift).
- WebKit `b2d2c2de1c74e095233e4ed243272fa7f0f89698`: [CoreGraphicsTestSPI.h](https://github.com/WebKit/WebKit/blob/b2d2c2de1c74e095233e4ed243272fa7f0f89698/Tools/TestRunnerShared/spi/CoreGraphicsTestSPI.h#L39-L94) independently corroborates private selector 55, classes 29/30, HID field 110, axis 123, progress 124, X velocity 129, and phase 132. Phases are exact values 0/1/2/4/8/128, not guessed combinable masks.
- [Apple IOHIDEventService.cpp](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/IOHIDEventService.cpp) assigns `event->setSenderID(getRegistryEntryID())`. This supports comparing actual registry identities when available; it does not prove a derived Dock event retains the original sender.

Both original recognizers require HID type 23 and horizontal axis 1 and deliberately exclude vertical Mission Control/App Exposé. PID zero filters synthetic events; it does **not** identify a physical trackpad or finger count.

Their terminal behavior differs. Cyclist consumes qualifying ended/cancelled phases. strafe may forward an uncommitted ended event, and on its macOS-27 synthetic-posting path forwards a zero-motion real ended event after successfully posting its own switch. At a Space edge it can suppress the terminal instead. These are not interchangeable protocols. This foundation emits only consume/pass-through decisions, never terminal repair packets or synthetic swipes.

## Model contract

`NativeHorizontalSwipeArbitrator` is experimental and production-inactive. The default `TestGate` denies claims. A future adapter must explicitly enable a test, match a nonempty exact OS build to a validated profile, and attest that the **complete** companion/terminal protocol is validated. These fields are a caller contract, not machine-verified capabilities or an OS allowlist.

The value decoder recognizes the source-backed horizontal fingerprint for classes 29/30. Only fully identified class-30 events drive ownership. Class-29 companions always pass through because a complete source/sequence correlation is not established. Consequently, if suppression requires dropping such companions on a tested build, this model cannot support that build and `completeStreamValidated` must remain false.

A claim requires a real-source PID, a nonzero sender registry ID exactly matching eligibility, a recognized opening phase, finite numeric fields, and complete horizontal-family coverage. Eligibility must include an independently identified trackpad, allowed app/modifier context, no native overlay, both left/right mappings, and equivalent actions across all possible 3/4-finger matches. The adapter is responsible for these facts. A dedicated native-horizontal rule family is safer than pretending begin encodes finger count.

Eligibility/action IDs freeze at opening. Passing a mayBegin/began means the whole sequence stays pass-through even if rules become eligible later. An orphan changed event also commits pass-through until terminal. A claimed sequence produces at most one action; progress magnitude 0.15 and end velocity magnitude 200 are explicit experiment thresholds, not documented Apple semantics. Cancelled/uncommitted sequences produce no action. MayBegin may advance to began. Duplicate openings, unknown phases, invalid numbers, sender loss/change, or gate withdrawal quarantine the model. Synthetic, unrelated, and generic companion events do not advance it.

Interruption has no lossless native recovery guarantee after some events were consumed. `interrupt()` invalidates queued ownership tokens and quarantines all further claims; no guessed cancellation is posted. `resetAfterVerifiedIdle()` requires independent evidence of an idle boundary, not elapsed time alone. A terminal event alone does not exit quarantine.

## Future adapter obligations (not implemented)

1. Install a separate experimental tap only after explicit test activation and validated capability. Do not add private classes to ordinary production routing.
2. Check callback class against private selector 55 and map fields without substituting missing values. Verify sender identity against the MT service registry ID, never the MT device ID. Cache expensive registry/overlay work outside the callback.
3. Atomically reserve the raw touch session before returning a consuming opening outcome. Suppress corresponding raw actions, including late queued frames and staggered releases, through a verified raw all-up boundary. The native terminal is not automatically the raw terminal. If the raw action already fired, decline ownership.
4. Resolve immutable action IDs and dispatch work outside the tap. Check `isCurrent` immediately before dispatch. Tokens remain current through normal ended to permit deferred end/flick actions, but expire on cancellation, interruption, verified-idle reset, or subsequent classified sequence. An action already dispatched cannot be undone by a later cancellation. Action execution still needs the ordinary rule/action gate.
5. If app/modifier context changes, retain the native stream's original ownership decision. Independently decide whether to cancel the action under existing safety rules. Do not switch native ownership midstream.
6. Report interruption/unknown stream as a failed experiment. Stop activation for that profile rather than treating pass-through as a repaired native sequence.

## Deterministic checks and hardware acceptance

Tests cover default/mismatched gates, incomplete family coverage, immutable eligibility, mayBegin/began, one-shot action and end velocity, orphan events, whole-stream pass-through, cancellation, invalid phases/numbers/source IDs, synthetic/companion/vertical events, token invalidation, and idle-reset quarantine.

Swift is unavailable in the current Linux workspace, so these tests have not been compiled or executed here. Syntax and behavior need Swift CI review; test fixtures are not hardware evidence.

Physical-machine blockers: complete private stream ordering; real sender retention and MT registry correlation; first opening arriving before raw action; overlay checks; class-29 companion necessity; terminal consumption without synthetic posting; three/four-finger mappings; simultaneous devices; Space edges/fullscreen/multiple displays; native animation absence; and permission/sleep/disconnect/timeout recovery. No exact-build capability is validated yet. Both actions firing, stuck animation, or unrelated-input loss fails acceptance. Vertical gestures, pinch, scroll, and taps remain outside scope.
