import XCTest
@testable import FlowGestureCore

final class TouchGestureRecognizerTests: XCTestCase {
    private func touch(_ id: Int, _ x: Double, _ y: Double = 0.5) -> TouchSample {
        TouchSample(id: id, location: GesturePoint(x: x, y: y))
    }
    private func frame(_ time: Double, _ touches: [TouchSample]) -> TouchFrame { TouchFrame(timestamp: time, touches: touches) }

    func testThreeFingerTapFiresOnlyWhenAllFingersLift() {
        var recognizer = TouchGestureRecognizer()
        XCTAssertNil(recognizer.process(frame: frame(0, [touch(1, 0.2), touch(2, 0.4), touch(3, 0.6)])))
        XCTAssertNil(recognizer.process(frame: frame(0.1, [touch(1, 0.201), touch(2, 0.401), touch(3, 0.601)])))
        XCTAssertEqual(recognizer.process(frame: frame(0.2, [])), .tap(fingers: 3))
        XCTAssertNil(recognizer.process(frame: frame(0.21, [])))
    }

    func testStaggeredLandingAndReleaseUsePeakFingerCount() {
        var recognizer = TouchGestureRecognizer()
        XCTAssertNil(recognizer.process(frame: frame(0, [touch(1, 0.2)])))
        XCTAssertNil(recognizer.process(frame: frame(0.02, [touch(1, 0.2), touch(2, 0.4)])))
        XCTAssertNil(recognizer.process(frame: frame(0.04, [touch(1, 0.2), touch(2, 0.4), touch(3, 0.6)])))
        XCTAssertNil(recognizer.process(frame: frame(0.12, [touch(2, 0.4), touch(3, 0.6)])))
        XCTAssertNil(recognizer.process(frame: frame(0.15, [touch(3, 0.6)])))
        XCTAssertEqual(recognizer.process(frame: frame(0.2, [])), .tap(fingers: 3))
    }

    func testSwipeUsesCentroidAndFiresOncePerSession() {
        var recognizer = TouchGestureRecognizer()
        XCTAssertNil(recognizer.process(frame: frame(0, [touch(1, 0.2), touch(2, 0.4), touch(3, 0.6)])))
        XCTAssertEqual(recognizer.process(frame: frame(0.1, [touch(1, 0.35), touch(2, 0.55), touch(3, 0.75)])),
                       .swipe(fingers: 3, direction: .right))
        XCTAssertNil(recognizer.process(frame: frame(0.15, [touch(1, 0.4), touch(2, 0.6), touch(3, 0.8)])))
        XCTAssertNil(recognizer.process(frame: frame(0.2, [])))
        XCTAssertNil(recognizer.process(frame: frame(1, [touch(1, 0.2)])))
        XCTAssertEqual(recognizer.process(frame: frame(1.1, [])), .tap(fingers: 1))
    }

    func testUpSwipeHasPositiveYAndDefaultsToCardinalDirection() {
        var recognizer = TouchGestureRecognizer()
        _ = recognizer.process(frame: frame(0, [touch(1, 0.3, 0.2), touch(2, 0.6, 0.2)]))
        XCTAssertEqual(recognizer.process(frame: frame(0.1, [touch(1, 0.33, 0.4), touch(2, 0.63, 0.4)])),
                       .swipe(fingers: 2, direction: .up))
    }

    func testOutwardAndInwardPinches() {
        var outward = TouchGestureRecognizer()
        _ = outward.process(frame: frame(0, [touch(1, 0.4), touch(2, 0.6)]))
        XCTAssertEqual(outward.process(frame: frame(0.1, [touch(1, 0.35), touch(2, 0.65)])), .pinch(.outward))
        XCTAssertNil(outward.process(frame: frame(0.15, [touch(1, 0.3), touch(2, 0.7)])))
        XCTAssertNil(outward.process(frame: frame(0.2, [])))
        var inward = TouchGestureRecognizer()
        _ = inward.process(frame: frame(0, [touch(1, 0.3), touch(2, 0.7)]))
        XCTAssertEqual(inward.process(frame: frame(0.1, [touch(1, 0.4), touch(2, 0.6)])), .pinch(.inward))
    }

