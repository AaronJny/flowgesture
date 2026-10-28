import Foundation

/// Cancellation is cooperative between actions. It does not interrupt an action
/// already running (in particular NSAppleScript or an OS application launch).
public final class ActionExecutionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    public init() {}
    public func snapshot() -> UInt64 { lock.lock(); defer { lock.unlock() }; return generation }
    public func isCurrent(_ token: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return token == generation }
    public func cancelPending() { lock.lock(); generation &+= 1; lock.unlock() }
}
