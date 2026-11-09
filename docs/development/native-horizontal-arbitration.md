# Experimental native horizontal arbitration foundation

Research and implementation: 2026-11-08. This is a pure value model, not an enabled event interceptor. It installs no taps, changes no preferences, and does not establish that FlowGesture blocks any native gesture. No physical Mac was available. No third-party implementation was copied.

## Evidence and boundaries

Read current upstream source, pinned to the following revisions:

- strafe `42f69de6007348f7da0f5cba8c5b3ec534f18da2`: [classification and ownership, SwipeInterceptor.swift lines 185–226](https://github.com/rileycx/strafe/blob/42f69de6007348f7da0f5cba8c5b3ec534f18da2/Sources/strafe/SwipeInterceptor.swift#L185-L226), [terminal protocol lines 228–264](https://github.com/rileycx/strafe/blob/42f69de6007348f7da0f5cba8c5b3ec534f18da2/Sources/strafe/SwipeInterceptor.swift#L228-L264), and [C field declarations](https://github.com/rileycx/strafe/blob/42f69de6007348f7da0f5cba8c5b3ec534f18da2/Sources/CStrafe/CStrafe.c).
- Cyclist `cc9d5db2c89a60f86cd89726da9bf145654d46c7`: [native encoding and scope, DockSwipeRecognizer.swift lines 4–41](https://github.com/pszypowicz/cyclist/blob/cc9d5db2c89a60f86cd89726da9bf145654d46c7/Sources/Cyclist/DockSwipeRecognizer.swift#L4-L41), [ownership/terminal handling lines 54–90](https://github.com/pszypowicz/cyclist/blob/cc9d5db2c89a60f86cd89726da9bf145654d46c7/Sources/Cyclist/DockSwipeRecognizer.swift#L54-L90), and [separate active session taps](https://github.com/pszypowicz/cyclist/blob/cc9d5db2c89a60f86cd89726da9bf145654d46c7/Sources/Cyclist/EventTap.swift).
- WebKit `b2d2c2de1c74e095233e4ed243272fa7f0f89698`: [CoreGraphicsTestSPI.h](https://github.com/WebKit/WebKit/blob/b2d2c2de1c74e095233e4ed243272fa7f0f89698/Tools/TestRunnerShared/spi/CoreGraphicsTestSPI.h#L39-L94) independently corroborates private selector 55, classes 29/30, HID field 110, axis 123, progress 124, X velocity 129, and phase 132. Phases are exact values 0/1/2/4/8/128, not guessed combinable masks.
- [Apple IOHIDEventService.cpp](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/IOHIDEventService.cpp) assigns `event->setSenderID(getRegistryEntryID())`. This supports comparing actual registry identities when available; it does not prove a derived Dock event retains the original sender.

Both original recognizers require HID type 23 and horizontal axis 1 and deliberately exclude vertical Mission Control/App Exposé. Their synthetic-event filters differ: Cyclist rejects its own `eventSourceUserData` tag, while strafe uses PID filtering on relevant paths. **PID zero is not proof of a physical event.** Original InstantSpaceSwitcher [reports synthetic events re-entering with PID zero on macOS 27](https://github.com/jurplel/InstantSpaceSwitcher/blob/2b883a995d1c81fbc6d75704372a6a0b546bb1ff/Sources/ISS/ISS.c#L69-L73). None of these fields alone establishes physical trackpad identity or finger count.

Their terminal behavior differs. Cyclist consumes qualifying ended/cancelled phases. strafe may forward an uncommitted ended event, and on its macOS-27 synthetic-posting path forwards a zero-motion real ended event after successfully posting its own switch. At a Space edge it can suppress the terminal instead. These are not interchangeable protocols. This foundation emits only consume/pass-through decisions, never terminal repair packets or synthetic swipes.

## Model contract

`NativeHorizontalSwipeArbitrator` is experimental and production-inactive. The default `TestGate` denies claims. A future adapter must explicitly enable a test, match a nonempty exact OS build to a validated profile, and attest that the **complete** companion/terminal protocol is validated. These fields are a caller contract, not machine-verified capabilities or an OS allowlist.

The value decoder recognizes the source-backed horizontal fingerprint for classes 29/30. Only fully identified class-30 events drive ownership. Class-29 companions always pass through because a complete source/sequence correlation is not established. Consequently, if suppression requires dropping such companions on a tested build, this model cannot support that build and `completeStreamValidated` must remain false.

A claim requires independently verified physical-source provenance (default: unverified), PID zero as an additional exclusion check, a nonzero sender registry ID exactly matching eligibility, a recognized opening phase, finite numeric fields, and complete horizontal-family coverage. Eligibility must include an independently identified trackpad, allowed app/modifier context, no native overlay, both left/right mappings, and equivalent actions across all possible 3/4-finger matches. The adapter is responsible for these facts. A dedicated native-horizontal rule family is safer than pretending begin encodes finger count.

Eligibility/action IDs freeze at opening. Passing a mayBegin/began means the whole sequence stays pass-through even if rules become eligible later. An orphan changed event also commits pass-through until terminal. A claimed sequence produces at most one action; progress magnitude 0.15 and end velocity magnitude 200 are explicit experiment thresholds, not documented Apple semantics. Cancelled/uncommitted sequences produce no action. MayBegin may advance to began. Duplicate openings, unknown phases, invalid numbers, sender loss/change, or gate withdrawal quarantine the model. Known nonzero-PID, unrelated, and generic companion events do not advance it. An unverified-origin class-30 horizontal packet quarantines the model and invalidates queued actions. The decoder never upgrades PID zero to verified provenance; only a future adapter with independent evidence may attest it.

Interruption has no lossless native recovery guarantee after some events were consumed. `interrupt()` invalidates queued ownership tokens and quarantines all further claims; no guessed cancellation is posted. `resetAfterVerifiedIdle()` requires independent evidence of an idle boundary, not elapsed time alone. A terminal event alone does not exit quarantine.

## Future live adapter obligations (not implemented)

1. Install a separate experimental tap only after explicit test activation and validated capability. Do not add private classes to ordinary production routing.
2. Check callback class against private selector 55 and map fields without substituting missing values. Verify sender identity against the MT service registry ID, never the MT device ID. Cache expensive registry/overlay work outside the callback.
3. Atomically reserve the raw touch session before returning a consuming opening outcome. Suppress corresponding raw actions, including late queued frames and staggered releases, through a verified raw all-up boundary. The native terminal is not automatically the raw terminal. If the raw action already fired, decline ownership.
4. Resolve immutable action IDs and dispatch work outside the tap. Check `isCurrent` immediately before dispatch. Tokens remain current through normal ended to permit deferred end/flick actions, but expire on cancellation, interruption, verified-idle reset, or subsequent classified sequence. An action already dispatched cannot be undone by a later cancellation. Action execution still needs the ordinary rule/action gate.
5. If app/modifier context changes, retain the native stream's original ownership decision. Independently decide whether to cancel the action under existing safety rules. Do not switch native ownership midstream.
6. Report interruption/unknown stream as a failed experiment. Stop activation for that profile rather than treating pass-through as a repaired native sequence.

## Inactive raw/native coordination and replay

`NativeRawGestureCoordinator` now supplies the missing software-side reservation
and action-admission model. Acquisition tickets are separate from delayed delivery;
raw recognition and native ownership share a lock, and every queued action must
consume its one-use admission ticket immediately before dispatch. A native claim
revokes a queued raw action, while an already admitted raw action prevents a late
native claim. Native terminal does not release the raw reservation before raw
all-up. Separate devices stay independent unless identity becomes ambiguous.

Registry identity alone cannot prove that a delayed native opening belongs to the
current raw session. An opening therefore also needs an explicitly supplied,
independently correlated `RawSession` ticket. Missing, old, foreign or mismatched
correlation declines ownership. The token is a caller contract, **not a physical
correlation detector**; a future adapter must not substitute its latest active
session merely because the sender ID matches. No live adapter currently supplies
this evidence.

App/modifier changes use `cancelForContextChange()`: pending actions become stale,
but an already owned native stream remains owned through terminal without new
actions. Capture loss uses `interrupt()`, quarantining uncertain native streams;
this is not a claim of lossless native recovery. Missing sender identity,
ambiguous mappings, unknown provenance and malformed boundaries cannot silently
restore ownership. State is bounded, and a new capture generation requires the
old capture to be stopped and drained.

Tests enumerate 330 order-preserving single-session channel interleavings and
additional multi-session, cancellation, provenance and association regressions.
App-level tests construct CoreGraphics packets, decode fields, reserve sessions
and admit actions, **without posting any event**. Their affirmative build/source/
correlation inputs are explicitly simulated assumptions. The external WebKit
browser-back fixture is a separate 33-packet negative classification replay,
retaining its BSD notice and unverified capture provenance. No test upgrades it
to a Spaces trace. See [verification without desktop access](no-connection-verification.md).

The coordinator is not constructed by production routing. It provides testable
integration logic, not an enabled or physically validated suppression feature.

## Deterministic checks and hardware acceptance

Tests cover default/mismatched gates, incomplete family coverage, immutable eligibility, mayBegin/began, one-shot action and end velocity, orphan events, whole-stream pass-through, cancellation, invalid phases/numbers/source IDs, synthetic/companion/vertical events, token invalidation, and idle-reset quarantine.

The Linux workspace has no Swift toolchain. The foundation and Quartz decoder
tests compiled and passed in the 185-test macOS 15.8.2/Swift 6.1.2 suite at
commit `3cee9b4942481b9c0fdde1d216d49490c938f5b2`
([successful full CI](https://github.com/AaronJny/flowgesture/actions/runs/42489465736)).
All subsequent UI and package checks passed too. The test fixtures and CI success
are not hardware interception evidence.

Physical-machine blockers: complete private stream ordering; real sender retention and MT registry correlation; first opening arriving before raw action; overlay checks; class-29 companion necessity; terminal consumption without synthetic posting; three/four-finger mappings; simultaneous devices; Space edges/fullscreen/multiple displays; native animation absence; and permission/sleep/disconnect/timeout recovery. No exact-build capability is validated yet. Both actions firing, stuck animation, or unrelated-input loss fails acceptance. Vertical gestures, pinch, scroll, and taps remain outside scope.
