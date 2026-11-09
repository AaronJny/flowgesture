#if os(macOS)
import XCTest
@testable import FlowGestureApp

final class ForegroundSmokeStageWaitTests: XCTestCase {
    private let side = ["keyDown(38)", "keyUp(38)"]
    private var all: [String] { side + ["keyDown(37)", "keyUp(37)"] }

    private func stage(expected: [String]) -> ForegroundSmokeStageWait<String> {
        ForegroundSmokeStageWait(expected: expected, deadline: 2.275, overallDeadline: 15, settleInterval: 0.25)
    }

    func testTimelyAuditEvidenceSurvivesTheObservedIntelPollDelay() {
        var wait = stage(expected: side)
        wait.observe(events: [], condition: false, at: 0.275)
        wait.observe(events: [side[0]], condition: true, at: 0.297)
        XCTAssertNil(wait.matchingSince, "A partial pair cannot start settling")
        wait.observe(events: side, condition: true, at: 0.298)
        XCTAssertEqual(wait.matchingSince, 0.298)
        XCTAssertEqual(wait.result(at: 0.4), .waiting)

        // CI received both events at +0.298s, but did not poll until +3.504s.
        // Rechecking the predicate must preserve evidence, not backdate new state.
        wait.observe(events: side, condition: true, at: 3.504)
        XCTAssertEqual(wait.matchingSince, 0.298)
        XCTAssertEqual(wait.result(at: 3.504), .passed)
    }

    func testConditionFirstObservedByLatePollIsNotBackdated() {
        var wait = stage(expected: side)
        wait.observe(events: side, condition: false, at: 0.298)
        wait.observe(events: side, condition: true, at: 3.504)
        XCTAssertEqual(wait.matchingSince, 3.504)
        XCTAssertEqual(wait.result(at: 3.504), .stageDeadline)
    }

    func testKeyUpFirstObservedAfterDeadlineStillFails() {
        var wait = stage(expected: side)
        wait.observe(events: [side[0]], condition: true, at: 0.298)
        wait.observe(events: side, condition: true, at: 2.3)
        XCTAssertEqual(wait.result(at: 3.504), .stageDeadline)
    }

    func testSettlingMustAlsoFitInsideTheStageDeadline() {
        var wait = stage(expected: side)
        wait.observe(events: side, condition: true, at: 2.1)
        XCTAssertEqual(wait.result(at: 2.2), .waiting)
        XCTAssertEqual(wait.result(at: 3.504), .stageDeadline)
    }

    func testNonActionStagesAcceptOnlyTimelyConditionEvidence() {
        // Readiness has no output; editing and pause retain the four prior events.
        for expected in [[], all] {
            var timely = stage(expected: expected)
            timely.observe(events: expected, condition: false, at: 0.275)
            timely.observe(events: expected, condition: true, at: 0.4)
            timely.observe(events: expected, condition: true, at: 3.504)
            XCTAssertEqual(timely.result(at: 3.504), .passed)

            var late = stage(expected: expected)
            late.observe(events: expected, condition: false, at: 0.275)
            late.observe(events: expected, condition: true, at: 3.504)
            XCTAssertEqual(late.result(at: 3.504), .stageDeadline)
        }
    }

    func testFalseConditionResetsTheQuietInterval() {
        var wait = stage(expected: all)
        wait.observe(events: all, condition: true, at: 0.3)
        wait.observe(events: all, condition: false, at: 0.4)
        XCTAssertNil(wait.matchingSince)
        wait.observe(events: all, condition: true, at: 0.6)
        XCTAssertEqual(wait.matchingSince, 0.6)
        XCTAssertEqual(wait.result(at: 0.7), .waiting)
        XCTAssertEqual(wait.result(at: 0.86), .passed)
    }

    func testFalseConditionAtDelayedPollRejectsEarlierEvidence() {
        var wait = stage(expected: all)
        wait.observe(events: all, condition: true, at: 0.3)
        wait.observe(events: all, condition: false, at: 3.504)
        XCTAssertEqual(wait.result(at: 3.504), .stageDeadline)
    }

    func testExtraEventsAfterSettlingStillFailAtDelayedPoll() {
        for extra in [[side[0]], side] {
            var wait = stage(expected: side)
            wait.observe(events: side, condition: true, at: 0.298)
            wait.observe(events: side + extra, condition: true, at: 3.0)
            XCTAssertEqual(wait.result(at: 3.504), .invalidSequence)
        }
    }

    func testWrongKeyAndReversedOrDuplicateDownEventsFail() {
        for invalid in [["keyDown(37)"], [side[1]], [side[0], side[0]]] {
            var wait = stage(expected: side)
            wait.observe(events: invalid, condition: true, at: 0.298)
            XCTAssertEqual(wait.result(at: 0.3), .invalidSequence)
        }
    }

    func testDelayedSideDuplicateCannotBecomeTheKeyboardPair() {
        var wait = stage(expected: all)
        wait.observe(events: side, condition: false, at: 0.275)
        wait.observe(events: side + side, condition: true, at: 0.4)
        XCTAssertEqual(wait.result(at: 0.7), .invalidSequence)
    }

    func testInvalidSequenceCannotBeClearedByLaterValidObservation() {
        var wait = stage(expected: side)
        wait.observe(events: side + side, condition: true, at: 0.3)
        wait.observe(events: side, condition: true, at: 0.4)
        XCTAssertEqual(wait.result(at: 0.7), .invalidSequence)
    }

    func testTimelyEvidenceNeverExtendsTheOverallDeadline() {
        var wait = stage(expected: side)
        wait.observe(events: side, condition: true, at: 0.298)
        XCTAssertEqual(wait.result(at: 14.999), .passed)
        XCTAssertEqual(wait.result(at: 15), .overallDeadline)
        XCTAssertEqual(wait.result(at: 16), .overallDeadline)
    }
}
#endif
