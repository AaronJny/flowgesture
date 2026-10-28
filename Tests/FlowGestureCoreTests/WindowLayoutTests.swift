import XCTest
@testable import FlowGestureCore

final class WindowLayoutTests: XCTestCase {
    func testFullScreenRetainsTopOriginVisibleFrame() {
        let screen = GestureRect(x: 20, y: 24, width: 1440, height: 876)
        XCTAssertEqual(WindowLayout.frame(forFraction: GestureRect(x: 0, y: 0, width: 1, height: 1), inTopOriginScreen: screen), screen)
    }

    func testBottomAndTopFractionsInvertY() {
        let screen = GestureRect(x: 100, y: 20, width: 1200, height: 800)
        XCTAssertEqual(WindowLayout.frame(forFraction: GestureRect(x: 0, y: 0, width: 1, height: 0.5), inTopOriginScreen: screen),
                       GestureRect(x: 100, y: 420, width: 1200, height: 400))
        XCTAssertEqual(WindowLayout.frame(forFraction: GestureRect(x: 0, y: 0.5, width: 1, height: 0.5), inTopOriginScreen: screen),
                       GestureRect(x: 100, y: 20, width: 1200, height: 400))
    }

    func testAsymmetricCustomFrameOnNegativeOriginMonitor() {
        let screen = GestureRect(x: -1600, y: -900, width: 1600, height: 900)
        let result = WindowLayout.frame(forFraction: GestureRect(x: 0.25, y: 0.2, width: 0.5, height: 0.3), inTopOriginScreen: screen)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.x, -1200, accuracy: 0.000001)
        XCTAssertEqual(result!.y, -450, accuracy: 0.000001)
        XCTAssertEqual(result!.width, 800, accuracy: 0.000001)
        XCTAssertEqual(result!.height, 270, accuracy: 0.000001)
    }

    func testInvalidFractionAndScreenRejectInsteadOfClamp() {
        let screen = GestureRect(x: 0, y: 0, width: 100, height: 100)
        for fraction in [GestureRect(x: -0.1, y: 0, width: 1, height: 1), GestureRect(x: 0.5, y: 0, width: 1, height: 1),
                         GestureRect(x: 0, y: 0, width: 0, height: 1), GestureRect(x: 0, y: .nan, width: 1, height: 1)] {
            XCTAssertNil(WindowLayout.frame(forFraction: fraction, inTopOriginScreen: screen))
        }
        XCTAssertNil(WindowLayout.frame(forFraction: GestureRect(x: 0, y: 0, width: 1, height: 1),
                                        inTopOriginScreen: GestureRect(x: 0, y: 0, width: -100, height: 100)))
    }
}
