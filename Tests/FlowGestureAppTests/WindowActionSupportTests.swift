#if os(macOS)
import Foundation
import FlowGestureCore
import XCTest
@testable import FlowGestureApp

final class WindowActionSupportTests: XCTestCase {
    func testFullScreenToggleTargetsOppositeStateForEnterAndExit() throws {
        XCTAssertTrue(try WindowActionSupport.fullScreenTarget(current: false, isSettable: true))
        XCTAssertFalse(try WindowActionSupport.fullScreenTarget(current: true, isSettable: true))
    }

    func testUnknownFullScreenStateRejectsRatherThanGuessingShortcut() {
        XCTAssertThrowsError(try WindowActionSupport.fullScreenTarget(current: nil, isSettable: true)) {
            XCTAssertEqual($0 as? WindowActionFailure, .fullScreenUnsupported)
        }
    }

    func testReadOnlyFullScreenStateReportsSpecificFailure() {
        XCTAssertThrowsError(try WindowActionSupport.fullScreenTarget(current: false, isSettable: false)) {
            XCTAssertEqual($0 as? WindowActionFailure, .fullScreenReadOnly)
        }
    }

    func testMaximizeDoesNotPretendToToggleExistingFullScreen() {
        XCTAssertThrowsError(try WindowActionSupport.validateLayout(isFullScreen: true, positionSettable: true,
                                                                    sizeSettable: true, requiresResize: true)) {
            XCTAssertEqual($0 as? WindowActionFailure, .exitFullScreenBeforeResizing)
        }
    }

    func testNonSettableMoveAndResizeHaveDistinctFailures() {
        XCTAssertThrowsError(try WindowActionSupport.validateLayout(isFullScreen: false, positionSettable: false,
                                                                    sizeSettable: true, requiresResize: true)) {
            XCTAssertEqual($0 as? WindowActionFailure, .positionReadOnly)
        }
        XCTAssertThrowsError(try WindowActionSupport.validateLayout(isFullScreen: false, positionSettable: true,
                                                                    sizeSettable: false, requiresResize: true)) {
            XCTAssertEqual($0 as? WindowActionFailure, .sizeReadOnly)
        }
    }

    func testCenterDoesNotRequireResizableWindow() throws {
        XCTAssertNoThrow(try WindowActionSupport.validateLayout(isFullScreen: false, positionSettable: true,
                                                                sizeSettable: false, requiresResize: false))
    }

    func testTrueFullScreenAndMaximizeRemainDistinctPersistedActions() throws {
        let action = Action.window(.toggleFullScreen)
        XCTAssertNotEqual(action, .window(.maximize))
        let data = try JSONEncoder().encode(action)
        XCTAssertEqual(try JSONDecoder().decode(Action.self, from: data), action)
        XCTAssertTrue(WindowAction.allCases.contains(.toggleFullScreen))
    }

    @MainActor func testExplicitMissingTargetDoesNotRetargetForegroundApplication() async {
        let executor = ActionExecutor()
        let reported = expectation(description: "Captured missing target is reported")
        executor.onError = { message in
            XCTAssertEqual(message, WindowActionFailure.noTargetApplication.localizedDescription)
            reported.fulfill()
        }
        // This must not toggle any real application/window, even if one is active.
        executor.execute([.window(.toggleFullScreen)], targetApplication: nil)
        await fulfillment(of: [reported], timeout: 2)
    }
}
#endif
