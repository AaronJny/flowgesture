import Foundation

public enum ClickSequenceDecision: Equatable, Sendable {
    case ignored
    case deferred(deadline: Double)
    case deliver(count: Int)
}

/// Resolves the ambiguity between single, double and triple click rules. This
/// classifies counts only; the adapter owns event replay and the matching rule.
/// Use one resolver for one button/modifier/app context and cancel on any change.
public struct ClickSequenceResolver: Sendable {
    public private(set) var pendingCount: Int?
    public private(set) var deadline: Double?
    private var lastTimestamp: Double?
    private var highestSeenCount = 0
    private var sequenceDelivered = false

    public init() {}

    /// Call `advance(now:)` before evaluating a new click and from a deadline
    /// timer. Lower counts are withheld while a higher registered count is possible.
    /// Native count 1 starts a fresh sequence; duplicate counts >1 cannot fire twice.
    public mutating func evaluate(count: Int, maxRegisteredClickCount: Int, now: Double,
                                  interval: Double) -> ClickSequenceDecision {
        guard (1...3).contains(maxRegisteredClickCount), count > 0,
              now.isFinite, interval.isFinite, interval > 0,
              lastTimestamp.map({ now >= $0 }) ?? true else { return .ignored }
        // Without a multi-click binding every completed physical click is a single.
        if maxRegisteredClickCount == 1 {
            clearPending()
            lastTimestamp = now
            highestSeenCount = count
            sequenceDelivered = true
            return .deliver(count: 1)
        }
        guard count <= 3 else { return .ignored }
        let newDeadline = now + interval
        guard newDeadline.isFinite else { return .ignored }
        if count == 1 {
            clearPending()
            highestSeenCount = 0
            sequenceDelivered = false
        } else if sequenceDelivered || count <= highestSeenCount {
            return .ignored
        }
        lastTimestamp = now
        highestSeenCount = count
        if count >= maxRegisteredClickCount {
            clearPending()
            sequenceDelivered = true
            return .deliver(count: count)
        }
        pendingCount = count
        deadline = newDeadline
        return .deferred(deadline: newDeadline)
    }

    public mutating func evaluate(count: Int, hasHigherCount: Bool, now: Double,
                                  interval: Double) -> ClickSequenceDecision {
        guard (1...3).contains(count), !hasHigherCount || count < 3 else { return .ignored }
        return evaluate(count: count, maxRegisteredClickCount: hasHigherCount ? count + 1 : count,
                        now: now, interval: interval)
    }

    /// Emits at most once when the latest lower-count candidate expires.
    public mutating func advance(now: Double) -> Int? {
        guard now.isFinite, lastTimestamp.map({ now >= $0 }) ?? true else { return nil }
        lastTimestamp = now
        guard let count = pendingCount, let deadline, now >= deadline else { return nil }
        clearPending()
        sequenceDelivered = true
        return count
    }

    /// Discards rather than delivers a candidate (focus change, drag, stop, etc.).
    public mutating func cancel() {
        clearPending()
        lastTimestamp = nil
        highestSeenCount = 0
        sequenceDelivered = false
    }

    private mutating func clearPending() { pendingCount = nil; deadline = nil }
}
