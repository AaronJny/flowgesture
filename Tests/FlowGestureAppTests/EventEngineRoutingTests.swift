import XCTest
import CoreGraphics
@testable import FlowGestureApp

final class EventEngineRoutingTests: XCTestCase {
    func testForegroundSettingsDoesNotBypassUserBindingsOrScrolling() {
        var policy = OwnAppInputPolicy()
        let context = OwnAppInputContext(isOwnAppActive: true, isPointerOverOwnWindowUI: true)
        let types: [CGEventType] = [.scrollWheel, .keyDown, .keyUp, .rightMouseDown, .otherMouseDown, .otherMouseUp]
        for type in types { XCTAssertFalse(policy.shouldBypass(eventType: type, context: context)) }
        XCTAssertTrue(policy.shouldBypass(eventType: .leftMouseDown, context: context))
    }
}
