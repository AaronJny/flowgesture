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
    private var pointerDiagnostics = "no mouse event posted"
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
        if let window = NSApp.keyWindow { window.makeFirstResponder(window.contentView) }
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
            self.checkPauseControl()
        }
    }
    @MainActor private func checkPauseControl() {
        guard model.isEnabled, actionEvents == 4, model.configurationLoadError == nil else {
            fail("pause-control precondition failed"); return
        }
        guard let window = settingsWindow, window.isVisible, !window.isMiniaturized,
              let root = window.contentView, let mainScreen = NSScreen.screens.first else {
            fail("no visible settings window for pause click"); return
        }
        root.layoutSubtreeIfNeeded()
        var stack = [root]
        var marker: NSView?
        while let view = stack.popLast() {
            if view.identifier?.rawValue == "flowgesture.settings.pause" { marker = view; break }
            stack.append(contentsOf: view.subviews)
        }
        guard let marker, !marker.isHiddenOrHasHiddenAncestor,
              marker.visibleRect.width > 0, marker.visibleRect.height > 0 else {
            fail("pause control geometry unavailable"); return
        }
        let inWindow = marker.convert(NSPoint(x: marker.visibleRect.midX, y: marker.visibleRect.midY), to: nil)
        let nativePoint = window.convertPoint(toScreen: inWindow)
        let point = CGPoint(x: nativePoint.x, y: mainScreen.frame.maxY - nativePoint.y)
        pointerDiagnostics = "pause marker=\(marker.bounds), visible=\(marker.visibleRect), windowPoint=\(inWindow), HIDPoint=\(point), windowFrame=\(window.frame)"
        print("INFO: pause click: \(pointerDiagnostics)")
        guard root.bounds.contains(root.convert(inWindow, from: nil)) else { fail("pause point is outside settings content"); return }
        guard postMouse(type: .leftMouseDown, point: point, button: 0) else { return }
        // Give AppKit a distinct down/up pair rather than two same-turn posts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            guard self.postMouse(type: .leftMouseUp, point: point, button: 0) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard !self.model.isEnabled, self.actionEvents == 4 else {
                    self.fail("left-button rule blocked the settings pause control or the control did not receive the click"); return
                }
                self.finished = true
                print("PASS: foreground side-button and keyboard mappings executed; text editing and pause-control clicks remained usable")
                exit(0)
            }
        }
    }

    @MainActor private var settingsWindow: NSWindow? {
        NSApp.windows.first(where: { $0.identifier?.rawValue == "FlowGesture.settings" })
    }

    @MainActor private func mouse(button: Int64, x: CGFloat, y: CGFloat) {
        guard let window = settingsWindow,
              let records = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]],
              let bounds = records.first?[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { fail("window bounds unavailable"); return }
        let point = CGPoint(x: frame.minX + x, y: frame.minY + y)
        pointerDiagnostics = "button=\(button), HIDPoint=\(point), windowBounds=\(frame)"
        let types: [CGEventType] = button == 0 ? [.leftMouseDown, .leftMouseUp] : [.otherMouseDown, .otherMouseUp]
        for type in types {
            guard postMouse(type: type, point: point, button: button) else { return }
        }
    }

    @MainActor @discardableResult
    private func postMouse(type: CGEventType, point: CGPoint, button: Int64) -> Bool {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button == 0 ? .left : .center) else {
            fail("mouse event unavailable"); return false
        }
        event.setIntegerValueField(.mouseEventButtonNumber, value: button)
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.flags = []
        event.post(tap: .cghidEventTap)
        return true
    }
    @MainActor private func key(code: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { fail("key event unavailable"); return }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }
    @MainActor private func fail(_ reason: String) {
        guard !finished else { return }
        finished = true
        fputs("FAIL: \(reason); enabled=\(model.isEnabled), engineRunning=\(model.engineRunning), actionEvents=\(actionEvents), lastEvent=\(model.lastEvent), active=\(NSApp.isActive), keySettings=\(settingsWindow?.isKeyWindow == true); \(pointerDiagnostics)\n", stderr)
        captureFailureWindow()
        exit(1)
    }

    @MainActor private func captureFailureWindow() {
        // Capture only our fixture window, never the desktop or another app.
        guard let window = settingsWindow, window.isVisible,
              let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            fputs("INFO: foreground failure window capture unavailable\n", stderr); return
        }
        let url = URL(fileURLWithPath: "build/ui-review/foreground-smoke-failure.png")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url)
            fputs("INFO: captured settings fixture at \(url.path)\n", stderr)
        } catch {
            fputs("INFO: foreground failure window capture write failed: \(error)\n", stderr)
        }
    }
}
