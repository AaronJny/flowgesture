import AppKit
import CoreGraphics
import FlowGestureCore
import Darwin

/// Opt-in CI probe: exercises actual foreground rules through the event tap and
/// checks generated action events, text editing, and the usable pause control.
final class ForegroundRuleSmoke {
    private let model: AppModel
    private var audit: CFMachPort?
    private var source: CFRunLoopSource?
    private var actionEvents = 0
    private var finished = false
    init(model: AppModel) { self.model = model }

    @MainActor func start() {
        let output = Action.shortcut(KeyboardShortcut(keyCode: 38, modifiers: [.command, .option]))
        var book = RuleBook(rules: [
            Rule(name: "foreground-side", trigger: .mouseButton(MouseButtonTrigger(button: .forward)), actions: [output]),
            Rule(name: "foreground-key", trigger: .keyboard(KeyboardShortcut(keyCode: 40, modifiers: [.command, .option])), actions: [output]),
            Rule(name: "foreground-left", trigger: .mouseButton(MouseButtonTrigger(button: .left)), actions: [output]),
            Rule(name: "foreground-text", trigger: .keyboard(KeyboardShortcut(keyCode: 0)), actions: [output])
        ])
        book.excludedBundleIdentifiers = []
        model.book = book
        model.isEnabled = true
        model.publishConfiguration()
        NSApp.activate(ignoringOtherApps: true)
        let callback: CGEventTapCallBack = { _, type, event, context in
            if let context, (type == .keyDown || type == .keyUp),
               event.getIntegerValueField(.eventSourceUserData) == EventEngine.syntheticTag,
               event.getIntegerValueField(.keyboardEventKeycode) == 38 {
                Unmanaged<ForegroundRuleSmoke>.fromOpaque(context).takeUnretainedValue().actionEvents += 1
            }
            return Unmanaged.passUnretained(event)
        }
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue | CGEventMask(1) << CGEventType.keyUp.rawValue
        guard let tap = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { fail("action audit unavailable"); return }
        audit = tap; self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { if !self.finished { self.fail("foreground rule test timeout") } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard self.model.engineRunning, NSApp.isActive,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() else { self.fail("FlowGesture is not the actual active foreground app"); return }
            self.mouse(button: 4, x: 100, y: 100)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.checkSideAndKeyboard() }
        }
    }
    @MainActor private func checkSideAndKeyboard() {
        guard actionEvents == 2, model.lastEvent == "foreground-side" else { fail("side-button rule did not execute while FlowGesture was foreground"); return }
        key(code: 40, flags: [.maskCommand, .maskAlternate])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard self.actionEvents == 4, self.model.lastEvent == "foreground-key" else { self.fail("keyboard rule did not execute while FlowGesture was foreground"); return }
            self.checkEditing()
        }
    }
    @MainActor private func checkEditing() {
        guard let window = NSApp.keyWindow, let content = window.contentView else { fail("no key settings window"); return }
        let field = NSTextField(frame: NSRect(x: 16, y: 16, width: 180, height: 24))
        content.addSubview(field)
        window.makeFirstResponder(field)
        key(code: 0, flags: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard field.stringValue == "a", self.actionEvents == 4 else { self.fail("text input was stolen by a keyboard rule"); return }
            window.makeFirstResponder(content)
            field.removeFromSuperview()
            self.mouse(button: 0, x: 150, y: 720)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard !self.model.isEnabled, self.actionEvents == 4 else { self.fail("left-button rule blocked the settings pause control"); return }
                self.finished = true
                print("PASS: foreground side-button and keyboard mappings executed; text editing and pause-control clicks remained usable")
                exit(0)
            }
        }
    }
    @MainActor private func mouse(button: Int64, x: CGFloat, y: CGFloat) {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "FlowGesture.settings" }),
              let records = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]],
              let bounds = records.first?[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { fail("window bounds unavailable"); return }
        let point = CGPoint(x: frame.minX + x, y: frame.minY + y)
        let types: [CGEventType] = button == 0 ? [.leftMouseDown, .leftMouseUp] : [.otherMouseDown, .otherMouseUp]
        for type in types {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button == 0 ? .left : .center) else { fail("mouse event unavailable"); return }
            event.setIntegerValueField(.mouseEventButtonNumber, value: button)
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: .cghidEventTap)
        }
    }
    private func key(code: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { fail("key event unavailable"); return }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }
    private func fail(_ reason: String) { fputs("FAIL: \(reason)\n", stderr); exit(1) }
}
