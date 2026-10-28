#if os(macOS)
import AppKit
import CoreGraphics
import Foundation

/// Minimal observer telemetry. A missing field means not applicable/unknown,
/// never a guessed device identity or a decoded private gesture payload.
struct GestureDiagnosticRecord: Codable, Equatable, Sendable {
    let receiptTime: TimeInterval
    var rawType: UInt32? = nil
    var scrollPhase: Int64? = nil
    var momentumPhase: Int64? = nil
    var senderID: UInt64? = nil
    var touchDeviceID: UInt64? = nil
    var contactCount: Int? = nil
    var cancelled: Bool? = nil
    var recognition: String? = nil
}

/// Fixed-capacity storage; overflowing discards the oldest record, not new input.
struct GestureDiagnosticBuffer {
    let capacity: Int
    private var storage: [GestureDiagnosticRecord?]
    private var next = 0
    private(set) var count = 0
    private(set) var dropped = 0

    init(capacity: Int = 512) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = Array(repeating: nil, count: capacity)
    }
    mutating func append(_ record: GestureDiagnosticRecord) {
        storage[next] = record
        next = (next + 1) % capacity
        if count < capacity { count += 1 } else { dropped += 1 }
    }
    func snapshot() -> [GestureDiagnosticRecord] {
        let first = count == capacity ? next : 0
        return (0..<count).compactMap { storage[(first + $0) % capacity] }
    }
}

struct GestureDiagnosticSnapshot: Codable, Sendable {
    let formatVersion: Int
    let isRunning: Bool
    let durationLimit: TimeInterval
    let capacity: Int
    let droppedRecords: Int
    let clock: String
    let interpretation: String
    let records: [GestureDiagnosticRecord]
}

/// Explicit, local, passive diagnostics. All public methods and callbacks run on
/// the main thread. Starting does not activate recognition, change preferences,
/// request privileges, consume events, write files, or create a network request.
final class GestureDiagnostics {
    var onStatus: ((String) -> Void)?
    private(set) var isRunning = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var deadlineTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var buffer = GestureDiagnosticBuffer()
    private var startedAt: TimeInterval = 0
    private var deadline: TimeInterval = 0
    private var durationLimit: TimeInterval = 0

    /// This is the public all-events mask minus known irrelevant public events.
    /// No undocumented event-type constants or event fields are interpreted.
    static var observationMask: CGEventMask {
        let excluded: [CGEventType] = [
            .null, .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .mouseMoved,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .tabletPointer, .tabletProximity
        ]
        return excluded.reduce(CGEventMask.max) { mask, type in
            mask & ~(CGEventMask(1) << type.rawValue)
        }
    }

    deinit { removeObserversAndTap() }

