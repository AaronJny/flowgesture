import AppKit
import CoreGraphics
import FlowGestureCore
import Darwin

@MainActor
final class FullScreenRuleSmoke {
    private let model: AppModel
    private var observations: [NSObjectProtocol] = []
    private var entered = false
    private var done = false
    init(model: AppModel) { self.model = model }
    func start() {
        guard let window = NSApp.keyWindow else { fail("missing settings window"); return }
        window.collectionBehavior.insert(.fullScreenPrimary)
        model.book = RuleBook(rules: [Rule(name: "diagonal-fullscreen", trigger: .draw(DrawGestureTrigger(button: .right, directions: [.upRight])), actions: [.window(.toggleFullScreen)])])
        model.isEnabled = true
        model.publishConfiguration()
        observations.append(NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.entered = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.stroke() }
            }
        })
        observations.append(NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.entered, self.model.lastEvent == "diagonal-fullscreen" else { self.fail("fullscreen did not execute through the gesture rule"); return }
                self.done = true
                print("PASS: actual right-up diagonal gesture entered and exited native full screen")
                exit(0)
            }
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { if !self.done { self.fail("native fullscreen gesture transition timed out: \(self.model.actionError ?? "no action error")") } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.stroke() }
    }
    private func stroke() {
        guard let window = NSApp.keyWindow,
              let entries = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]],
              let bounds = entries.first?[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { fail("gesture window bounds unavailable"); return }
        let initial = CGPoint(x: frame.midX, y: frame.midY)
        let steps: [(CGEventType, Int)] = [(.rightMouseDown, 0), (.rightMouseDragged, 1), (.rightMouseDragged, 2), (.rightMouseDragged, 3), (.rightMouseDragged, 4), (.rightMouseUp, 4)]
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.03) {
                let point = CGPoint(x: initial.x + CGFloat(step.1 * 25), y: initial.y - CGFloat(step.1 * 25))
                guard let event = CGEvent(mouseEventSource: nil, mouseType: step.0, mouseCursorPosition: point, mouseButton: .right) else { self.fail("gesture event unavailable"); return }
                event.setIntegerValueField(.mouseEventClickState, value: 1)
                event.post(tap: .cghidEventTap)
            }
        }
    }
    private func fail(_ reason: String) { fputs("FAIL: \(reason)\n", stderr); exit(1) }
}
