import XCTest
@testable import FlowGestureCore

final class TouchGestureOverlapTests: XCTestCase {
    func testThreeFingerHorizontalSwipeWarnsAboutPagesAndSpaces() {
        let trigger = TouchGestureTrigger(gesture: .swipe(fingers: 3, direction: .left), device: .trackpad)
        XCTAssertEqual(TouchGestureOverlap.possible(for: trigger), [.trackpadPages, .trackpadSpaces])
    }

    func testVerticalAndDiagonalSwipesExplainRelevantSystemAssignments() {
        XCTAssertEqual(TouchGestureOverlap.possible(for: .init(gesture: .swipe(fingers: 4, direction: .up), device: .trackpad)), [.trackpadMissionControl])
        XCTAssertEqual(TouchGestureOverlap.possible(for: .init(gesture: .swipe(fingers: 4, direction: .down), device: .trackpad)), [.trackpadAppExpose])
        XCTAssertEqual(TouchGestureOverlap.possible(for: .init(gesture: .swipe(fingers: 4, direction: .upRight), device: .trackpad)), [.trackpadSpaces, .trackpadMissionControl])
    }

    func testMouseScopeDoesNotShowTrackpadAdvice() {
        let trigger = TouchGestureTrigger(gesture: .swipe(fingers: 2, direction: .right), device: .mouse)
        XCTAssertEqual(TouchGestureOverlap.possible(for: trigger), [.mouseSpaces])
    }

    func testAnyDeviceScopeIncludesBothDevices() {
        let trigger = TouchGestureTrigger(gesture: .swipe(fingers: 2, direction: .right))
        XCTAssertEqual(TouchGestureOverlap.possible(for: trigger), [.trackpadScroll, .trackpadPages, .mouseSpaces])
    }

    func testModifiersDoNotPretendToSuppressNativePinch() {
        let trigger = TouchGestureTrigger(gesture: .pinch(.outward), modifiers: [.command, .shift], device: .trackpad)
        XCTAssertEqual(TouchGestureOverlap.possible(for: trigger), [.trackpadZoom])
    }

    func testTapFamiliesHaveSpecificWarnings() {
        for (fingers, expected) in [(1, TouchGestureOverlap.trackpadClick), (2, .trackpadSecondaryClick), (3, .trackpadLookup)] {
            XCTAssertEqual(TouchGestureOverlap.possible(for: .init(gesture: .tap(fingers: fingers), device: .trackpad)), [expected])
        }
    }

    func testMouseSingleFingerSwipeWarnsAboutScrollingAndPages() {
        let trigger = TouchGestureTrigger(gesture: .swipe(fingers: 1, direction: .left), device: .mouse)
        XCTAssertEqual(TouchGestureOverlap.possible(for: trigger), [.mouseScroll, .mousePages])
    }
}