    func testSmallMotionDoesNotSwipeButPreventsFalseTap() {
        var recognizer = TouchGestureRecognizer()
        _ = recognizer.process(frame: frame(0, [touch(1, 0.2), touch(2, 0.4)]))
        XCTAssertNil(recognizer.process(frame: frame(0.1, [touch(1, 0.25), touch(2, 0.45)])))
        XCTAssertNil(recognizer.process(frame: frame(0.2, [])))
    }

    func testMovingAwayThenReturningDoesNotBecomeTap() {
        var recognizer = TouchGestureRecognizer()
        _ = recognizer.process(frame: frame(0, [touch(1, 0.4)]))
        _ = recognizer.process(frame: frame(0.1, [touch(1, 0.45)]))
        _ = recognizer.process(frame: frame(0.15, [touch(1, 0.4)]))
        XCTAssertNil(recognizer.process(frame: frame(0.2, [])))
    }

    func testSlowHoldIsNotTap() {
        var recognizer = TouchGestureRecognizer()
        _ = recognizer.process(frame: frame(0, [touch(1, 0.4), touch(2, 0.6)]))
        XCTAssertNil(recognizer.process(frame: frame(0.4, [])))
    }

    func testFingerRemovalCannotCreateSpuriousCentroidSwipe() {
        var recognizer = TouchGestureRecognizer()
        _ = recognizer.process(frame: frame(0, [touch(1, 0.1), touch(2, 0.5), touch(3, 0.9)]))
        XCTAssertNil(recognizer.process(frame: frame(0.1, [touch(2, 0.5), touch(3, 0.9)])))
        XCTAssertNil(recognizer.process(frame: frame(0.15, [touch(3, 0.9)])))
        XCTAssertEqual(recognizer.process(frame: frame(0.2, [])), .tap(fingers: 3))
    }

    func testLateJoiningOrReplacedContactCancelsUntilRelease() {
        var late = TouchGestureRecognizer()
        _ = late.process(frame: frame(0, [touch(1, 0.2)]))
        XCTAssertNil(late.process(frame: frame(0.1, [touch(1, 0.2), touch(2, 0.4)])))
        XCTAssertNil(late.process(frame: frame(0.2, [])))
        var replaced = TouchGestureRecognizer()
        _ = replaced.process(frame: frame(0, [touch(1, 0.2), touch(2, 0.4)]))
        XCTAssertNil(replaced.process(frame: frame(0.1, [touch(2, 0.4), touch(3, 0.6)])))
        XCTAssertNil(replaced.process(frame: frame(0.2, [])))
    }

    func testMalformedDuplicateContactsSuppressUntilAllUp() {
        var recognizer = TouchGestureRecognizer()
        XCTAssertNil(recognizer.process(frame: frame(0, [touch(1, 0.2), touch(1, 0.4)])))
        XCTAssertNil(recognizer.process(frame: frame(0.1, [touch(1, 0.2)])))
        XCTAssertNil(recognizer.process(frame: frame(0.2, [])))
        _ = recognizer.process(frame: frame(1, [touch(1, 0.2)]))
        XCTAssertEqual(recognizer.process(frame: frame(1.1, [])), .tap(fingers: 1))
    }

    func testInvalidCoordinatesAndBackwardsTimeDoNotEmit() {
        var recognizer = TouchGestureRecognizer()
        _ = recognizer.process(frame: frame(1, [touch(1, 0.2)]))
        XCTAssertNil(recognizer.process(frame: frame(0.9, [])))
        XCTAssertNil(recognizer.process(frame: frame(1.1, [])))
        XCTAssertNil(recognizer.process(frame: frame(2, [touch(1, 1.5)])))
        XCTAssertNil(recognizer.process(frame: frame(2.1, [])))
        XCTAssertNil(recognizer.process(frame: frame(3, [touch(1, .nan)])))
    }

