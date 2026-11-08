import AppKit
import CoreGraphics
import FlowGestureCore
import Darwin

/// Explicit CI integration: operates only the app's own review window.
/// Clicks real buttons, records three synthetic shortcuts, and checks Save's value.
@MainActor
final class ShortcutCaptureUISmoke {
    let model: AppModel
    private let cases = [KeyboardShortcut(keyCode: 8, modifiers: .command), KeyboardShortcut(keyCode: 124, modifiers: .command), KeyboardShortcut(keyCode: 123, modifiers: .control)]
    private var index = 0
    private var done = false
    private var stage = "starting"
    private var pointerDiagnostics = "no mouse event posted"
    init(model: AppModel) { self.model = model }
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { if !self.done { self.fail("UI shortcut recording timed out") } }
        recordNext()
    }
    private func recordNext() {
        guard !done else { return }
        stage = "click Record"
        click(identifier: "flowgesture.shortcut.capture.start") {
            self.stage = "verify recording owner"
            guard self.model.activeShortcutRecorder != nil else { self.fail("record button did not begin capture"); return }
            let value = self.cases[self.index]
            self.stage = "post shortcut key-down"
            self.key(value, down: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                self.stage = "post shortcut key-up"
                self.key(value, down: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.stage = "verify key-up released owner"
                    guard self.model.activeShortcutRecorder == nil else { self.fail("capture did not release UI owner after key-up"); return }
                    self.stage = "await Save persistence"
                    self.click(identifier: "flowgesture.rule.save") {}
                }
            }
        }
    }
    func saved(_ rule: Rule) {
        guard !done else { return }
        guard stage == "await Save persistence", cases.indices.contains(index) else { fail("unexpected Save callback"); return }
        guard rule.actions.first == .shortcut(cases[index]) else { fail("Save did not receive the recorded shortcut: \(rule.actions)"); return }
        guard model.book.rules.contains(where: { $0.id == rule.id && $0.actions == rule.actions }) else { fail("Save did not persist recorded shortcut"); return }
        print("INFO: shortcut UI case=\(index + 1)/\(cases.count) persisted keyCode=\(cases[index].keyCode)")
        index += 1
        if index == cases.count {
            done = true
            print("PASS: actual Record button -> native shortcut callback -> UI state -> Save persisted Command+C, Command+Right and Control+Left")
            exit(0)
        }
        stage = "between recordings"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.recordNext() }
    }
    private var settingsWindow: NSWindow? {
        NSApp.windows.first(where: { $0.identifier?.rawValue == "FlowGesture.settings" })
    }
    private func click(identifier: String, completion: @escaping () -> Void) {
        pointerDiagnostics = "target=\(identifier); geometry not resolved"
        guard let window = settingsWindow, window.isVisible, !window.isMiniaturized,
              let root = window.contentView, let mainScreen = NSScreen.screens.first else {
            fail("no visible settings window for control click"); return
        }
        root.layoutSubtreeIfNeeded()
        var stack = [root]
        var markers: [NSView] = []
        while let view = stack.popLast() {
            if view.identifier?.rawValue == identifier, !view.isHiddenOrHasHiddenAncestor { markers.append(view) }
            stack.append(contentsOf: view.subviews)
        }
        guard markers.count == 1, let marker = markers.first else {
            fail("expected one visible control marker for \(identifier), found \(markers.count)"); return
        }
        // SwiftUI's non-clipping host may report visibleRect outside the marker.
        let targetRect = marker.bounds.intersection(marker.visibleRect)
        pointerDiagnostics = "target=\(identifier), bounds=\(marker.bounds), visible=\(marker.visibleRect), intersection=\(targetRect), windowFrame=\(window.frame), contentBounds=\(root.bounds), contentFrame=\(root.frame)"
        guard !targetRect.isNull, targetRect.width > 0, targetRect.height > 0 else {
            fail("control is clipped outside its own bounds"); return
        }
        let inWindow = marker.convert(NSPoint(x: targetRect.midX, y: targetRect.midY), to: nil)
        let nativePoint = window.convertPoint(toScreen: inWindow)
        let point = CGPoint(x: nativePoint.x, y: mainScreen.frame.maxY - nativePoint.y)
        pointerDiagnostics += ", windowPoint=\(inWindow), HIDPoint=\(point)"
        print("INFO: shortcut UI case=\(index + 1)/\(cases.count), stage=\(stage); \(pointerDiagnostics)")
        guard root.bounds.contains(root.convert(inWindow, from: nil)), window.frame.contains(nativePoint) else {
            fail("control point is outside settings content or window"); return
        }
        guard postMouse(type: .leftMouseDown, point: point) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            guard self.postMouse(type: .leftMouseUp, point: point) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard !self.done else { return }
                completion()
            }
        }
    }
    private func postMouse(type: CGEventType, point: CGPoint) -> Bool {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
            fail("cannot create test click"); return false
        }
        event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.flags = []
        event.post(tap: .cghidEventTap)
        return true
    }
    private func key(_ value: KeyboardShortcut, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: value.keyCode, keyDown: down) else { fail("cannot create test shortcut"); return }
        var flags: CGEventFlags = []
        if value.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if value.modifiers.contains(.control) { flags.insert(.maskControl) }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
    private func fail(_ reason: String) {
        guard !done else { return }
        done = true
        fputs("FAIL: \(reason); case=\(index + 1)/\(cases.count), stage=\(stage), recordingOwner=\(String(describing: model.activeShortcutRecorder)), active=\(NSApp.isActive), keySettings=\(settingsWindow?.isKeyWindow == true); \(pointerDiagnostics)\n", stderr)
        captureFailureWindow()
        exit(1)
    }
    private func captureFailureWindow() {
        // Capture only our settings fixture, never the desktop or another app.
        guard let window = settingsWindow, window.isVisible,
              let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            fputs("INFO: shortcut UI failure window capture unavailable\n", stderr); return
        }
        let url = URL(fileURLWithPath: "build/ui-review/shortcut-ui-smoke-failure.png")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url)
            fputs("INFO: captured settings fixture at \(url.path)\n", stderr)
        } catch {
            fputs("INFO: shortcut UI failure window capture write failed: \(error)\n", stderr)
        }
    }
}
