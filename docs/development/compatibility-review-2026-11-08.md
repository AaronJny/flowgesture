# Daily-use compatibility changes

Baseline: `cc654e6` on `main`, following v0.1.3. This is an isolated test build, not a release or physical-device certification.

## Included fixes

- Preserve the first gesture after an idle application/configuration change; interrupt only still-active contacts and reject queued old-context actions.
- Preserve early movement while fingers join during the 80 ms recognition window, including short flicks that finish on release.
- Retry failed touch devices with 3–60 second backoff without restarting healthy devices.
- Keep the rule editor's Save/Cancel footer reachable on small displays.
- Draw shape previews through AppKit/CoreGraphics instead of the Intel-crashing Canvas path.
- Show likely native overlaps for the selected gesture/device. Open System Settings without changing preferences, or disable the current draft rule and save. Cancel does not apply the draft.

## Practical conflict handling

FlowGesture does **not** intercept native multi-finger gestures. Users choose either the custom action by manually disabling the overlapping system gesture, or the system action by disabling corresponding FlowGesture rules. Inputs without an off switch, such as ordinary scrolling, should use another custom trigger instead. Modifiers and application scopes do not disable macOS gestures. The guidance does not detect the user's current system assignments.

No device capture, private-event interception, Quartz/Dock replay harness or standalone collector is added to this minimal change set. Earlier experiments remain in Git history through `74041a3`; they are not required to build or use the app.

## Validation and delivery

The existing CI builds/tests macOS 15 ARM64, macOS 15 Intel and macOS 26 ARM64, exercises app UI/actions and verifies the downloaded universal DMG. Native bridge tests also run without physical hardware. Each new source commit requires its own CI result; earlier successful runs do not certify later changes.

Physical touch detection, Bluetooth reconnects, device-specific behavior and native interactions remain unverified. Prior isolated Intel foreground-smoke latency has no demonstrated root-cause fix; the strict existing timing checks and bounded diagnostics remain. Do not interpret cloud tests as physical-device certification.

The test DMG is ad-hoc signed, not notarized, and still uses the app's existing 0.1.3 version metadata. Identify it by source commit and hash. Do not run the existing release workflow for this build: it is fixed to the older v0.1.3 commit/artifact. No merge or release is part of this change.