    func start(maxDuration: TimeInterval = 60) {
        precondition(Thread.isMainThread)
        guard !isRunning else {
            onStatus?("Gesture diagnostics are already recording / 手势诊断已在记录中")
            return
        }
        guard let requestedDuration = Self.validatedDuration(maxDuration) else {
            onStatus?("Diagnostic duration must be positive and finite / 诊断时长须为正的有限数")
            return
        }
        // Do not invoke a permission prompt or infer Input Monitoring access from
        // Accessibility. A user can review permissions outside this diagnostic.
        guard CGPreflightListenEventAccess() else {
            onStatus?("Input Monitoring access is required for passive diagnostics / 被动诊断需要输入监控权限")
            return
        }
        let callback: CGEventTapCallBack = { _, type, event, context in
            if let context {
                Unmanaged<GestureDiagnostics>.fromOpaque(context).takeUnretainedValue().observe(type, event: event)
            }
            // Listen-only ignores a disposition anyway; return the original on
            // every path to make the non-consuming intent explicit.
            return Unmanaged.passUnretained(event)
        }
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                             options: .listenOnly, eventsOfInterest: Self.observationMask,
                                             callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            onStatus?("Could not create a passive diagnostic tap; no capture started / 无法创建被动诊断监听，未开始采集")
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            CFMachPortInvalidate(newTap)
            onStatus?("Could not attach the diagnostic run loop / 无法连接诊断运行循环")
            return
        }
        // Failed starts preserve the previous trace. A successful explicit start
        // begins a new bounded session, without appending across unrelated runs.
        buffer = GestureDiagnosticBuffer()
        startedAt = ProcessInfo.processInfo.systemUptime
        durationLimit = requestedDuration
        deadline = startedAt + requestedDuration
        tap = newTap
        runLoopSource = source
        isRunning = true
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        installLifecycleObservers()
        let timer = Timer(timeInterval: min(0.25, requestedDuration), repeats: true) { [weak self] _ in
            guard let self, self.isRunning else { return }
            if !CGPreflightListenEventAccess() {
                self.finish("Input Monitoring access changed; diagnostic recording stopped / 输入监控权限已改变，诊断记录已停止")
            } else {
                _ = self.sessionReceiptTime()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        deadlineTimer = timer
        onStatus?("Passive diagnostics recording for up to \(requestedDuration) seconds; unknown types are observations only / 被动诊断最多记录 \(requestedDuration) 秒，未知类型仅作观测")
    }

    func stop() {
        precondition(Thread.isMainThread)
        guard isRunning else { return }
        finish("Gesture diagnostic recording stopped / 手势诊断记录已停止")
    }

    func recordTouchFrame(deviceID: UInt64, contacts: Int, cancelled: Bool) {
        precondition(Thread.isMainThread)
        guard let time = sessionReceiptTime(), (0...64).contains(contacts) else { return }
        buffer.append(GestureDiagnosticRecord(receiptTime: time, touchDeviceID: deviceID == 0 ? nil : deviceID,
                                               contactCount: contacts, cancelled: cancelled))
    }

    /// Accepts enum-derived names only, never user rule names, URLs, scripts,
    /// typed text, or arbitrary labels. Supported format is documented below.
    func recordRecognition(_ name: String) {
        precondition(Thread.isMainThread)
        guard let time = sessionReceiptTime(), Self.isAllowedRecognitionName(name) else { return }
        buffer.append(GestureDiagnosticRecord(receiptTime: time, recognition: name))
    }

    /// Returns bytes only. The caller owns explicit user-driven local export.
    func snapshotData() throws -> Data {
        precondition(Thread.isMainThread)
        if isRunning { _ = sessionReceiptTime() }
        let snapshot = GestureDiagnosticSnapshot(
            formatVersion: 1, isRunning: isRunning, durationLimit: durationLimit,
            capacity: buffer.capacity, droppedRecords: buffer.dropped,
            clock: "Monotonic receipt seconds since this diagnostic session began. Touch/recognition receipt is measured at the engine hook after main-queue delivery, not at hardware acquisition.",
            interpretation: "Unknown raw event types are observed numbers only, not verified gestures. Touch device IDs and Quartz sender IDs are separate namespaces. No claim of native gesture suppression or complete event visibility.",
            records: buffer.snapshot())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot)
    }

    static func validatedDuration(_ value: TimeInterval) -> TimeInterval? {
        guard value.isFinite, value > 0 else { return nil }
        return min(value, 60)
    }

    static func isAllowedRecognitionName(_ name: String) -> Bool {
        if name == "pinch.inward" || name == "pinch.outward" { return true }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let fingers = Int(parts[1]), (1...5).contains(fingers),
              String(fingers) == String(parts[1]) else { return false }
        if parts.count == 2 { return parts[0] == "tap" }
        guard parts.count == 3, parts[0] == "swipe" else { return false }
        return ["up", "down", "left", "right", "upLeft", "upRight", "downLeft", "downRight"].contains(String(parts[2]))
    }

    private func observe(_ type: CGEventType, event: CGEvent) {
        precondition(Thread.isMainThread)
        guard isRunning else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            finish("The system disabled the diagnostic tap; recording stopped / 系统停用了诊断监听，记录已停止")
            return
        }
        guard let time = sessionReceiptTime() else { return }
        // The mask is not treated as a sufficient privacy boundary: defensively
        // reject excluded public types again if a runtime ever delivers one.
        guard type.rawValue < 64,
              (Self.observationMask & (CGEventMask(1) << type.rawValue)) != 0 else { return }
        var record = GestureDiagnosticRecord(receiptTime: time, rawType: type.rawValue)
        if type == .scrollWheel {
            record.scrollPhase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
            record.momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
            record.senderID = EventDeviceIdentity.senderID(for: event)
        }
        // Unknown types get only type+receiptTime. No NSEvent conversion, private
        // fields, sender introspection, coordinates, deltas, or flags are read.
        buffer.append(record)
    }

    /// Stops before recording an event outside the requested duration, even when
    /// a busy main loop delays its timer. This is observer time, not device time.
    private func sessionReceiptTime() -> TimeInterval? {
        guard isRunning else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        guard now < deadline else {
            finish("Diagnostic time limit reached; recording stopped / 已达到诊断时限，记录已停止")
            return nil
        }
        return max(0, now - startedAt)
    }
    private func finish(_ message: String) {
        isRunning = false
        removeObserversAndTap()
        onStatus?(message)
    }
    private func installLifecycleObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.isRunning else { return }
                self.finish("Session interrupted; diagnostic recording stopped / 会话中断，诊断记录已停止")
            })
        }
    }
    private func removeObserversAndTap() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        tap = nil
    }
}
#endif
