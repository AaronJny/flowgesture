import AppKit
import CoreGraphics
import FlowGestureCore
import Darwin

/// Opt-in CI probe: exercises actual foreground rules through the event tap and
/// checks generated action events, text editing, and the usable pause control.
final class ForegroundRuleSmoke {
    private struct ActionEvent: Equatable, CustomStringConvertible {
        let type: CGEventType
        let keyCode: Int64
        var description: String { "\(type == .keyDown ? "keyDown" : "keyUp")(\(keyCode))" }
    }

    private static let sideOutputKey: CGKeyCode = 38
    private static let keyboardOutputKey: CGKeyCode = 37
    private static let stageTimeout: TimeInterval = 2
    private static let settleInterval: TimeInterval = 0.25
    private static let totalTimeout: TimeInterval = 15
    private let model: AppModel
    private var audit: CFMachPort?
    private var source: CFRunLoopSource?
    private var observedActions: [ActionEvent] = []
    private var actionEvents: Int { observedActions.count }
    private var auditDisabledReason: String?
    private var startedAt: TimeInterval = 0
    private var overallDeadline: TimeInterval = 0
    private var stage = "setup"
    private var stageStartedAt: TimeInterval = 0
    private var stageWait: ForegroundSmokeStageWait<ActionEvent>?
    private var stageTimer: Timer?
    // Both callers run on the main CFRunLoop, including inside event tracking.
    // Sample in place: dispatching this evidence would timestamp queue latency.
    private var observeStage: ((String) -> Void)?
    private var finished = false
    private var pointerDiagnostics = "no mouse event posted"
    init(model: AppModel) { self.model = model }

