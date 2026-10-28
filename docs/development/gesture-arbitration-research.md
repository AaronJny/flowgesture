# System-gesture conflicts: evidence and implementation options

Research date: 2026-10-28. **Read-only research; no system preferences changed, no third-party binary installed, and no new event interception implemented. No physical Mac was available for this investigation.** This document separates documented contracts, original-project reports, and proposed experiments.

## Decision in brief

1. **Current FlowGesture cannot promise to suppress Mission Control, App Exposé, Spaces switching, or another app's native pinch behavior.** Its raw touch callback is an observation channel; its existing event tap subscribes to public keyboard/mouse/scroll types, not an independently validated system-gesture channel.
2. **A useful supported product path is conflict guidance plus user-controlled gesture assignments**, not silently changing Trackpad preferences. A separate, explicitly scoped scroll-consumption feature is technically plausible but would not establish system-gesture suppression.
3. **Do not claim interception is universally impossible.** Original projects report consuming private Dock/WindowServer gesture events, particularly horizontal Spaces swipes. That is a credible research path, not proof that FlowGesture can block vertical Mission Control gestures on every supported OS/device.
4. **No guessed private type numbers, fields, phase masks, or “return nil for everything” patch should enter the production event tap.** A private backend requires a separate versioned compatibility investigation and physical-machine acceptance before activation.

## 1. What the APIs actually guarantee

