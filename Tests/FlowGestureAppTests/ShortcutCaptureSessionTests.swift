#if os(macOS)
import CoreGraphics
import FlowGestureCore
import XCTest
@testable import FlowGestureApp

final class ShortcutCaptureSessionTests: XCTestCase {
    private func key(_ code: UInt16, down: Bool, flags: CGEventFlags = [], repeatKey: Bool = false) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down))
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
        return event
    }

    func testAllModifierArrowCombinationsCaptureOnlyAfterMatchingKeyUp() throws {
        let combinations: [(CGEventFlags, ModifierKeys)] = [
            (.maskCommand, .command), (.maskControl, .control), (.maskAlternate, .option), (.maskShift, .shift),
            (.maskSecondaryFn, .function),
            ([.maskCommand, .maskControl, .maskAlternate, .maskShift], [.command, .control, .option, .shift])
        ]
        for code in [UInt16(123), 124, 125, 126] {
            for (flags, modifiers) in combinations {
                var policy = ShortcutCapturePolicy()
                policy.begin()
                XCTAssertEqual(policy.handle(type: .keyDown, event: try key(code, down: true, flags: flags)), .swallow)
                XCTAssertEqual(policy.pendingKeyCode, code)
                XCTAssertEqual(policy.handle(type: .keyUp, event: try key(code, down: false)),
                               .captured(FlowGestureCore.KeyboardShortcut(keyCode: code, modifiers: modifiers)))
                XCTAssertFalse(policy.isRecording)
                XCTAssertNil(policy.pendingKeyCode)
            }
        }
    }

    func testFlagsChangedPassThroughWithoutCapturingModifierAlone() throws {
        var policy = ShortcutCapturePolicy()
        policy.begin()
        let event = try key(55, down: true, flags: .maskCommand)
        event.type = .flagsChanged
        XCTAssertEqual(policy.handle(type: .flagsChanged, event: event), .passThrough)
        XCTAssertTrue(policy.isRecording)
        XCTAssertNil(policy.pendingKeyCode)
    }

    func testCapturedKeyRepeatsAreSwallowedButDoNotCompleteEarly() throws {
        var policy = ShortcutCapturePolicy()
        policy.begin()
        XCTAssertEqual(policy.handle(type: .keyDown, event: try key(123, down: true, flags: .maskControl)), .swallow)
        for _ in 0..<3 {
            XCTAssertEqual(policy.handle(type: .keyDown, event: try key(123, down: true, flags: .maskControl, repeatKey: true)), .swallow)
        }
        XCTAssertEqual(policy.handle(type: .keyUp, event: try key(123, down: false)),
                       .captured(FlowGestureCore.KeyboardShortcut(keyCode: 123, modifiers: .control)))
        XCTAssertEqual(policy.handle(type: .keyUp, event: try key(123, down: false)), .passThrough)
    }

    func testKeyHeldBeforeRecordingIsNotCapturedFromAutorepeat() throws {
        var policy = ShortcutCapturePolicy()
        policy.begin()
        XCTAssertEqual(policy.handle(type: .keyDown, event: try key(123, down: true, repeatKey: true)), .passThrough)
        XCTAssertEqual(policy.handle(type: .keyUp, event: try key(123, down: false)), .passThrough)
        XCTAssertTrue(policy.isRecording)
    }

    func testEscapeCancelsAndSwallowsItsMatchingUp() throws {
        var policy = ShortcutCapturePolicy()
        policy.begin()
        XCTAssertEqual(policy.handle(type: .keyDown, event: try key(53, down: true)), .swallow)
        XCTAssertFalse(policy.isRecording)
        XCTAssertTrue(policy.isDraining)
        XCTAssertEqual(policy.handle(type: .keyUp, event: try key(53, down: false)), .cancelled)
        XCTAssertFalse(policy.isDraining)
    }

    func testLifecycleCancellationDiscardsCandidateButDrainsKeyPair() throws {
        var policy = ShortcutCapturePolicy()
        policy.begin()
        _ = policy.handle(type: .keyDown, event: try key(124, down: true, flags: [.maskCommand, .maskShift]))
        policy.cancel() // timeout, app resignation, sleep, token replacement or view disappearance
        XCTAssertFalse(policy.isRecording)
        XCTAssertTrue(policy.isDraining)
        XCTAssertEqual(policy.handle(type: .keyDown, event: try key(8, down: true)), .passThrough)
        XCTAssertEqual(policy.handle(type: .keyUp, event: try key(8, down: false)), .passThrough)
        XCTAssertEqual(policy.handle(type: .keyUp, event: try key(124, down: false)), .cancelled)
        XCTAssertNil(policy.pendingKeyCode)
    }

    func testUnmatchedKeyUpCannotCompleteCapture() throws {
        var policy = ShortcutCapturePolicy()
        policy.begin()
        _ = policy.handle(type: .keyDown, event: try key(125, down: true, flags: [.maskAlternate, .maskShift]))
        XCTAssertEqual(policy.handle(type: .keyUp, event: try key(126, down: false)), .passThrough)
        XCTAssertEqual(policy.pendingKeyCode, 125)
        XCTAssertEqual(policy.handle(type: .keyUp, event: try key(125, down: false)),
                       .captured(FlowGestureCore.KeyboardShortcut(keyCode: 125, modifiers: [.option, .shift])))
    }

    func testInactiveAndResetPoliciesNeverConsumeKeys() throws {
        var policy = ShortcutCapturePolicy()
        XCTAssertEqual(policy.handle(type: .keyDown, event: try key(123, down: true)), .passThrough)
        policy.begin()
        _ = policy.handle(type: .keyDown, event: try key(123, down: true))
        policy.reset()
        XCTAssertFalse(policy.isRecording)
        XCTAssertFalse(policy.isDraining)
        XCTAssertEqual(policy.handle(type: .keyUp, event: try key(123, down: false)), .passThrough)
    }

    @MainActor func testSessionInitializationAndCancellationDoNotStartCapture() async {
        let session = ShortcutCaptureSession()
        XCTAssertFalse(session.isRecording)
        session.cancel()
        XCTAssertFalse(session.isRecording)
    }
}
#endif