    func testResetDiscardsOldContactsAndAllowsClockRestart() {
        var recognizer = TouchGestureRecognizer()
        _ = recognizer.process(frame: frame(100, [touch(1, 0.2)]))
        recognizer.reset()
        XCTAssertNil(recognizer.process(frame: frame(0, [touch(2, 0.4)])))
        XCTAssertEqual(recognizer.process(frame: frame(0.1, [])), .tap(fingers: 1))
    }

    func testTouchOrderingDoesNotAffectRecognition() {
        var a = TouchGestureRecognizer(), b = TouchGestureRecognizer()
        let start = [touch(1, 0.2), touch(2, 0.4), touch(3, 0.6)]
        let end = [touch(1, 0.35), touch(2, 0.55), touch(3, 0.75)]
        _ = a.process(frame: frame(0, start))
        _ = b.process(frame: frame(0, Array(start.reversed())))
        XCTAssertEqual(a.process(frame: frame(0.1, end)), b.process(frame: frame(0.1, Array(end.reversed()))))
    }

    func testInvalidConfigurationRejectsInput() {
        var recognizer = TouchGestureRecognizer(configuration: TouchGestureConfiguration(swipeDistance: 0))
        XCTAssertNil(recognizer.process(frame: frame(0, [touch(1, 0.2)])))
        XCTAssertNil(recognizer.process(frame: frame(0.1, [])))
    }

    func testEarlyOneFingerSwipeWaitsForThirdAndFourthFingers() {
        var recognizer = TouchGestureRecognizer()
        XCTAssertNil(recognizer.process(frame: frame(0, [touch(1, 0.1)])))
        XCTAssertNil(recognizer.process(frame: frame(0.02, [touch(1, 0.25)])))
        XCTAssertNil(recognizer.process(frame: frame(0.04, [touch(1, 0.25), touch(2, 0.4), touch(3, 0.55)])))
        XCTAssertNil(recognizer.process(frame: frame(0.06, [touch(1, 0.25), touch(2, 0.4), touch(3, 0.55), touch(4, 0.7)])))
        XCTAssertEqual(recognizer.process(frame: frame(0.1, [touch(1, 0.4), touch(2, 0.55), touch(3, 0.7), touch(4, 0.85)])),
                       .swipe(fingers: 4, direction: .right))
        XCTAssertNil(recognizer.process(frame: frame(0.12, [touch(4, 0.9)])))
        XCTAssertNil(recognizer.process(frame: frame(0.14, [])))
    }

    func testEarlyTwoFingerSwipeDoesNotCommitBeforeThirdJoins() {
        var recognizer = TouchGestureRecognizer()
        _ = recognizer.process(frame: frame(0, [touch(1, 0.1), touch(2, 0.3)]))
        XCTAssertNil(recognizer.process(frame: frame(0.02, [touch(1, 0.25), touch(2, 0.45)])))
        XCTAssertNil(recognizer.process(frame: frame(0.04, [touch(1, 0.25), touch(2, 0.45), touch(3, 0.65)])))
        // Each old contact already moved 0.15; the next 0.05 suffices without
        // pretending the new finger also made the earlier movement.
        XCTAssertEqual(recognizer.process(frame: frame(0.1, [touch(1, 0.3), touch(2, 0.5), touch(3, 0.7)])),
                       .swipe(fingers: 3, direction: .right))
    }

    func testEarlyPinchIsDiscardedWhenThirdFingerJoins() {
        var recognizer = TouchGestureRecognizer()
        _ = recognizer.process(frame: frame(0, [touch(1, 0.4), touch(2, 0.6)]))
        XCTAssertNil(recognizer.process(frame: frame(0.02, [touch(1, 0.35), touch(2, 0.65)])))
        XCTAssertNil(recognizer.process(frame: frame(0.04, [touch(1, 0.35), touch(2, 0.65), touch(3, 0.8)])))
        XCTAssertNil(recognizer.process(frame: frame(0.1, [touch(1, 0.35), touch(2, 0.65), touch(3, 0.8)])))
        XCTAssertNil(recognizer.process(frame: frame(0.12, [])))
    }

