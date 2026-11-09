import Foundation
import CoreFoundation
import CoreGraphics

/// Diagnostic evidence only. Never supplies a timestamp or predicate to the
/// smoke's pass/fail policy. Ordinary app launches allocate no trace recorder.
final class ForegroundSmokeTrace {
    static let inputTag: Int64 = 0x4647534D4F4B4531
    static let shared: ForegroundSmokeTrace? = CommandLine.arguments.contains("--foreground-rule-smoke") ? ForegroundSmokeTrace() : nil

    struct Entry: Equatable {
        let time: TimeInterval
        let detail: String
    }

    struct Snapshot {
        let startedAt: TimeInterval?
        let entries: [Entry]
        let dropped: Int
        let lastRunLoopBoundary: Entry?
    }

    private let lock = NSLock()
    private let capacity: Int
    private var startedAt: TimeInterval?
    private var entries: [Entry] = []
    private var dropped = 0
    private var previousRunLoopBoundary: Entry?

    init(capacity: Int = 256) { self.capacity = max(1, capacity) }

    func start(at now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        startedAt = now
        entries.removeAll(keepingCapacity: true)
        dropped = 0
        previousRunLoopBoundary = nil
    }

    func record(_ detail: String, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        guard startedAt != nil else { return }
        append(Entry(time: now, detail: detail))
    }

    /// Preserve the beginning of a stalled interval as well as its end. A gap
    /// after beforeWaiting can include idle/scheduling time; one after
    /// afterWaiting includes main-thread work. Neither alone proves its cause.
    func runLoopBoundary(_ boundary: String, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        guard let origin = startedAt else { return }
        if let previous = previousRunLoopBoundary, now - previous.time >= 0.1 {
            append(Entry(time: now, detail: "main-run-loop gap=\(Self.seconds(now - previous.time))s from=\(previous.detail) at=+\(Self.seconds(previous.time - origin))s to=\(boundary)"))
        }
        previousRunLoopBoundary = Entry(time: now, detail: boundary)
    }

    private func append(_ entry: Entry) {
        // Retain the earliest causal evidence. Explicit overflow prevents a
        // truncated trace from being mistaken for a complete timeline.
        guard entries.count < capacity else { dropped += 1; return }
        entries.append(entry)
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(startedAt: startedAt, entries: entries, dropped: dropped, lastRunLoopBoundary: previousRunLoopBoundary)
    }

    private func trySnapshot() -> Snapshot? {
        // Best-effort diagnostics skip a snapshot held by the main thread or
        // action worker. The independent exit callback never calls this code.
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        return Snapshot(startedAt: startedAt, entries: entries, dropped: dropped, lastRunLoopBoundary: previousRunLoopBoundary)
    }

    func dump(reason: String, ifAvailable: Bool = false) {
        let snapshot = ifAvailable ? trySnapshot() : self.snapshot()
        guard let snapshot, let origin = snapshot.startedAt else { return }
        var output = "INFO: foreground timing trace (\(reason)); entries=\(snapshot.entries.count), dropped=\(snapshot.dropped); diagnostic only, deadlines unchanged\n"
        for entry in snapshot.entries {
            output += "INFO: foreground trace +\(Self.seconds(entry.time - origin))s: \(entry.detail)\n"
        }
        if let boundary = snapshot.lastRunLoopBoundary {
            output += "INFO: foreground trace last main-run-loop boundary +\(Self.seconds(boundary.time - origin))s: \(boundary.detail)\n"
        }
        // No file/console I/O occurs inside an event-tap callback or the lock.
        fputs(output, stderr)
    }

    static func forEvent(_ event: CGEvent) -> ForegroundSmokeTrace? {
        guard let shared else { return nil }
        let tag = event.getIntegerValueField(.eventSourceUserData)
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        // Read back the system fields without rewriting them. A lost/rewritten
        // tag or PID means incomplete correlation, never permission to capture
        // untagged input or another FlowGesture instance's generic output tag.
        guard accepts(tag: tag, sourcePID: sourcePID) else { return nil }
        if tag == EventEngine.syntheticTag {
            guard event.type == .keyDown || event.type == .keyUp,
                  acceptsOutput(type: event.type, keyCode: event.getIntegerValueField(.keyboardEventKeycode)) else { return nil }
        }
        return shared
    }

    static func accepts(tag: Int64, sourcePID: Int64, currentPID: Int64 = Int64(ProcessInfo.processInfo.processIdentifier)) -> Bool {
        currentPID > 0 && sourcePID == currentPID && (tag == inputTag || tag == EventEngine.syntheticTag)
    }

    static func acceptsOutput(type: CGEventType, keyCode: Int64) -> Bool {
        (type == .keyDown || type == .keyUp) &&
            [Int64(ForegroundRuleSmoke.sideOutputKey), Int64(ForegroundRuleSmoke.keyboardOutputKey)].contains(keyCode)
    }

    static func describeSource(tag: Int64, sourcePID: Int64, currentPID: Int64 = Int64(ProcessInfo.processInfo.processIdentifier)) -> String {
        let classification: String
        switch tag {
        case inputTag: classification = "fixture-input-tag"
        case EventEngine.syntheticTag: classification = "engine-synthetic-tag"
        default: classification = "unknown/unconfirmed-tag"
        }
        let match = currentPID > 0 && sourcePID == currentPID
        // This is observed tag/process correlation, not physical provenance.
        return "observedTag=\(tag) tagClass=\(classification) observedSourcePID=\(sourcePID) sourceProcessMatch=\(match)"
    }

    static func forRule(_ name: String) -> ForegroundSmokeTrace? {
        guard let shared else { return nil }
        guard ["foreground-side", "foreground-key", "foreground-left", "foreground-text"].contains(name) else { return nil }
        return shared
    }

    static func describe(_ event: CGEvent) -> String {
        let isKey = event.type == .keyDown || event.type == .keyUp
        let number = event.getIntegerValueField(isKey ? .keyboardEventKeycode : .mouseEventButtonNumber)
        let tag = event.getIntegerValueField(.eventSourceUserData)
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        return "\(describeSource(tag: tag, sourcePID: sourcePID)) type=\(event.type.rawValue) \(isKey ? "key" : "button")=\(number) eventTimestamp=\(event.timestamp)"
    }

    private static func seconds(_ interval: TimeInterval) -> String { String(format: "%.6f", interval) }
}
