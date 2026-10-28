# Touch and device bridge: implementation and validation

## Current verification status

**Implemented and macOS CI build-tested; not hardware-validated.** This bridge was authored on Linux without Swift, a macOS SDK, or attached Apple input hardware. Do not describe the private API ABI, permissions, device identity, sleep/wake recovery, or gesture behavior as verified from build or decoder tests.

Local checks on 2026-10-28:

- Passed: C11 compilation with `-Wall -Wextra -Werror -pedantic` on the portable branch.
- Passed: deterministic touch-record decoder tests and explicit non-macOS unavailable/unknown behavior.
- Passed: the same tests with AddressSanitizer and UndefinedBehaviorSanitizer, **with leak detection disabled**. LeakSanitizer itself could not run in the executor because its ptrace environment is incompatible; no leak-check pass is claimed.
- Parent-confirmed [second macOS CI run](https://github.com/AaronJny/flowgesture/actions/runs/40644349810), on macOS 14.8.9 arm64 with Swift 5.10: strict native tests, full-app Swift Debug compilation, and all 36 core tests passed; arm64 and x86_64 Release compilation also succeeded. The run did **not** complete artifact packaging because its `lipo` invocation had incorrect arguments. That script was subsequently corrected, but this evidence does not establish successful packaging of the correction.
- Not run: live capture, callback stress under Apple's framework, hotplug, wake, real event-sender resolution, or hardware leak tests. macOS CI compiles and runs the decoder test without opening a device; it cannot establish hardware behavior.

Run from the repository root:

```sh
bash scripts/test-native-bridge.sh
SANITIZE=1 bash scripts/test-native-bridge.sh
# Only for a test environment with the documented LeakSanitizer/ptrace failure:
ASAN_OPTIONS=detect_leaks=0 SANITIZE=1 bash scripts/test-native-bridge.sh
```

The native test never starts capture on macOS and does not request Input Monitoring or Accessibility permission. It covers valid multi-contact and maximum-sized frames, all eight phase values, unaligned reads, duplicate/negative identities, impossible phase values, null buffers, zero-contact frames, capacity/count bounds, timestamp and coordinate NaNs/infinities, quality validation, and modest edge-coordinate clamping.

## Module contract

`FlowGestureNative` has no static dependency on the private multitouch framework. It loads only the system framework at its absolute path and checks every required symbol before registering any callbacks. Missing optional identity symbols do not prevent touch capture. Missing required unregister/start/stop/registration symbols yield an explicit unavailable status.

`TouchMonitor` provides:

- `start()`, `stop()`, `refreshDevices()`, `refreshDiagnostics()` on the main thread.
- Main-thread `onFrame`, `onStatus`, `onDevicesChanged`, and `onReset` callbacks.
- `RawTouchFrame.deviceID`: opaque **session** identity, not a persistent configuration key or an HID sender ID.
- `RawTouchFrame.activeContacts`: only physically touching phases; an empty array marks all-up.
- `RawTouchFrame.cancelled`: discard partial recognition without executing an action. Recognition must remain suppressed until a subsequent valid all-up frame. The delivery queue also enforces this after loss.
- Separate `registryID` and `multitouchID` fields when available. Do not assume those identity namespaces are interchangeable.
- Optional calibrated pressure is always `nil`. The available contact-quality scalar is not Force Touch pressure and must not drive a purported pressure threshold.

Use a recognizer per `deviceID`. Reset all recognizers on `onReset`; never combine contacts from different devices. Coordinates use a bottom-left origin, with positive Y up. Frame timestamps are the framework's monotonic seconds, not wall-clock dates; they are suitable for intervals inside a touch stream, not direct comparison with `Date`.

Saved touch rules carry `TouchDeviceScope.any`, `.trackpad`, or `.mouse` (for a touch-capable mouse such as Magic Mouse). Existing JSON without the `device` field, or with a null field, imports as `.any`; malformed explicit values still fail decoding. Valid schema-1 settings migrate to schema 2 in memory. Exports always advertise schema 2 so older versions reject the new format rather than ignore device restrictions; unknown schema versions remain marked as unknown and are rejected by validation. This model migration does not change the application’s disk-loading policy. Only a saved `.any` rule is a wildcard: an observed event with unresolved type cannot match a device-specific rule. Gesture details and modifiers remain exact. Existing app-specific, priority, and saved-order precedence is unchanged. Device-scoped rule support does not establish hardware identification accuracy or system-gesture suppression.

## Ownership and delivery

The native adapter enumerates the complete returned device list, retains each unique device for its registration lifetime, registers each callback independently, and reports individual start errors. It does not exclusively seize HID devices or request a systemwide gesture suppression mechanism.

On stop, admission is revoked before unregister/stop calls; callbacks already admitted are drained before retained devices or Swift context can be released. Native callbacks never synchronously wait for the main queue. Do not call native lifecycle functions synchronously from their callback. The Swift wrapper only copies and queues the values, so stopping from `onFrame` is supported.

A bounded 256-frame queue cancels affected sessions on overflow and drops further partial frames until all-up. Queued pre-stop frames cannot cross a new monitoring generation. Process-lifetime handles keep the small, fixed set of loaded system frameworks resident, avoiding unload races.

The Swift wrapper rebuilds on system wake, stops on sleep, and checks device topology every three seconds. It retries failed device starts; it does not recreate a running device list on every timer tick. A manual refresh is available for stale driver handles not reflected by topology. Multiple simultaneous native monitors are rejected rather than registering duplicate global listeners.

## Private ABI limits

The decoder independently expresses the observed 64-bit record layout as a byte stride and offsets. It does not vendor any reverse-engineered implementation or private header. The observed stride is 96 bytes; consumed fields are contact identity at offset 16, phase at 20, normalized coordinates at 32 and 36, and contact quality at 48. Phases 3 and 4 are active; 5 is break-contact, and the remaining phases are range/tracking transitions.

The frame callback has no byte-length parameter or versioned struct contract. Bounds, phase, finite-number, and duplicate-ID checks reject malformed data but **cannot prove the private layout is unchanged or guarantee safe decoding after an incompatible OS change**. Review this adapter on each supported macOS update. Missing symbols fail explicitly; suspicious decoded frames cancel sessions and increment diagnostics. A nonzero rejected-frame count must be investigated rather than ignored.

Enumeration can include non-trackpad touch surfaces such as Touch Bar or other sensors. Device category is separate from raw capture. The application should restrict action execution to intended devices or provide explicit device selection; raw discovery alone is not evidence that a device is a trackpad.

## CGEvent source identity

`EventDeviceIdentity.senderID(for:)` dynamically resolves `CGEventCopyIOHIDEvent` and `IOHIDEventGetSenderID`. Missing functions, missing underlying HID events, or sender zero yield `nil`. The copied HID object is released after reading its ID.

`EventDeviceIdentity.info(for:)` looks up that sender in IORegistry. Classification uses an explicit trackpad/touchpad product label or digitizer-touchpad usage, an explicit mouse product label, or mouse HID usage without conflicting digitizer/multitouch evidence. It reports its evidence, vendor/product metadata, and registry lookup success. Classification is metadata-based, not a promise of physical-device identity: composite/virtual devices, receivers, generic product labels, driver changes, and missing registry data can remain unknown. Built-in status alone is not used to classify a device.

There is **no** fallback equating continuous scrolling with a trackpad, discrete scrolling with a mouse, a zero sender with the built-in device, or missing recent touch data with a mouse. Unknown sources should pass through unless the user explicitly opts into broader behavior. Registry lookup results have bounded, short-lived caching; they are cleared on device refresh/wake.

## Required macOS validation before release

Record macOS build, architecture, hardware model, connection type, signing mode, permission state, observed device identities, callback counts, rejected-frame count, and expected versus observed results. Do not publish serial numbers or full private event logs.

| Test | Required result |
|---|---|
| Intel and Apple silicon builds | Swift/C compile and launch without linking private symbols statically |
| Missing framework/symbol debug fixture | Explicit unavailable status, app remains usable, no registration attempted |
| No touch device | Explicit no-devices state, ordinary configured input still works |
| Built-in trackpad | Correct device category or explicit unknown; 1–5 contacts, positions and phases validated |
| Wired/Bluetooth Magic Trackpad | Separate identity, correct lifecycle and complete contact stream |
| Built-in + external simultaneously | Independent gesture sessions; contacts never merged |
| Magic Mouse | Mouse metadata where available; raw touch surface does not become a trackpad by default |
| Ordinary mouse / multi-device receiver | Source category checked against physical device; ambiguous events remain unknown |
| Touch Bar / other multitouch sensors | Enumerated safely; does not trigger unintended trackpad actions |
| Stop during live frames, then rapid start/stop | No stale actions, use-after-free, deadlock, or growing queue |
| Quit while touching | Clean callback drain without a crash |
| Sleep/wake with fingers down | Old sessions canceled; no release-triggered action after wake |
| Bluetooth disconnect/reconnect | List updates and fresh session identity; disconnected sessions canceled |
| Foreground-app change mid-gesture | No action applied to the wrong application |
| Main-thread stall / delivery overflow | Session cancellation, bounded memory, no synthetic partial tap |
| Permission denial/revocation | Honest blocked/failed diagnostics; no claim that zero callbacks means permission success |
| Mouse and trackpad scrolling side by side | Mouse-only settings leave confirmed trackpad and unknown sources unchanged |
| Sender ID zero / underlying HID event absent | Explicit unknown, no silent classification fallback |
| Real Force Touch press | No fabricated pressure value or unsupported force recognition |

Useful local checks are `swift build`, `swift test`, and the native script above. Hardware stress and leak tools require a real, authorized macOS test session and are separate from passing CI.

## Primary research references

These sources were inspected for API facts, lifecycle/ownership conventions, observed layout, and platform limitations. FlowGesture's implementation is independently authored; no BAB, GPL, or Creative Commons implementation code was copied.

- [Calf Trail's original reverse-engineered MultitouchSupport declarations](https://github.com/calftrail/TrackMagic/blob/master/MultitouchSupport.h): observed layout, phases, callback/device function signatures. This is not an Apple compatibility guarantee.
- [Apple WebKit CoreGraphics SPI declarations](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/PAL/pal/spi/cg/CoreGraphicsSPI.h): `CGEventCopyIOHIDEvent` signature.
- [Apple WebKit IOKit SPI declarations](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/PAL/pal/spi/mac/IOKitSPIMac.h): sender ID type and `IOHIDEventGetSenderID` signature.
- [Apple CGEvent documentation](https://developer.apple.com/documentation/coregraphics/cgevent): Quartz event/HID pipeline context.
- [Apple IORegistry entry ID matching documentation](https://developer.apple.com/documentation/iokit/1514880-ioregistryentryidmatching): sender-to-registry lookup.
- [Apple IORegistry property lookup documentation](https://developer.apple.com/documentation/iokit/1514537-ioregistryentrysearchcfproperty): registry hierarchy and returned-property ownership.
- [Apple HID property-key source](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/IOHIDKeys.h): primary usage is insufficient for composite HID devices; usage-pair metadata is considered as well.