    func testEarlyPinchCanBecomeFourFingerSwipe() {
        var recognizer = TouchGestureRecognizer()
        _ = recognizer.process(frame: frame(0, [touch(1, 0.3), touch(2, 0.5)]))
        XCTAssertNil(recognizer.process(frame: frame(0.02, [touch(1, 0.25), touch(2, 0.55)])))
        XCTAssertNil(recognizer.process(frame: frame(0.04, [touch(1, 0.25), touch(2, 0.55), touch(3, 0.65)])))
        XCTAssertNil(recognizer.process(frame: frame(0.06, [touch(1, 0.25), touch(2, 0.55), touch(3, 0.65), touch(4, 0.75)])))
        XCTAssertEqual(recognizer.process(frame: frame(0.1, [touch(1, 0.4), touch(2, 0.7), touch(3, 0.8), touch(4, 0.9)])),
                       .swipe(fingers: 4, direction: .right))
    }

    func testJoinWindowEndpointStillAcceptsFingers() {
        var recognizer = TouchGestureRecognizer()
        _ = recognizer.process(frame: frame(0, [touch(1, 0.1)]))
        XCTAssertNil(recognizer.process(frame: frame(0.08, [touch(1, 0.3)])))
        XCTAssertNil(recognizer.process(frame: frame(0.08, [touch(1, 0.3), touch(2, 0.5)])))
        XCTAssertEqual(recognizer.process(frame: frame(0.09, [touch(1, 0.35), touch(2, 0.55)])),
                       .swipe(fingers: 2, direction: .right))
    }

    func testShortSwipeAndBothPinchesEmitAtAllUp() {
        let cases: [([TouchSample], [TouchSample], TouchGesture)] = [
            ([touch(1, 0.2)], [touch(1, 0.35)], .swipe(fingers: 1, direction: .right)),
            ([touch(1, 0.4), touch(2, 0.6)], [touch(1, 0.35), touch(2, 0.65)], .pinch(.outward)),
            ([touch(1, 0.3), touch(2, 0.7)], [touch(1, 0.4), touch(2, 0.6)], .pinch(.inward))
        ]
        for (start, moved, expected) in cases {
            var recognizer = TouchGestureRecognizer()
            XCTAssertNil(recognizer.process(frame: frame(0, start)))
            XCTAssertNil(recognizer.process(frame: frame(0.02, moved)))
            XCTAssertEqual(recognizer.process(frame: frame(0.04, [])), expected)
            XCTAssertNil(recognizer.process(frame: frame(0.05, [])))
        }
    }

    func testEarlyThresholdCrossingSurvivesReversalAndStaggeredRelease() {
        var recognizer = TouchGestureRecognizer()
        let start = [touch(1, 0.2), touch(2, 0.4), touch(3, 0.6)]
        _ = recognizer.process(frame: frame(0, start))
        XCTAssertNil(recognizer.process(frame: frame(0.02, [touch(1, 0.35), touch(2, 0.55), touch(3, 0.75)])))
        XCTAssertNil(recognizer.process(frame: frame(0.03, start)))
        XCTAssertNil(recognizer.process(frame: frame(0.04, [touch(2, 0.4), touch(3, 0.6)])))
        XCTAssertNil(recognizer.process(frame: frame(0.1, [touch(3, 0.9)])))
        XCTAssertEqual(recognizer.process(frame: frame(0.12, [])), .swipe(fingers: 3, direction: .right))
    }

    func testPendingSwipeIsNotCarriedAcrossInvalidContactChanges() {
        let invalidChanges: [(Double, [TouchSample])] = [
            (0.04, [touch(2, 0.4)]), // Replaced ID.
            (0.1, [touch(1, 0.4), touch(2, 0.6)]), // Late join.
            (0.04, [touch(1, 0.4), touch(1, 0.6)]), // Malformed duplicate.
            (0.04, [touch(1, .nan)]),
            (0.01, [touch(1, 0.4)]) // Backwards time.
        ]
        for (time, contacts) in invalidChanges {
            var recognizer = TouchGestureRecognizer()
            _ = recognizer.process(frame: frame(0, [touch(1, 0.2)]))
            XCTAssertNil(recognizer.process(frame: frame(0.02, [touch(1, 0.4)])))
            XCTAssertNil(recognizer.process(frame: frame(time, contacts)))
            XCTAssertNil(recognizer.process(frame: frame(0.12, [])))
            _ = recognizer.process(frame: frame(1, [touch(3, 0.5)]))
            XCTAssertEqual(recognizer.process(frame: frame(1.1, [])), .tap(fingers: 1))
        }
    }

