#if os(macOS)
import AppKit
import FlowGestureCore
import XCTest
@testable import FlowGestureApp

final class OwnAppInputPolicyTests: XCTestCase {
    private let active = OwnAppInputContext(isOwnAppActive: true)
    private let editing = OwnAppInputContext(isOwnAppActive: true, isEditingText: true, isPointerOverOwnWindowUI: true)

    func testOwnActiveAppStillAllowsSideMiddleAndRightMappings() {
        for button in [MouseButton.back, .forward, .middle, .right, .button6, .button7, .button8] {
            XCTAssertFalse(OwnAppInputPolicy.shouldBypass(trigger: .mouseButton(MouseButtonTrigger(button: button)), context: editing))
            XCTAssertFalse(OwnAppInputPolicy.shouldBypass(trigger: .draw(DrawGestureTrigger(button: button)), context: editing))
        }
    }

    func testKeyboardOnlyBypassesWhileActualOwnTextEntryIsFocused() {
        let shortcut = InputTrigger.keyboard(FlowGestureCore.KeyboardShortcut(keyCode: 123, modifiers: .control))
        XCTAssertFalse(OwnAppInputPolicy.shouldBypass(trigger: shortcut, context: active))
        XCTAssertTrue(OwnAppInputPolicy.shouldBypass(trigger: shortcut, context: editing))
        XCTAssertFalse(OwnAppInputPolicy.shouldBypass(trigger: shortcut,
            context: OwnAppInputContext(isOwnAppActive: false, isEditingText: true)))
    }

    func testTouchAndCornersWorkEvenWhileOwnTextFieldIsFocused() {
        XCTAssertFalse(OwnAppInputPolicy.shouldBypass(trigger: .touch(TouchGestureTrigger()), context: editing))
        XCTAssertFalse(OwnAppInputPolicy.shouldBypass(trigger: .screenCorner(ScreenCornerTrigger()), context: editing))
    }

    func testLeftMappingOnlyBypassesWhenDownBeganInsideOwnKeyWindow() {
        let left = InputTrigger.mouseButton(MouseButtonTrigger(button: .left))
        XCTAssertTrue(OwnAppInputPolicy.shouldBypass(trigger: left, context: editing))
        XCTAssertFalse(OwnAppInputPolicy.shouldBypass(trigger: left, context: active))
        XCTAssertFalse(OwnAppInputPolicy.shouldBypass(trigger: left,
            context: OwnAppInputContext(isOwnAppActive: false, isPointerOverOwnWindowUI: true)))
    }

    func testProtectedLeftPairPassesThroughAfterPointerAndFocusMove() {
        var policy = OwnAppInputPolicy()
        XCTAssertTrue(policy.shouldBypass(eventType: .leftMouseDown, context: editing))
        let otherApp = OwnAppInputContext(isOwnAppActive: false)
        XCTAssertTrue(policy.shouldBypass(eventType: .leftMouseDragged, context: otherApp))
        XCTAssertTrue(policy.shouldBypass(eventType: .leftMouseUp, context: otherApp))
        XCTAssertFalse(policy.isPassingLeftClick)
        XCTAssertFalse(policy.shouldBypass(eventType: .leftMouseUp, context: editing))
    }

    func testLeftStrokeBeginningOutsideOwnWindowIsNotHijackedAtUIEndpoint() {
        var policy = OwnAppInputPolicy()
        XCTAssertFalse(policy.shouldBypass(eventType: .leftMouseDown, context: active))
        XCTAssertFalse(policy.shouldBypass(eventType: .leftMouseDragged, context: editing))
        XCTAssertFalse(policy.shouldBypass(eventType: .leftMouseUp, context: editing))
    }

    func testOtherEventsDoNotCancelProtectedLeftPairOrBlockSideButtons() {
        var policy = OwnAppInputPolicy()
        _ = policy.shouldBypass(eventType: .leftMouseDown, context: editing)
        for type in [CGEventType.otherMouseDown, .otherMouseUp, .rightMouseDown, .rightMouseDragged,
                     .mouseMoved, .scrollWheel, .flagsChanged] {
            XCTAssertFalse(policy.shouldBypass(eventType: type, context: editing))
            XCTAssertTrue(policy.isPassingLeftClick)
        }
        XCTAssertTrue(policy.shouldBypass(eventType: .leftMouseUp, context: editing))
    }

    func testResetDropsOnlyTheProtectionLatch() {
        var policy = OwnAppInputPolicy()
        _ = policy.shouldBypass(eventType: .leftMouseDown, context: editing)
        policy.reset()
        XCTAssertFalse(policy.isPassingLeftClick)
        XCTAssertFalse(policy.shouldBypass(eventType: .leftMouseDragged, context: editing))
    }

    @MainActor func testTextEntryDetectionDoesNotReadContentsOrBlockReadOnlyText() async {
        XCTAssertFalse(OwnAppInputPolicy.isEditingText(nil))
        XCTAssertFalse(OwnAppInputPolicy.isEditingText(NSView()))
        let editor = NSTextView()
        editor.isEditable = true
        XCTAssertTrue(OwnAppInputPolicy.isEditingText(editor))
        editor.isEditable = false
        XCTAssertFalse(OwnAppInputPolicy.isEditingText(editor))
        let field = NSTextField()
        field.isEditable = true
        XCTAssertFalse(OwnAppInputPolicy.isEditingText(field), "A field without an active field editor is not currently being edited")
    }
}
#endif