    @MainActor func start() {
        startedAt = ProcessInfo.processInfo.systemUptime
        stageStartedAt = startedAt
        overallDeadline = startedAt + Self.totalTimeout
        // A stalled main queue/run loop must not extend the overall time bound.
        // Normal failures still capture the fixture window on the main thread.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + max(0, overallDeadline - ProcessInfo.processInfo.systemUptime)) {
            fputs("FAIL: foreground rule smoke exceeded its 15s global deadline (independent watchdog)\n", stderr)
            _exit(1)
        }
        let output = Action.shortcut(KeyboardShortcut(keyCode: Self.sideOutputKey, modifiers: [.command, .option]))
        // Distinct fixture outputs prevent a late duplicate from the side-button
        // rule being mistaken for the keyboard rule's expected down/up pair.
        let keyboardOutput = Action.shortcut(KeyboardShortcut(keyCode: Self.keyboardOutputKey, modifiers: [.command, .option]))
        var book = RuleBook(rules: [
            Rule(name: "foreground-side", trigger: .mouseButton(MouseButtonTrigger(button: .forward)), actions: [output]),
            Rule(name: "foreground-key", trigger: .keyboard(KeyboardShortcut(keyCode: 40, modifiers: [.command, .option])), actions: [keyboardOutput]),
            Rule(name: "foreground-left", trigger: .mouseButton(MouseButtonTrigger(button: .left)), actions: [output]),
            Rule(name: "foreground-text", trigger: .keyboard(KeyboardShortcut(keyCode: 0)), actions: [output])
        ])
        book.excludedBundleIdentifiers = []
        model.book = book
        model.isEnabled = true
        model.publishConfiguration()
        NSApp.activate(ignoringOtherApps: true)
        let callback: CGEventTapCallBack = { _, type, event, context in
            if let context {
                let smoke = Unmanaged<ForegroundRuleSmoke>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    let reason = type == .tapDisabledByTimeout ? "timeout" : "user input"
                    smoke.auditDisabledReason = reason
                    print("INFO: foreground audit tap disabled: \(reason)")
                } else if (type == .keyDown || type == .keyUp),
                          event.getIntegerValueField(.eventSourceUserData) == EventEngine.syntheticTag {
                    let observed = ActionEvent(type: type, keyCode: event.getIntegerValueField(.keyboardEventKeycode))
                    smoke.observedActions.append(observed)
                    let now = ProcessInfo.processInfo.systemUptime
                    smoke.observeStage?("action audit")
                    print("INFO: foreground audit +\(ForegroundRuleSmoke.seconds(now - smoke.startedAt))s: \(observed); actionEvents=\(smoke.actionEvents), stage=\(smoke.stage)")
                }
            }
            return Unmanaged.passUnretained(event)
        }
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue | CGEventMask(1) << CGEventType.keyUp.rawValue
        guard let tap = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { fail("action audit unavailable"); return }
        audit = tap; self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, overallDeadline - ProcessInfo.processInfo.systemUptime)) {
            if !self.finished { self.fail("foreground rule test global deadline exceeded (\(Self.totalTimeout)s)") }
        }
        waitForStage("foreground readiness", expected: [], failure: "FlowGesture is not the actual active foreground app with a key settings window", condition: {
            self.model.engineRunning && NSApp.isActive && self.settingsWindow?.isKeyWindow == true &&
                NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
        }) {
            self.mouse(button: 4, x: 100, y: 100)
            self.checkSideAndKeyboard()
        }
    }
    @MainActor private func checkSideAndKeyboard() {
        waitForStage("side-button action", expected: Self.sideEvents, failure: "side-button rule did not execute while FlowGesture was foreground", condition: {
            self.actionEvents == 2 && self.model.lastEvent == "foreground-side"
        }) {
            if let window = NSApp.keyWindow { window.makeFirstResponder(window.contentView) }
            self.key(code: 40, flags: [.maskCommand, .maskAlternate])
            self.waitForStage("keyboard action", expected: Self.allEvents, failure: "keyboard rule did not execute while FlowGesture was foreground", condition: {
                self.actionEvents == 4 && self.model.lastEvent == "foreground-key"
            }) {
                self.checkEditing()
            }
        }
    }
    @MainActor private func checkEditing() {
        guard let window = NSApp.keyWindow, let content = window.contentView else { fail("no key settings window"); return }
        let field = NSTextField(frame: NSRect(x: 16, y: 16, width: 180, height: 24))
        content.addSubview(field)
        window.makeFirstResponder(field)
        key(code: 0, flags: [])
        waitForStage("text editing", expected: Self.allEvents, failure: "text input was stolen by a keyboard rule", condition: {
            field.stringValue == "a" && self.actionEvents == 4 && self.model.lastEvent == "foreground-key"
        }) {
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
        guard let marker, !marker.isHiddenOrHasHiddenAncestor else {
            fail("pause control geometry unavailable"); return
        }
        // A non-clipping SwiftUI host can report visibleRect outside this tiny
        // marker's bounds. Always target the control's own visible intersection.
        let targetRect = marker.bounds.intersection(marker.visibleRect)
        guard !targetRect.isNull, targetRect.width > 0, targetRect.height > 0 else {
            fail("pause control is clipped outside its own bounds"); return
        }
        let inWindow = marker.convert(NSPoint(x: targetRect.midX, y: targetRect.midY), to: nil)
        let nativePoint = window.convertPoint(toScreen: inWindow)
        let point = CGPoint(x: nativePoint.x, y: mainScreen.frame.maxY - nativePoint.y)
        pointerDiagnostics = "pause marker=\(marker.bounds), visible=\(marker.visibleRect), windowPoint=\(inWindow), HIDPoint=\(point), windowFrame=\(window.frame)"
        print("INFO: pause click: \(pointerDiagnostics)")
        guard root.bounds.contains(root.convert(inWindow, from: nil)) else { fail("pause point is outside settings content"); return }
        guard postMouse(type: .leftMouseDown, point: point, button: 0) else { return }
        // Give AppKit a distinct down/up pair rather than two same-turn posts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            guard self.postMouse(type: .leftMouseUp, point: point, button: 0) else { return }
            self.waitForStage("pause control", expected: Self.allEvents, failure: "left-button rule blocked the settings pause control or the control did not receive the click", condition: {
                !self.model.isEnabled && self.actionEvents == 4 && self.model.lastEvent == "foreground-key"
            }) {
                self.finished = true
                print("PASS: foreground side-button and keyboard mappings executed; text editing and pause-control clicks remained usable")
                exit(0)
            }
        }
    }

    private static var sideEvents: [ActionEvent] {
        [ActionEvent(type: .keyDown, keyCode: Int64(sideOutputKey)), ActionEvent(type: .keyUp, keyCode: Int64(sideOutputKey))]
    }

    private static var allEvents: [ActionEvent] {
        sideEvents + [ActionEvent(type: .keyDown, keyCode: Int64(keyboardOutputKey)), ActionEvent(type: .keyUp, keyCode: Int64(keyboardOutputKey))]
    }

    private static func seconds(_ interval: TimeInterval) -> String { String(format: "%.3f", interval) }

    @MainActor private var auditIsEnabled: Bool {
        guard let audit else { return false }
        return CGEvent.tapIsEnabled(tap: audit)
    }

    @MainActor private func waitForStage(_ name: String, expected: [ActionEvent], failure: String,
                                        condition: @escaping () -> Bool, completion: @escaping () -> Void) {
        guard !finished else { return }
        stageTimer?.invalidate()
        stage = name
        stageStartedAt = ProcessInfo.processInfo.systemUptime
        let deadline = min(stageStartedAt + Self.stageTimeout, overallDeadline)
        stageWait = ForegroundSmokeStageWait(expected: expected, deadline: deadline,
                                            overallDeadline: overallDeadline, settleInterval: Self.settleInterval)
        observeStage = { [weak self] source in
            guard let self else { return }
            let previousMatch = self.stageWait?.matchingSince
            let matches = condition()
            // Timestamp after reading the predicate; never infer earlier state
            // from an old event timestamp or the timer's scheduled fire date.
            let now = ProcessInfo.processInfo.systemUptime
            self.stageWait?.observe(events: self.observedActions, condition: matches, at: now)
            if let match = self.stageWait?.matchingSince, match != previousMatch {
                print("INFO: foreground stage=\(self.stage) first matched at +\(Self.seconds(match - self.startedAt))s via \(source)")
            }
        }
        print("INFO: foreground stage=\(name), deadline=+\(Self.seconds(deadline - startedAt))s, budget=\(Self.seconds(deadline - stageStartedAt))s, settle=\(Self.seconds(Self.settleInterval))s, expected=\(expected)")
        let poll: () -> Void = { [weak self] in self?.pollStage(failure: failure, completion: completion) }
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in poll() }
        stageTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        poll()
    }

    @MainActor private func pollStage(failure: String, completion: @escaping () -> Void) {
        guard !finished else { return }
        guard auditDisabledReason == nil, auditIsEnabled else { fail("action audit tap disabled during \(stage)"); return }
        observeStage?("run-loop poll")
        let now = ProcessInfo.processInfo.systemUptime
        guard let wait = stageWait else { fail("missing stage observation"); return }
        switch wait.result(at: now) {
        case .waiting: return
        case .invalidSequence:
            fail("\(failure) (unexpected synthetic key sequence; expected \(wait.expected))")
        case .stageDeadline:
            fail("\(failure) (stage deadline exceeded without timely settled evidence)")
        case .overallDeadline:
            fail("foreground rule test global deadline exceeded (\(Self.totalTimeout)s)")
        case .passed:
            print("INFO: foreground stage=\(stage) passed after \(Self.seconds(now - stageStartedAt))s; observedMatch=+\(Self.seconds((wait.matchingSince ?? now) - startedAt))s, actionEvents=\(actionEvents), sequence=\(observedActions)")
            stageTimer?.invalidate()
            stageTimer = nil
            observeStage = nil
            stageWait = nil
            completion()
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
        stageTimer?.invalidate()
        let now = ProcessInfo.processInfo.systemUptime
        let observedMatch = stageWait?.matchingSince.map { "+\(Self.seconds($0 - startedAt))s" } ?? "none"
        fputs("FAIL: \(reason); stage=\(stage), stageElapsed=\(Self.seconds(now - stageStartedAt))s, totalElapsed=\(Self.seconds(now - startedAt))s, observedMatch=\(observedMatch), enabled=\(model.isEnabled), engineRunning=\(model.engineRunning), actionEvents=\(actionEvents), sequence=\(observedActions), auditEnabled=\(auditIsEnabled), auditDisabledReason=\(auditDisabledReason ?? "none"), lastEvent=\(model.lastEvent), active=\(NSApp.isActive), keySettings=\(settingsWindow?.isKeyWindow == true); \(pointerDiagnostics)\n", stderr)
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

/// Timestamped observations, independent of when a polling callback is scheduled.
/// This helper is only used by the opt-in smoke test and its deterministic tests.
struct ForegroundSmokeStageWait<Event: Equatable> {
    enum Result: Equatable { case waiting, passed, invalidSequence, stageDeadline, overallDeadline }

    let expected: [Event]
    let deadline: TimeInterval
    let overallDeadline: TimeInterval
    let settleInterval: TimeInterval
    private(set) var matchingSince: TimeInterval?
    private var invalidSequence = false

    init(expected: [Event], deadline: TimeInterval, overallDeadline: TimeInterval, settleInterval: TimeInterval) {
        self.expected = expected
        self.deadline = deadline
        self.overallDeadline = overallDeadline
        self.settleInterval = settleInterval
    }

    mutating func observe(events: [Event], condition: Bool, at now: TimeInterval) {
        // Incomplete pairs can arrive over several run-loop turns, but duplicates,
        // wrong keys and out-of-order down/up events permanently invalidate a stage.
        guard !invalidSequence, events.count <= expected.count, expected.starts(with: events) else {
            invalidSequence = true
            matchingSince = nil
            return
        }
        if events == expected && condition {
            if matchingSince == nil { matchingSince = now }
        } else {
            matchingSince = nil
        }
    }

    func result(at now: TimeInterval) -> Result {
        // Evidence cannot extend the global limit, and extra events cannot be
        // excused because the expected pair happened to arrive earlier.
        guard now < overallDeadline else { return .overallDeadline }
        guard !invalidSequence else { return .invalidSequence }
        if let matchingSince, matchingSince + settleInterval <= deadline,
           now >= matchingSince + settleInterval { return .passed }
        // A late poll may accept a timely, settled observation above. A condition
        // first seen true by that late poll is never backdated to an earlier event.
        return now < deadline ? .waiting : .stageDeadline
    }
}
