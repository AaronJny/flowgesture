import Foundation
import XCTest
@testable import FlowGestureCapture

final class CaptureSessionGateTests: XCTestCase {
    private func snapshot(locked: Any? = false) -> CaptureSessionSnapshot {
        CaptureSessionSnapshot(onConsole: true, loginComplete: true, screenLocked: locked)
    }

    func testAlreadyLockedSessionIsRejectedDespiteConsoleAndLoginFlags() {
        XCTAssertEqual(snapshot(locked: true).failure, .screenLocked)
        XCTAssertNil(snapshot().failure)
    }

    func testMissingAndMalformedFieldsFailClosed() {
        XCTAssertEqual(snapshot(locked: nil).failure, .sessionStateUnknown)
        let malformedValues: [Any] = ["false", 0, 1, NSNull()]
        for malformed in malformedValues {
            XCTAssertEqual(snapshot(locked: malformed).failure, .sessionStateUnknown)
        }
        XCTAssertEqual(CaptureSessionSnapshot(onConsole: nil, loginComplete: true, screenLocked: false).failure, .sessionStateUnknown)
        XCTAssertEqual(CaptureSessionSnapshot(onConsole: true, loginComplete: nil, screenLocked: false).failure, .sessionStateUnknown)
        XCTAssertEqual(CaptureSessionSnapshot(onConsole: false, loginComplete: true, screenLocked: false).failure, .inactiveSession)
    }

    func testLockDuringObserverRegistrationCannotUseEarlierUnlockedSnapshot() {
        var current = snapshot()
        var order: [String] = []
        let failure = CaptureSessionGate.afterInstallingObservers(install: {
            order.append("register")
            current = snapshot(locked: true)
        }, read: {
            order.append("read")
            return current
        }, interrupted: { false })
        XCTAssertEqual(order, ["register", "read"])
        XCTAssertEqual(failure, .screenLocked)
    }

    func testStartupCheckpointRereadsStateAndInterruptionIsSticky() {
        var current = snapshot()
        var interrupted = false
        let read = { current }
        XCTAssertNil(CaptureSessionGate.failure(read: read, interrupted: { interrupted }))
        current = snapshot(locked: true)
        XCTAssertEqual(CaptureSessionGate.failure(read: read, interrupted: { interrupted }), .screenLocked)
        current = snapshot()
        interrupted = true
        XCTAssertEqual(CaptureSessionGate.failure(read: read, interrupted: { interrupted }), .sessionLost)
    }

    func testInterruptionWhileReadingStatePreventsCaptureStart() {
        var interrupted = false
        let failure = CaptureSessionGate.failure(read: {
            interrupted = true
            return snapshot()
        }, interrupted: { interrupted })
        XCTAssertEqual(failure, .sessionLost)
    }
}
