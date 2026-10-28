# Acceptance matrix / 验收清单

Target: major-function parity, not merely a settings mockup. A checked-in implementation
is not proof of hardware correctness. No real-device rows are marked passed yet.

| Feature | Implementation | Required acceptance |
|---|---|---|
| Right-button directional drawings | Recognizer + active event tap + replay | Match all 8 directions and turns; ordinary context click/drag preserved; no stuck button |
| Side-button mappings | Button 2–7, modifiers, click count | Test physical buttons and multi-click order |
| Smooth / reverse scrolling | Pixel synthesis and easing, independent axes | No drift/reversal oscillation, no horizontal loss, long-scroll responsiveness |
| Mouse vs trackpad isolation | Sender registry identification + unknown fallback | Built-in/external trackpad unaffected; conventional and smooth-wheel mice both work |
| Multi-finger touch | Raw device frames, stable IDs, taps/swipes/pinch | 1–5 contacts, staggered lift, cancel/wake/disconnect; no duplicate system action |
| Magic Mouse | Device enumeration shares touch pipeline | Actual Magic Mouse contact axes/classification and gesture interaction |
| Keyboard and screen corners | Tap + multi-display edge coordinates | Shortcut down/up symmetry, modifiers, screen arrangements, secure-input behavior |
| Per-app rules/exclusions | Specific-app precedence and stable order | Frontmost-app switching during a gesture, excluded app pass-through |
| Shortcut/script/open/menu/window actions | Native dispatch and AX | Target app/refusal/error behavior, multi-action order, media keys |
| Rule UI, bilingual settings | SwiftUI | CRUD, all input/action choices, validation feedback, Chinese/English |
| Import/export/sync | Validated atomic files, backups, conflict handling | Round-trip, corrupt/unsupported file preserves old state, simultaneous sync edits |
| Reconnect/lifecycle | Wake and device refresh | Permission revocation, event-tap timeout, unplug/replug, clean pause/quit |
| Packaging | SwiftPM + macOS CI + app bundle | macOS compile/tests/archive then local launch and permissions |

## Remaining parity items requiring subsequent implementation or validation

- Free-form template shapes beyond directional sequences and gesture recorder. Live non-intercepting stroke overlay is implemented, awaiting hardware validation.
- Touch regions, rotate/force/edge gesture families; explicit Magic Mouse vs trackpad rule scopes.
- Native system-gesture conflict suppression/arbitration (capture alone is not suppression).
- Full BAB action and gesture catalogue comparison, app-picker ergonomics and login launch.
- Hardware verification on Intel/Apple Silicon and macOS versions; notarization/distribution later.

These remain in scope. No claim of one-to-one parity or a fully hardware-validated release
is made until these rows are closed with evidence.