    func testPendingGestureIsCancelledByRejoiningAfterReleaseOrReset() {
        var recognizer = TouchGestureRecognizer()
        let start = [touch(1, 0.2), touch(2, 0.4)]
        _ = recognizer.process(frame: frame(0, start))
        XCTAssertNil(recognizer.process(frame: frame(0.02, [touch(1, 0.4), touch(2, 0.6)])))
        XCTAssertNil(recognizer.process(frame: frame(0.03, [touch(2, 0.6)])))
        XCTAssertNil(recognizer.process(frame: frame(0.04, [touch(1, 0.4), touch(2, 0.6)])))
        XCTAssertNil(recognizer.process(frame: frame(0.05, [])))
        _ = recognizer.process(frame: frame(1, start))
        XCTAssertNil(recognizer.process(frame: frame(1.02, [touch(1, 0.4), touch(2, 0.6)])))
        recognizer.reset()
        XCTAssertNil(recognizer.process(frame: frame(0, [])))
    }

    func testPendingGestureExpiresEvenWithoutIntermediateFrames() {
        var recognizer = TouchGestureRecognizer()
        _ = recognizer.process(frame: frame(0, [touch(1, 0.2)]))
        XCTAssertNil(recognizer.process(frame: frame(0.02, [touch(1, 0.4)])))
        XCTAssertNil(recognizer.process(frame: frame(3, [])))
    }


    func testDeferredSwipeCommitsAfterWindowWithoutLosingEarlyMotion() {
        var recognizer = TouchGestureRecognizer()
        _ = recognizer.process(frame: frame(0, [touch(1, 0.2)]))
        XCTAssertNil(recognizer.process(frame: frame(0.02, [touch(1, 0.4)])))
        XCTAssertEqual(recognizer.process(frame: frame(0.09, [touch(1, 0.2)])),
                       .swipe(fingers: 1, direction: .right))
        // Once committed, later contact churn cannot produce a second action.
        XCTAssertNil(recognizer.process(frame: frame(0.1, [touch(2, 0.5), touch(3, 0.7)])))
        XCTAssertNil(recognizer.process(frame: frame(0.12, [])))
    }

    func testStaggeredTwoFingerLandingDoesNotFabricatePinch() {
        var recognizer = TouchGestureRecognizer()
        _ = recognizer.process(frame: frame(0, [touch(1, 0.2)]))
        XCTAssertNil(recognizer.process(frame: frame(0.02, [touch(1, 0.25)])))
        XCTAssertNil(recognizer.process(frame: frame(0.04, [touch(1, 0.25), touch(2, 0.45)])))
        XCTAssertNil(recognizer.process(frame: frame(0.09, [touch(1, 0.25), touch(2, 0.45)])))
        XCTAssertEqual(recognizer.process(frame: frame(0.1, [touch(1, 0.2), touch(2, 0.5)])), .pinch(.outward))
    }

    func testShortJoinedSwipeUsesNewCohortAtRelease() {
        var recognizer = TouchGestureRecognizer()
        _ = recognizer.process(frame: frame(0, [touch(1, 0.1), touch(2, 0.3)]))
        XCTAssertNil(recognizer.process(frame: frame(0.02, [touch(1, 0.3), touch(2, 0.5)])))
        XCTAssertNil(recognizer.process(frame: frame(0.04, [touch(1, 0.3), touch(2, 0.5), touch(3, 0.7)])))
        XCTAssertEqual(recognizer.process(frame: frame(0.05, [])), .swipe(fingers: 3, direction: .right))
    }

}
