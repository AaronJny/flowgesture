import AppKit
import CoreGraphics
import FlowGestureCore
import Darwin

/// Explicit CI-only integration exercise. Events contain arrow keys only and
/// carry a unique tag; no physical keystrokes or text are inspected or logged.
final class ShortcutCaptureSmoke {
    private let marker: Int64 = 0x464753484F5254
    private var observer: CFMachPort?
    private var source: CFRunLoopSource?
    private var recorder: ShortcutCaptureSession?
    private var leaked = 0
    private var index = 0
    private var finished = false
    private let combinations: [KeyboardShortcut] = ([ModifierKeys.command, .control, .option, .shift, [.command, .control, .option, .shift]]).flatMap { modifiers in
        [KeyboardShortcut(keyCode: 123, modifiers: modifiers), KeyboardShortcut(keyCode: 124, modifiers: modifiers)]
    }

    func start() {
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<ShortcutCaptureSmoke>.fromOpaque(context).takeUnretainedValue()
            if (type == .keyDown || type == .keyUp) && event.getIntegerValueField(.eventSourceUserData) == owner.marker {
                owner.leaked += 1
            }
            return Unmanaged.passUnretained(event)
        }
        guard let observer = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, observer, 0) else {
            fail("could not create downstream event observer"); return
        }
        self.observer = observer; self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: observer, enable: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { if !self.finished { self.fail("capture integration timeout") } }
        next()
    }
    private func next() {
        guard index < combinations.count else {
            finished = true
            guard leaked == 0 else { fail("captured arrow events reached downstream applications"); return }
            print("PASS: native shortcut tap captured Command/Control/Option/Shift + left/right and consumed every down/up pair")
            exit(0)
        }
        let expected = combinations[index]
        let capture = ShortcutCaptureSession()
        recorder = capture
        let started = capture.start(onCaptured: { value in
            guard value == expected else { self.fail("captured combination mismatch"); return }
            self.index += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.next() }
        }, onStatus: { status in print("Capture integration: \(status)") })
        guard started else { fail("native shortcut recorder could not start"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.post(expected, down: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.post(expected, down: false) }
        }
    }
    private func post(_ shortcut: KeyboardShortcut, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: down) else { fail("failed creating arrow event"); return }
        var flags: CGEventFlags = []
        if shortcut.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if shortcut.modifiers.contains(.control) { flags.insert(.maskControl) }
        if shortcut.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if shortcut.modifiers.contains(.shift) { flags.insert(.maskShift) }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.post(tap: .cghidEventTap)
    }
    private func fail(_ reason: String) { fputs("FAIL: \(reason)\n", stderr); exit(1) }
}
