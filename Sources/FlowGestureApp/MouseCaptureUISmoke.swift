import AppKit
import ApplicationServices
import CoreGraphics
import FlowGestureCore
import Darwin

/// Opt-in CI check operating exclusively on FlowGesture's own review window.
/// The fixture is supplied by the caller for click, directional-draw, or shape.
/// No foreign app contents, names, or input are inspected or logged.
@MainActor
final class MouseCaptureUISmoke {
    private let model: AppModel
    private let originalRule: Rule
    private var done = false
    private var awaitingSave = false

    init(model: AppModel, originalRule: Rule) {
        self.model = model
        self.originalRule = originalRule
    }

    func start() {
        guard AXIsProcessTrusted() else { fail("Mouse capture UI smoke requires Accessibility permission"); return }
        guard expectedRule() != nil else { fail("Fixture must use a mouse, draw, or shape trigger"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            if !self.done { self.fail("Mouse capture UI smoke timed out") }
        }
        // Exercise Cancel through the same real button, then record for real.
        click(identifier: "flowgesture.mouse.capture.start") {
            self.after(0.2) {
                guard self.model.activeShortcutRecorder != nil else { self.fail("Record button did not begin mouse capture"); return }
                self.click(identifier: "flowgesture.mouse.capture.start") {
                    self.after(0.2) {
                        guard self.model.activeShortcutRecorder == nil else { self.fail("Cancel did not release capture ownership"); return }
                        self.beginActualCapture()
                    }
                }
            }
        }
    }

    private func beginActualCapture() {
        click(identifier: "flowgesture.mouse.capture.start") {
            self.after(0.2) {
                guard self.model.activeShortcutRecorder != nil else { self.fail("Repeated Record did not start a fresh capture"); return }
                guard let point = self.captureSurfaceCenter() else { self.fail("Actual mouse capture NSView was not visible"); return }
                guard self.postMouse(type: .otherMouseDown, point: point, button: 3) else { return }
                self.after(0.08) {
                    guard self.model.activeShortcutRecorder != nil else { self.fail("Mouse capture ended on down instead of preserving the matching up"); return }
                    guard self.postMouse(type: .otherMouseUp, point: point, button: 3) else { return }
                    self.after(0.25) {
                        guard self.model.activeShortcutRecorder == nil else { self.fail("Mouse capture did not finish on matching up"); return }
                        self.awaitingSave = true
                        self.click(identifier: "flowgesture.rule.save") {}
                    }
                }
            }
        }
    }

    /// The production Save closure calls this after model.saveRule succeeds.
    func saved(_ rule: Rule) {
        guard !done else { return }
        guard awaitingSave else { fail("Save occurred before mouse recording completed"); return }
        guard let expected = expectedRule(), rule == expected else {
            fail("Saved rule did not change only the mouse button; trigger payload or modifiers were altered")
            return
        }
        guard model.book.rules.contains(where: { $0 == expected }) else { fail("Save did not persist the recorded mouse button"); return }
        do {
            let data = try Data(contentsOf: model.configurationURL)
            let persisted = try JSONDecoder().decode(RuleBook.self, from: data)
            guard persisted.rules.contains(where: { $0 == expected }) else { fail("On-disk configuration did not retain the recorded trigger payload"); return }
            let roundTrip = try JSONDecoder().decode(RuleBook.self, from: JSONEncoder().encode(persisted))
            guard roundTrip == persisted else { fail("Recorded rule failed its Codable round trip"); return }
        } catch { fail("Could not verify mouse-rule persistence and Codable round trip"); return }
        done = true
        let kind: String
        switch rule.trigger {
        case .mouseButton: kind = "click"
        case .draw: kind = "draw"
        case .shape: kind = "shape"
        default: kind = "unexpected"
        }
        print("PASS: actual \(kind) Record -> Cancel -> Record -> paired button-4 down/up -> Save persisted all original trigger fields except the button, including Codable round trip")
        exit(0)
    }

    private func expectedRule() -> Rule? {
        var expected = originalRule
        switch expected.trigger {
        case .mouseButton(var trigger): trigger.button = .back; expected.trigger = .mouseButton(trigger)
        case .draw(var trigger): trigger.button = .back; expected.trigger = .draw(trigger)
        case .shape(var trigger): trigger.button = .back; expected.trigger = .shape(trigger)
        default: return nil
        }
        return expected
    }

    private func after(_ interval: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { if !self.done { work() } }
    }

    private func click(identifier: String, completion: @escaping @MainActor () -> Void) {
        let pid = getpid()
        // AX requests to this process must not block its main event loop.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.accessibilityCenter(identifier: identifier, pid: pid)
            DispatchQueue.main.async {
                guard !self.done else { return }
                guard let point = result.point else { self.fail(result.error ?? "AX control could not be located"); return }
                guard self.postMouse(type: .leftMouseDown, point: point, button: 0) else { return }
                self.after(0.04) {
                    guard self.postMouse(type: .leftMouseUp, point: point, button: 0) else { return }
                    completion()
                }
            }
        }
    }

