import XCTest
import CoreGraphics
@testable import FlowGestureApp

final class EventEngineRoutingTests: XCTestCase {
    func testSettingsWindowStillReceivesScrollAdjustmentWhileRulesAreBypassed() {
        XCTAssertFalse(EventEngine.shouldBypassOwnAppEvent(.scrollWheel))
        let types: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        for type in types {
            XCTAssertTrue(EventEngine.shouldBypassOwnAppEvent(type))
        }
    }
}
