#if os(macOS)
import AppKit
import ApplicationServices
import FlowGestureCore

enum ShortcutCaptureDecision: Equatable {
    case passThrough
    case swallow
    case captured(FlowGestureCore.KeyboardShortcut)
    case cancelled
}

/// Key-pair policy, independent of tap creation so it can be tested with in-memory
/// CGEvents. Only the first completed, non-repeated key is captured.
struct ShortcutCapturePolicy {
    private(set) var isRecording = false
    private(set) var pendingKeyCode: UInt16?
    private var candidate: FlowGestureCore.KeyboardShortcut?
    var isDraining: Bool { !isRecording && pendingKeyCode != nil }

    mutating func begin() {
        isRecording = true
        pendingKeyCode = nil
        candidate = nil
    }
    /// After a swallowed down, cancellation only drains its matching up; it does
    /// not capture any new key or publish the cancelled candidate.
    mutating func cancel() {
        isRecording = false
        candidate = nil
    }
    mutating func reset() {
        isRecording = false
        pendingKeyCode = nil
        candidate = nil
    }

    mutating func handle(type: CGEventType, event: CGEvent) -> ShortcutCaptureDecision {
        guard type == .keyDown || type == .keyUp else { return .passThrough }
        let rawCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard (0...Int64(UInt16.max)).contains(rawCode) else { return .passThrough }
        let keyCode = UInt16(rawCode)
        if let pendingKeyCode {
            guard keyCode == pendingKeyCode else { return .passThrough }
            if type == .keyDown { return .swallow }
            let captured = candidate
            reset()
            return captured.map(ShortcutCaptureDecision.captured) ?? .cancelled
        }
        guard isRecording, type == .keyDown,
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return .passThrough }
        pendingKeyCode = keyCode
        if keyCode == 53 {
            // Escape cancels without leaking its up into a sheet's Cancel action.
            isRecording = false
            candidate = nil
        } else {
            candidate = FlowGestureCore.KeyboardShortcut(keyCode: keyCode, modifiers: Self.modifiers(event.flags))
        }
        return .swallow
    }

    private static func modifiers(_ flags: CGEventFlags) -> ModifierKeys {
        var result: ModifierKeys = []
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskSecondaryFn) { result.insert(.function) }
        return result
    }
}

/// Main-thread-only, explicit recording session. It does not post keys, inspect
/// Unicode text, or log captured input. HID-head interception is attempted first;
/// macOS may still reserve some shortcuts outside this tap's control.
final class ShortcutCaptureSession {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var policy = ShortcutCapturePolicy()
    private var timeout: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var capturedCallback: ((FlowGestureCore.KeyboardShortcut) -> Void)?
    private var statusCallback: ((String) -> Void)?
    private var finishedCallback: (() -> Void)?
    private var generation: UInt64 = 0
    var isRecording: Bool { policy.isRecording }

    @discardableResult
    func start(onCaptured: @escaping (FlowGestureCore.KeyboardShortcut) -> Void,
               onStatus: ((String) -> Void)? = nil, onFinished: (() -> Void)? = nil) -> Bool {
        assert(Thread.isMainThread)
        guard tap == nil else {
            onStatus?("Release the previous key or cancel recording first. / 请先松开上一个按键或取消录制。")
            return false
        }
        guard AXIsProcessTrusted() else {
            onStatus?("Shortcut recording needs Accessibility permission. / 录制快捷键需要辅助功能权限。")
            onFinished?()
            return false
        }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<ShortcutCaptureSession>.fromOpaque(context).takeUnretainedValue().receive(type, event)
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        var usedHID = true
        var created = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: callback, userInfo: context)
        if created == nil {
            usedHID = false
            created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: callback, userInfo: context)
        }
        guard let created, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) else {
            if let created { CFMachPortInvalidate(created) }
            onStatus?("Cannot start shortcut capture. Check Accessibility and Input Monitoring permissions. / 无法启动录制，请检查辅助功能与输入监控权限。")
            onFinished?()
            return false
        }
        generation &+= 1
        tap = created
        self.source = source
        capturedCallback = onCaptured
        statusCallback = onStatus
        finishedCallback = onFinished
        policy.begin()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        observe(NotificationCenter.default, NSApplication.didResignActiveNotification)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification)
        timeout = Timer(timeInterval: 15, repeats: false) { [weak self] _ in
            self?.cancel(message: "Recording timed out. / 录制已超时。")
        }
        if let timeout { RunLoop.main.add(timeout, forMode: .common) }
        onStatus?(usedHID
            ? "Press a shortcut, then release its key. Escape cancels. System-reserved keys may vary by macOS. / 按下快捷键后松开；Esc取消。系统保留组合键受macOS限制。"
            : "Recording with session fallback; some system shortcuts may not be intercepted. Escape cancels. / 正使用会话级录制，部分系统快捷键可能无法拦截；Esc取消。")
        return true
    }

    /// Call from view disappearance or recorder-token replacement as well as Cancel.
    func cancel() {
        assert(Thread.isMainThread)
        cancel(message: "Recording cancelled. / 已取消录制。")
    }

    private func cancel(message: String) {
        guard tap != nil else { return }
        capturedCallback = nil
        policy.cancel()
        timeout?.invalidate()
        statusCallback?(message)
        if policy.isDraining {
            // Keep only the matching-up filter briefly, never capture more keys.
            // Strong retention keeps the callback context alive if the view vanishes.
            timeout = Timer(timeInterval: 2, repeats: false) { [self] _ in finish(captured: nil) }
            if let timeout { RunLoop.main.add(timeout, forMode: .common) }
        } else { finish(captured: nil) }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.cancel() }
        observers.append((center, token))
    }

    private func receive(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            statusCallback?("Shortcut capture was interrupted; try recording again. / 快捷键录制被中断，请重试。")
            capturedCallback = nil
            finish(captured: nil)
            return Unmanaged.passUnretained(event)
        }
        switch policy.handle(type: type, event: event) {
        case .passThrough: return Unmanaged.passUnretained(event)
        case .swallow: return nil
        case .captured(let shortcut):
            scheduleFinish(captured: shortcut)
            return nil
        case .cancelled:
            scheduleFinish(captured: nil)
            return nil
        }
    }

    private func scheduleFinish(captured: FlowGestureCore.KeyboardShortcut?) {
        let token = generation
        // Return nil for the captured key-up before invoking UI completion.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token, self.tap != nil else { return }
            self.finish(captured: captured)
        }
    }

    private func finish(captured: FlowGestureCore.KeyboardShortcut?) {
        let capture = capturedCallback
        let finished = finishedCallback
        tearDown()
        if let captured { capture?(captured) }
        finished?()
    }

    private func tearDown() {
        generation &+= 1
        timeout?.invalidate(); timeout = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil; tap = nil
        policy.reset()
        capturedCallback = nil; statusCallback = nil; finishedCallback = nil
    }

    deinit { tearDown() }
}
#endif