    private func captureSurfaceCenter() -> CGPoint? {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.identifier?.rawValue == "FlowGesture.settings" }),
              window.isVisible, !window.isMiniaturized, let root = window.contentView else { return nil }
        var stack = [root]
        while let view = stack.popLast() {
            if view is MouseButtonCaptureSurface.CaptureView, !view.isHiddenOrHasHiddenAncestor,
               view.bounds.width > 0, view.bounds.height > 0 {
                let inWindow = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                let screen = window.convertPoint(toScreen: inWindow)
                guard let mainScreen = NSScreen.screens.first else { return nil }
                return CGPoint(x: screen.x, y: mainScreen.frame.maxY - screen.y)
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    @discardableResult
    private func postMouse(type: CGEventType, point: CGPoint, button: Int64) -> Bool {
        let base: CGMouseButton = button == 0 ? .left : .center
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: base) else {
            fail("Could not create the CI mouse event"); return false
        }
        event.setIntegerValueField(.mouseEventButtonNumber, value: button)
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.flags = []
        event.post(tap: .cghidEventTap)
        return true
    }

    private func fail(_ message: String) {
        guard !done else { return }
        done = true
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }

    nonisolated private static func accessibilityCenter(identifier: String, pid: pid_t) -> MouseCaptureAXResult {
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, 1.0)
        // Query only windows: traversing the application's AXChildren also walks
        // its menu bar, whose self-process NSMenu bridge can assert off-main.
        guard let windows = attribute(app, kAXWindowsAttribute as CFString) as? [AXUIElement], !windows.isEmpty else {
            return MouseCaptureAXResult(point: nil, error: "Own-app AX windows are unavailable")
        }
        var stack = windows
        var inspected = 0
        while let element = stack.popLast(), inspected < 4_000 {
            inspected += 1
            if attribute(element, "AXIdentifier" as CFString) as? String == identifier {
                if let enabled = attribute(element, kAXEnabledAttribute as CFString) as? Bool, !enabled {
                    return MouseCaptureAXResult(point: nil, error: "Target UI control is disabled: \(identifier)")
                }
                if let position = attribute(element, kAXPositionAttribute as CFString),
                   let size = attribute(element, kAXSizeAttribute as CFString),
                   CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
                    var origin = CGPoint.zero
                    var dimensions = CGSize.zero
                    let positionValue = unsafeBitCast(position, to: AXValue.self)
                    let sizeValue = unsafeBitCast(size, to: AXValue.self)
                    if AXValueGetValue(positionValue, .cgPoint, &origin), AXValueGetValue(sizeValue, .cgSize, &dimensions),
                       dimensions.width > 0, dimensions.height > 0 {
                        return MouseCaptureAXResult(point: CGPoint(x: origin.x + dimensions.width / 2, y: origin.y + dimensions.height / 2), error: nil)
                    }
                }
            }
            if let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] { stack.append(contentsOf: children) }
        }
        return MouseCaptureAXResult(point: nil, error: "Own-app AX identifier not found: \(identifier)")
    }

    nonisolated private static func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name, &value) == .success ? value : nil
    }
}

private struct MouseCaptureAXResult: Sendable {
    let point: CGPoint?
    let error: String?
}
