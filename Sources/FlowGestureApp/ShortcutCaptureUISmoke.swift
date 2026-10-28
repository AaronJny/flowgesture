import AppKit
import CoreGraphics
import FlowGestureCore
import Darwin

/// Explicit CI integration: operates only the app's own fixed-size review window.
/// Clicks real buttons, records three synthetic shortcuts, and checks Save's value.
@MainActor
final class ShortcutCaptureUISmoke {
    let model: AppModel
    private let cases = [KeyboardShortcut(keyCode: 8, modifiers: .command), KeyboardShortcut(keyCode: 124, modifiers: .command), KeyboardShortcut(keyCode: 123, modifiers: .control)]
    private var index = 0
    private var done = false
    init(model: AppModel) { self.model = model }
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { if !self.done { self.fail("UI shortcut recording timed out") } }
        recordNext()
    }
    private func recordNext() {
        click(x: 600, y: 388)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard self.model.activeShortcutRecorder != nil else { self.fail("record button did not begin capture"); return }
            let value = self.cases[self.index]
            self.key(value, down: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.key(value, down: false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard self.model.activeShortcutRecorder == nil else { self.fail("capture did not release UI owner after key-up"); return }
                self.click(x: 930, y: 742)
            }
        }
    }
    func saved(_ rule: Rule) {
        guard rule.actions.first == .shortcut(cases[index]) else { fail("Save did not receive the recorded shortcut"); return }
        guard model.book.rules.contains(where: { $0.id == rule.id && $0.actions == rule.actions }) else { fail("Save did not persist recorded shortcut"); return }
        index += 1
        if index == cases.count {
            done = true
            print("PASS: actual Record button -> native shortcut callback -> UI state -> Save persisted Command+C, Command+Right and Control+Left")
            exit(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.recordNext() }
    }
    private func click(x: CGFloat, y: CGFloat) {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "FlowGesture.settings" }),
              let entries = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]],
              let bounds = entries.first?[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { fail("test window bounds unavailable"); return }
        let point = CGPoint(x: frame.minX + x, y: frame.minY + y)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { fail("cannot create test click"); return }
            event.post(tap: .cghidEventTap)
        }
    }
    private func key(_ value: KeyboardShortcut, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: value.keyCode, keyDown: down) else { fail("cannot create test shortcut"); return }
        var flags: CGEventFlags = []
        if value.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if value.modifiers.contains(.control) { flags.insert(.maskControl) }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
    private func fail(_ text: String) { fputs("FAIL: \(text)\n", stderr); exit(1) }
}
