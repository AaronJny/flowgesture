import XCTest
@testable import FlowGestureCore

final class TouchGestureSessionsTests: XCTestCase {
    private func frame(_ time: Double, down: Bool, x: Double = 0.2) -> TouchFrame {
        TouchFrame(timestamp: time, touches: down ? (1...3).map {
            TouchSample(id: $0, location: GesturePoint(x: x + Double($0) * 0.1, y: 0.5))
        } : [])
    }

    func testIdleDeviceDoesNotLoseFirstGestureAfterFocusOrConfigurationChange() {
        var sessions = TouchGestureSessions()
        _ = sessions.process(deviceID: 1, frame: frame(0, down: true))
        XCTAssertEqual(sessions.process(deviceID: 1, frame: frame(0.1, down: false)), .tap(fingers: 3))
        sessions.cancelActiveGestures()
        // Devices need not send another all-up frame while idle.
        _ = sessions.process(deviceID: 1, frame: frame(1, down: true))
        XCTAssertEqual(sessions.process(deviceID: 1, frame: frame(1.1, down: false)), .tap(fingers: 3))
    }

    func testInterruptedContactsCannotBecomeNewAppTapOrSwipe() {
        var sessions = TouchGestureSessions()
        _ = sessions.process(deviceID: 1, frame: frame(0, down: true))
        sessions.cancelActiveGestures()
        XCTAssertNil(sessions.process(deviceID: 1, frame: frame(0.1, down: true, x: 0.4)))
        XCTAssertNil(sessions.process(deviceID: 1, frame: frame(0.2, down: false)))
        _ = sessions.process(deviceID: 1, frame: frame(1, down: true))
        XCTAssertEqual(sessions.process(deviceID: 1, frame: frame(1.1, down: true, x: 0.4)),
                       .swipe(fingers: 3, direction: .right))
    }

    func testActiveAndIdleDevicesAreInterruptedIndependently() {
        var sessions = TouchGestureSessions()
        _ = sessions.process(deviceID: 1, frame: frame(0, down: true))
        _ = sessions.process(deviceID: 2, frame: frame(0, down: true))
        _ = sessions.process(deviceID: 2, frame: frame(0.1, down: false))
        sessions.cancelActiveGestures()
        _ = sessions.process(deviceID: 2, frame: frame(0.2, down: true))
        XCTAssertEqual(sessions.process(deviceID: 2, frame: frame(0.3, down: false)), .tap(fingers: 3))
        XCTAssertNil(sessions.process(deviceID: 1, frame: frame(0.3, down: false)))
    }

    func testRepeatedCancellationFramesCannotCountAsRelease() {
        var sessions = TouchGestureSessions()
        _ = sessions.process(deviceID: 1, frame: frame(0, down: true))
        XCTAssertNil(sessions.process(deviceID: 1, frame: frame(0.1, down: false), cancelled: true))
        XCTAssertNil(sessions.process(deviceID: 1, frame: frame(0.2, down: false), cancelled: true))
        _ = sessions.process(deviceID: 1, frame: frame(0.3, down: true))
        XCTAssertNil(sessions.process(deviceID: 1, frame: frame(0.4, down: false)))
        _ = sessions.process(deviceID: 1, frame: frame(1, down: true))
        XCTAssertEqual(sessions.process(deviceID: 1, frame: frame(1.1, down: false)), .tap(fingers: 3))
    }

    func testFiredGestureRemainsActiveUntilRelease() {
        var sessions = TouchGestureSessions()
        _ = sessions.process(deviceID: 1, frame: frame(0, down: true))
        XCTAssertEqual(sessions.process(deviceID: 1, frame: frame(0.1, down: true, x: 0.4)),
                       .swipe(fingers: 3, direction: .right))
        sessions.cancelActiveGestures()
        _ = sessions.process(deviceID: 1, frame: frame(0.2, down: true, x: 0.4))
        XCTAssertNil(sessions.process(deviceID: 1, frame: frame(0.3, down: false)))
    }

