import XCTest
@testable import FlowGestureCore

final class TouchContactActivityTests: XCTestCase {
    func testCompleteQueuedGestureIsIdleAtContextBoundary() {
        var activity = TouchContactActivity()
        activity.observe(deviceID: 1, timestamp: 1, hasActiveContacts: true, cancelled: false)
        activity.observe(deviceID: 1, timestamp: 1.1, hasActiveContacts: false, cancelled: false)
        XCTAssertTrue(activity.activeDeviceIDs.isEmpty)
    }

    func testOnlyStillTouchingDeviceNeedsReleaseAfterBoundary() {
        var activity = TouchContactActivity()
        activity.observe(deviceID: 1, timestamp: 1, hasActiveContacts: true, cancelled: false)
        activity.observe(deviceID: 2, timestamp: 1, hasActiveContacts: true, cancelled: false)
        activity.observe(deviceID: 2, timestamp: 1.1, hasActiveContacts: false, cancelled: false)
        XCTAssertEqual(activity.activeDeviceIDs, [1])
    }

    func testInvalidOrCancelledAllUpCannotProveIdle() {
        for (time, cancelled) in [(9.0, false), (Double.nan, false), (10.1, true)] {
            var activity = TouchContactActivity()
            activity.observe(deviceID: 1, timestamp: 10, hasActiveContacts: true, cancelled: false)
            activity.observe(deviceID: 1, timestamp: time, hasActiveContacts: false, cancelled: cancelled)
            XCTAssertEqual(activity.activeDeviceIDs, [1])
            activity.observe(deviceID: 1, timestamp: 11, hasActiveContacts: false, cancelled: false)
            XCTAssertTrue(activity.activeDeviceIDs.isEmpty)
        }
    }

    func testResetAllowsNewCaptureClock() {
        var activity = TouchContactActivity()
        activity.observe(deviceID: 1, timestamp: 100, hasActiveContacts: true, cancelled: false)
        activity.reset()
        activity.observe(deviceID: 1, timestamp: 0, hasActiveContacts: false, cancelled: false)
        XCTAssertTrue(activity.activeDeviceIDs.isEmpty)
    }
}
