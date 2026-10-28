import AppKit
import XCTest
@testable import FlowGestureApp

final class MouseCaptureTests: XCTestCase {
    @MainActor func testCaptureWaitsForMatchingReleaseBeforeResumingEngine() async throws {
        let view = MouseButtonCaptureSurface.CaptureView()
        var captured: [Int] = []
        view.onCapture = { number, _ in captured.append(number) }
        func event(_ type: CGEventType, button: Int64) throws -> NSEvent {
            let cg = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .center))
            cg.setIntegerValueField(.mouseEventButtonNumber, value: button)
            return try XCTUnwrap(NSEvent(cgEvent: cg))
        }
        view.otherMouseDown(with: try event(.otherMouseDown, button: 3))
        XCTAssertTrue(captured.isEmpty)
        view.otherMouseDown(with: try event(.otherMouseDown, button: 4))
        view.otherMouseUp(with: try event(.otherMouseUp, button: 4))
        XCTAssertTrue(captured.isEmpty)
        view.otherMouseUp(with: try event(.otherMouseUp, button: 3))
        XCTAssertEqual(captured, [3])
        view.otherMouseUp(with: try event(.otherMouseUp, button: 3))
        XCTAssertEqual(captured, [3])
    }
}
