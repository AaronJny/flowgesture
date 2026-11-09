import CoreFoundation
import Foundation

/// No truthy numeric/string coercion: Apple publishes these values as
/// CFBoolean/OSBoolean. A missing or malformed lock flag is unknown, not unlocked.
struct CaptureSessionSnapshot: Equatable {
    let onConsole: Bool?
    let loginComplete: Bool?
    let screenLocked: Bool?

    init(onConsole: Any?, loginComplete: Any?, screenLocked: Any?) {
        self.onConsole = Self.strictBoolean(onConsole)
        self.loginComplete = Self.strictBoolean(loginComplete)
        self.screenLocked = Self.strictBoolean(screenLocked)
    }

    private static func strictBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    var failure: CaptureStore.StopReason? {
        guard let onConsole, let loginComplete, let screenLocked else { return .sessionStateUnknown }
        if screenLocked { return .screenLocked }
        return onConsole && loginComplete ? nil : .inactiveSession
    }
}

/// Registration precedes the first fresh state read. Every startup checkpoint
/// rereads state; any recorded interruption is sticky even if a later read is safe.
enum CaptureSessionGate {
    static func afterInstallingObservers(install: () -> Void, read: () -> CaptureSessionSnapshot,
                                        interrupted: () -> Bool) -> CaptureStore.StopReason? {
        install()
        return failure(read: read, interrupted: interrupted)
    }

    static func failure(read: () -> CaptureSessionSnapshot, interrupted: () -> Bool) -> CaptureStore.StopReason? {
        if interrupted() { return .sessionLost }
        let snapshot = read()
        if interrupted() { return .sessionLost }
        return snapshot.failure
    }
}
