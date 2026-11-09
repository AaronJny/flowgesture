#if os(macOS)
import CoreGraphics
import XCTest
@testable import FlowGestureCapture

final class CaptureQuartzMaskTests: XCTestCase {
    func testPrivacyMaskMatchesPublicQuartzExclusions() {
        let excluded: [CGEventType] = [.null, .keyDown, .keyUp, .flagsChanged,
                                      .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                      .otherMouseDown, .otherMouseUp, .mouseMoved,
                                      .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                      .tabletPointer, .tabletProximity]
        XCTAssertEqual(Set(excluded.map(\.rawValue)), CaptureStore.excludedQuartzClasses)
        let mask = excluded.reduce(CGEventMask.max) { $0 & ~(CGEventMask(1) << $1.rawValue) }
        XCTAssertEqual(mask, CaptureStore.eventMask)
    }
}
#endif