    func testRepeatedInterruptionsKeepActiveDeviceBlocked() {
        var sessions = TouchGestureSessions()
        _ = sessions.process(deviceID: 1, frame: frame(0, down: true))
        sessions.cancelActiveGestures()
        sessions.cancelActiveGestures()
        _ = sessions.process(deviceID: 1, frame: frame(0.1, down: true))
        XCTAssertNil(sessions.process(deviceID: 1, frame: frame(0.2, down: false)))
    }

    func testCaptureResetClearsOldDeviceStateAndClock() {
        var sessions = TouchGestureSessions()
        _ = sessions.process(deviceID: 1, frame: frame(100, down: true))
        sessions.cancelActiveGestures()
        sessions.reset()
        _ = sessions.process(deviceID: 1, frame: frame(0, down: true))
        XCTAssertEqual(sessions.process(deviceID: 1, frame: frame(0.1, down: false)), .tap(fingers: 3))
    }

    func testBackwardAllUpBeforeInterruptionCannotRearmPartialGesture() {
        assertInvalidReleaseDoesNotRearm(timestamp: 9, interruptBeforeInvalidRelease: false)
    }

    func testNaNAllUpBeforeInterruptionCannotRearmPartialGesture() {
        assertInvalidReleaseDoesNotRearm(timestamp: .nan, interruptBeforeInvalidRelease: false)
    }

    func testBackwardAllUpWhileBlockedCannotRearmPartialGesture() {
        assertInvalidReleaseDoesNotRearm(timestamp: 9, interruptBeforeInvalidRelease: true)
    }

    func testNaNAllUpWhileBlockedCannotRearmPartialGesture() {
        assertInvalidReleaseDoesNotRearm(timestamp: .nan, interruptBeforeInvalidRelease: true)
    }

    func testAcquiredButUndeliveredReleaseDoesNotBlockNextGesture() {
        var sessions = TouchGestureSessions()
        _ = sessions.process(deviceID: 1, frame: frame(0, down: true))
        sessions.interrupt(activeDeviceIDs: [])
        _ = sessions.process(deviceID: 1, frame: frame(1, down: true))
        XCTAssertEqual(sessions.process(deviceID: 1, frame: frame(1.1, down: false)), .tap(fingers: 3))
    }

    func testAcquiredButUndeliveredDownMustWaitForRelease() {
        var sessions = TouchGestureSessions()
        sessions.interrupt(activeDeviceIDs: [1])
        _ = sessions.process(deviceID: 1, frame: frame(1, down: true))
        XCTAssertNil(sessions.process(deviceID: 1, frame: frame(1.1, down: false)))
        _ = sessions.process(deviceID: 1, frame: frame(2, down: true))
        XCTAssertEqual(sessions.process(deviceID: 1, frame: frame(2.1, down: false)), .tap(fingers: 3))
    }

    private func assertInvalidReleaseDoesNotRearm(timestamp: Double, interruptBeforeInvalidRelease: Bool,
                                                 file: StaticString = #filePath, line: UInt = #line) {
        var sessions = TouchGestureSessions()
        _ = sessions.process(deviceID: 1, frame: frame(10, down: true))
        if interruptBeforeInvalidRelease { sessions.cancelActiveGestures() }
        XCTAssertNil(sessions.process(deviceID: 1, frame: frame(timestamp, down: false)), file: file, line: line)
        if !interruptBeforeInvalidRelease { sessions.cancelActiveGestures() }
        _ = sessions.process(deviceID: 1, frame: frame(10.1, down: true))
        XCTAssertNil(sessions.process(deviceID: 1, frame: frame(10.2, down: false)), file: file, line: line)
        _ = sessions.process(deviceID: 1, frame: frame(11, down: true))
        XCTAssertEqual(sessions.process(deviceID: 1, frame: frame(11.1, down: false)), .tap(fingers: 3), file: file, line: line)
    }
}