| Channel | Visibility and timing | Consumption boundary |
|---|---|---|
| `NSEvent.addGlobalMonitorForEvents` | Copies events posted to other applications; delivered asynchronously. It excludes the monitoring application's own events. | Read-only: no modification or prevention of original delivery. Suitable for diagnostics, not cross-app arbitration. [Apple global monitor](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:)) |
| `NSEvent.addLocalMonitorForEvents` | Runs before dispatch of events addressed to this application; events consumed by nested tracking loops can bypass it. | Returning `nil` stops this app's dispatch, not the system's handling or another app's delivery. [Apple local monitor](https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents(matching:handler:)) |
| AppKit gesture recognizers | Attached to a particular view or its descendants, processing events received by the app. | May delay events before that view handles them. `delaysMagnificationEvents` does not grant authority over other applications or Dock. Useful for FlowGesture's own recorder/test window. [Apple recognizer](https://developer.apple.com/documentation/appkit/nsgesturerecognizer?language=objc), [magnification delays](https://developer.apple.com/documentation/appkit/nsgesturerecognizer/delaysmagnificationevents) |
| Active `CGEventTap` | Filters events actually delivered at the selected tap location and allowed by its mask/permissions. | The callback can return the original/replacement event or `NULL` to delete that event. A listen-only tap cannot affect delivery regardless of its return value. [Apple callback contract](https://developer.apple.com/documentation/coregraphics/cgeventtapcallback?language=objc) |
| Current `MultitouchSupport` contact callback | Reports contact frames independently of the Quartz callback. The original reverse-engineered declaration returns `void`, not an event-disposition result. | No consumed/cancel-system contract is provided by this callback. This is a statement about the callback FlowGesture uses, not proof that no other private mechanism exists. [Original declarations](https://github.com/calftrail/TrackMagic/blob/master/MultitouchSupport.h) |

Apple documents `CGEventType` cases for keyboard, buttons, pointer motion, scrolling, tablets, and tap state. It does not document public Mission-Control, Dock-swipe, magnify, or rotate cases there. AppKit's gesture enum and Quartz's public event enum are **not interchangeable**, and casting an `NSEvent` numeric value into a `CGEventType` is not a supported suppression contract. [Apple Quartz event types](https://developer.apple.com/documentation/coregraphics/cgeventtype?changes=la)

Tap placement matters, but its name must not be overinterpreted. Apple's session tap is where events enter a login session; the annotated tap is on the path to an application. “Head insert” refers to tap-chain placement, not a guarantee of running before every driver, WindowServer, or Dock recognizer. Tap creation can fail or strip disallowed mask bits. Moving to a different tap location is not evidence that a previously invisible gesture becomes suppressible. [Apple tap locations](https://developer.apple.com/documentation/coregraphics/cgeventtaplocation), [tap creation](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:))

Apple's trackpad guide distinguishes touch sequences from driver-recognized gesture sequences. A gesture sequence may start after contacts begin, can end or cancel, and multiple interpreted gestures can occur during one contact sequence. Scroll events are handled as mouse/scroll-wheel events and can continue through momentum after fingers lift. Therefore contact count alone is not equivalent to the lifetime of a system gesture. [Apple trackpad event handling](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingTouchEvents/HandlingTouchEvents.html)

## 2. Original-project evidence, including counterexamples

### Raw observation does not itself reserve a gesture

**ThreeFingerSwitcher** explicitly describes its MultitouchSupport input as passive. Its documented strategy is to change conflicting gesture assignments with user consent, then separately consume residual scroll-wheel events while its own gesture mode owns that interaction. The project carefully distinguishes preference-based removal of a native gesture from consuming scrolling. Its README is GPL-3.0 project documentation; no implementation was copied. [Original README, architectural keystone](https://github.com/amitayks/ThreeFingerSwitcher#the-architectural-keystone-internalize-this-before-anything-else)

**StrokeMouse** documents that its experimental raw-touch gestures do not intercept native trackpad events, so a native gesture may run alongside its assigned action. This is evidence about that implementation, not a platform impossibility theorem. [Original StrokeMouse README, experimental touch gestures](https://github.com/Licoy/StrokeMouse#experimental-touch-gestures)

**BetterTouchTool's own continuous-gesture documentation** distinguishes suppression of native scrolling/momentum and native pinch/rotation from other macOS swipe assignments. Its explicit warning is: “Other macOS swipe assignments may still run; disable conflicting assignments if needed.” This is particularly useful evidence that blocking scrolling is not equivalent to blocking Mission Control/Spaces. It does not disclose a reusable public global-pinch interception API. [Vendor documentation, compatibility section](https://docs.folivora.ai/docs/trackpad-mouse/continuous-gestures/#compatibility-and-troubleshooting)

### Private system-gesture interception is a real research candidate

**strafe** documents an active session event tap limited to private gesture and Dock-control event classes. Its security document identifies the private fields used to classify a real horizontal Space swipe and describes phase-sensitive terminal handling. Its README claims replacement of the ordinary animated Space swipe. The repository license is MIT (with additional notices); we read documentation only and copied neither code nor constants. [Original strafe security document](https://github.com/rileycx/strafe/blob/main/SECURITY.md), [README](https://github.com/rileycx/strafe), [license](https://github.com/rileycx/strafe/blob/main/LICENSE)

**Cyclist** independently documents interception of the system Spaces swipe before Dock handles it, while requiring the native gesture setting to remain enabled so the corresponding events are generated. It describes pass-through while Mission Control/App Exposé is already open. Its README supports investigating a private event-stream backend; it does not establish FlowGesture's compatibility or universal vertical-gesture suppression. No license-based reuse permission was assumed, and no code was copied. [Original Cyclist README](https://github.com/pszypowicz/cyclist#known-limitations)

Important source qualification: strafe's `docs/SPEC.md` says it describes the upstream InstantSpaceSwitcher implementation, **not strafe's authoritative current code**. In particular, it should not be used as a drop-in recipe for masks, timing, or recovery. [Spec qualification](https://github.com/rileycx/strafe/blob/main/docs/SPEC.md)

These reports are compatible rather than contradictory: a raw contact observer cannot consume events merely by observing them, while a **different, private, phase-aware Quartz gesture backend** may intercept particular system gestures on tested builds. Neither horizontal-Space examples nor UI build success prove vertical Mission Control interception.

## 3. Why timing prevents a quick `return nil` fix

Local code inspection found the following:

- `FlowGestureNative.c` registers a `void` contact callback and starts each device normally.
- `TouchMonitor.swift` copies each frame and dispatches it asynchronously to the main queue.
- `EventEngine.swift` currently creates an active session tap with standard button, movement, scroll, and keyboard cases. Raw touch recognition happens separately. Actions are deferred beyond input callbacks.

**Engineering inference:** when a raw recognizer decides that a swipe or tap matched, an overlapping native event may already have passed its tap or begun its animation. Returning `nil` from an unrelated later callback cannot retract that earlier delivery. Global `NSEvent` observation is additionally asynchronous by contract, so its handler cannot serve as a late veto.

A speculative backend needs explicit ownership at the earliest relevant phase. It must distinguish at least: observing, eligible-before-begin, claimed sequence, and pass-through-until-end. Claiming after forwarding begin, forwarding a random terminal phase after suppressing the rest, or treating all-up as momentum-ended risks partial input streams. The correct terminal protocol for private Dock events is itself an empirical compatibility question, not something to invent from raw contact phases.

Recognition and action execution must not block an event tap waiting for UI work. Apple's timeout-disabled tap event is another reason to keep the callback bounded and move logging/action work out of it. A timeout or permission interruption must abandon ownership, not blindly re-enable a stale claimed session. [Apple timeout notification](https://developer.apple.com/documentation/coregraphics/cgeventtype/tapdisabledbytimeout)

## 4. Concrete implementation paths

### A. Conflict assistant — practical now, no system mutation

Add an advisory to overlapping touch-rule editors with three explicit choices: choose another gesture/finger count, keep coexistence, or review the system's assignment manually. Explain the likely collision by gesture family, without claiming its current setting was read or disabled.

For trackpads, guide users to **System Settings → Trackpad → More Gestures** for Mission Control, App Exposé, full-screen application switching, and page swipes; use **Scroll & Zoom** for pinch/rotation. Apple's guide documents these user-controlled assignments. Mouse touch-surface assignments belong to **Mouse → More Gestures**, not the trackpad pane. [Apple Trackpad settings, Sonoma version](https://support.apple.com/guide/mac-help/change-trackpad-settings-mchlp1226/14.0/mac/14.0), [Apple Mouse settings](https://support.apple.com/en-mk/guide/mac-help/mh29222/mac)

Recommended status wording: **“Potential system overlap — FlowGesture does not currently suppress this native gesture.”** Do not show “Conflict resolved” merely because the user opened Settings. A user declaration that an assignment was changed is not a machine-verified suppression capability. Modifier requirements and per-app scopes reduce accidental FlowGesture activation; they do not prove macOS ignores the same physical gesture.

No `defaults write`, Dock restart, logout, seizure, TCC reset, or background preference change is part of this path.

### B. Public scroll-event ownership — limited experiment, not Mission Control suppression

A separately labeled opt-in could suppress **only public scroll-wheel events** for a precisely matched interaction, while leaving unrelated devices, ordinary scrolling, and unknown sources untouched. Before implementing it, prove correlation between the touch device and the event sender, establish whether ownership is available before the first scroll phase, and measure the momentum tail. The existing distinct MT/IORegistry identity namespaces must not be equated by assumption.

If the initial phase has already passed, or identity is unknown, leave the entire interaction alone and report coexistence. Never infer “trackpad” from continuous scrolling alone. This path can address scroll leakage after a user frees a gesture assignment, but must not be labeled “block Spaces/Mission Control.”

### C. Private Dock/system-gesture backend — isolated research branch

The original projects above justify an experiment, not a production shortcut. The first milestone is a passive capability probe on the actual supported macOS builds. Only after identifying complete gesture sequences, device attribution, and ordering should an explicit test mode try narrowly scoped active consumption.

Keep this backend independent of the raw recognizer. Gate activation on a recorded compatibility result for the exact OS/build and gesture family; unsupported or changed payloads stay pass-through. Do not make undocumented numeric casts seem safe merely by wrapping them in an enum or calling `dlsym`—symbol presence cannot validate an event payload. Initially investigate horizontal Spaces separately from vertical Mission Control, App Exposé, pinch, and taps. Do not inherit a horizontal success claim across those families.

No private field constants or interception code are added by this research document. Implementing and enabling that backend needs a dedicated physical-machine test session with a reliable recovery input path.

### D. Full HID-device seizure — not a scoped default-input-preserving solution

Apple's exclusive-open option prevents the system and other clients from receiving that device's events. It therefore is not a selective gesture-ownership API; preserving normal input would require a much broader replacement pipeline. Do not use it as a shortcut for an overlapping swipe, and do not assume every Apple trackpad supports a suitable public seize/reinject path. [Apple exclusive device option](https://developer.apple.com/documentation/iokit/1556660-anonymous/kiohidoptionstypeseizedevice)

## 5. Physical-machine validation plan and acceptance gates

This is a proposed plan, **not completed testing**. No preference toggles are performed by the research or by a passive probe.

1. **Record the environment:** exact OS build, Intel/Apple silicon, built-in versus wired/Bluetooth trackpad, Magic Mouse, connected second mouse, permissions and signing identity, enabled native assignments, Spaces/display layout, and other gesture tools. Use a separate test account and a second known-working input device before any active experiment.
2. **Baseline without suppression:** confirm native outcomes and FlowGesture recognition separately. Test slow swipes, fast flicks, reversal, staggered fingers, taps, pinch, cancellation, and unexpected extra contacts. Record whether both actions happen—not just whether our action fires.
3. **Passive timing trace:** collect bounded, in-memory records of monotonic receipt time, source channel, observed event type/phase, optional sender identity, raw finger-count/session transition, foreground app changes, and action-dispatch time. No key text, full window content, or persistent raw trajectories. Use both local and global AppKit monitors only where their scope requires them. Distinguish “not observed” from “consumed by the OS”; an absent event is not proof of where it disappeared.
4. **Known-public-event control:** in a test mode, consume only an explicitly selected harmless public event addressed to a test view/application and confirm the consumption contract. This validates plumbing, not system-gesture ownership.
5. **Private-backend gate:** for each candidate system gesture, first prove a reproducible, complete observable phase sequence and that the proposed decision occurs before native behavior starts. If that cannot be established, no active claim is justified. Active tests must be separately opted into, narrowly scoped, and immediately disableable.
6. **Outcome matrix:** test three- and four-finger horizontal/vertical swipes, Mission Control and App Exposé already open, first/last Space, fullscreen transitions, multiple displays, normal two-finger scroll plus momentum, Safari/Preview pinch, Magic Mouse gestures, simultaneous second-device input, and an unrelated app scope. Add stop/restart, sleep/wake, disconnect, focus changes, callback backlog, and permission loss.
7. **Stop conditions:** any stuck animation, missing normal click/scroll, cross-device consumption, unresolved terminal state, dropped input, or permission-dependent ambiguity ends that backend's activation for the affected build/family. Do not attempt to “repair” it by sending guessed cancellation packets, restarting Dock, changing preferences, or seizing hardware.
8. **Pass criteria:** the intended action occurs once; the overlapping native outcome does not occur for the claimed family; unrelated events remain normal; interruption returns to pass-through; repeated trials reveal no stuck state. Record latency distributions and failures, not a single successful demo. Hardware checks remain distinct from unit tests and macOS CI compilation.

## Implemented next step: passive local diagnostics

The independent `GestureDiagnostics.swift` observer is now implemented as infrastructure, not as evidence of live system-gesture visibility. It uses a public all-events mask with known unrelated public event types excluded, a listen-only tap, a 512-record memory ring, fixed-vocabulary recognition labels, and a maximum 60-second explicit session. Unknown event types remain raw observed numbers and receive no private-field interpretation. See [gesture-diagnostics.md](gesture-diagnostics.md) for API, telemetry boundaries, and unrun hardware checks. This addition makes no system-settings changes and never consumes events.

## Scope of the conclusion

We now have a defensible, staged route: ship honest conflict guidance; test public scroll ownership separately; investigate a private system-gesture channel using original-project evidence and exact-build hardware tests. **We have not established that FlowGesture can prevent Mission Control.** We also have not established that no implementation ever can. No user system state was modified to reach these conclusions.
