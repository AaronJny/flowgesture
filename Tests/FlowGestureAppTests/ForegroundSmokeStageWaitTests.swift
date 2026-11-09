#if os(macOS)
import XCTest
import Dispatch
import CoreGraphics
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

    func testLatestIntelLatePairFailsEvenWithTimelyDiagnosticPosts() {
        let trace = ForegroundSmokeTrace()
        trace.start(at: 0)
        trace.record("fixture.post.begin", at: 0.280)
        trace.record("fixture.post.end", at: 0.284)
        trace.record("action.post.end", at: 0.300)
        var wait = ForegroundSmokeStageWait(expected: side, deadline: 2.285, overallDeadline: 15, settleInterval: 0.25)
        wait.observe(events: [], condition: false, at: 0.285)
        // Run 42616627310 first observed BOTH events and the predicate here.
        // Even an earlier producer timestamp cannot backdate consumer evidence.
        wait.observe(events: [side[0]], condition: true, at: 3.682)
        wait.observe(events: side, condition: true, at: 3.682)
        trace.record("action.audit", at: 3.682)
        XCTAssertEqual(wait.matchingSince, 3.682)
        XCTAssertEqual(wait.result(at: 3.682), .stageDeadline)
        XCTAssertEqual(wait.result(at: 4), .stageDeadline)
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

final class ForegroundSmokeTraceTests: XCTestCase {
    func testRecorderIsInactiveUntilExplicitlyStarted() {
        let trace = ForegroundSmokeTrace()
        trace.record("before start", at: 1)
        trace.runLoopBoundary("beforeWaiting", at: 2)
        XCTAssertNil(trace.snapshot().startedAt)
        XCTAssertTrue(trace.snapshot().entries.isEmpty)
        XCTAssertNil(trace.snapshot().lastRunLoopBoundary)
        trace.start(at: 3)
        trace.record("fixture.post.begin", at: 3.1)
        XCTAssertEqual(trace.snapshot().entries, [.init(time: 3.1, detail: "fixture.post.begin")])
    }

    func testBoundedTracePreservesFirstEvidenceAndReportsOverflow() {
        let trace = ForegroundSmokeTrace(capacity: 2)
        trace.start(at: 10)
        trace.record("fixture.post.begin", at: 10.1)
        trace.record("fixture.post.end", at: 10.2)
        trace.record("engine.handle.begin", at: 13.6)
        trace.record("action.audit", at: 13.7)
        let snapshot = trace.snapshot()
        XCTAssertEqual(snapshot.entries.map(\.time), [10.1, 10.2])
        XCTAssertEqual(snapshot.dropped, 2)
    }

    func testRunLoopGapsKeepTheirActualBoundariesWithoutAssumingCause() {
        let trace = ForegroundSmokeTrace()
        trace.start(at: 10)
        trace.runLoopBoundary("beforeWaiting", at: 10.1)
        trace.runLoopBoundary("afterWaiting", at: 10.12)
        XCTAssertTrue(trace.snapshot().entries.isEmpty, "Do not fill the trace with healthy loop turns")
        trace.runLoopBoundary("beforeWaiting", at: 13.5)
        trace.runLoopBoundary("afterWaiting", at: 13.9)
        let entries = trace.snapshot().entries
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].time, 13.5)
        XCTAssertTrue(entries[0].detail.contains("from=afterWaiting at=+0.120000s to=beforeWaiting"))
        XCTAssertEqual(entries[1].time, 13.9)
        XCTAssertTrue(entries[1].detail.contains("from=beforeWaiting at=+3.500000s to=afterWaiting"))
        XCTAssertEqual(trace.snapshot().lastRunLoopBoundary, ForegroundSmokeTrace.Entry(time: 13.9, detail: "afterWaiting"))
    }

    func testRestartClearsOldStageAndLoopEvidence() {
        let trace = ForegroundSmokeTrace(capacity: 1)
        trace.start(at: 0)
        trace.record("old", at: 1)
        trace.record("overflow", at: 2)
        trace.runLoopBoundary("afterWaiting", at: 3)
        trace.start(at: 10)
        let snapshot = trace.snapshot()
        XCTAssertEqual(snapshot.startedAt, 10)
        XCTAssertTrue(snapshot.entries.isEmpty)
        XCTAssertEqual(snapshot.dropped, 0)
        XCTAssertNil(snapshot.lastRunLoopBoundary)
    }

    func testOnlyExactFixtureAndOutputTagsAreEligible() {
        XCTAssertNotEqual(ForegroundSmokeTrace.inputTag, EventEngine.syntheticTag,
                          "Fixture input must traverse matching, not the synthetic-output bypass")
        XCTAssertTrue(ForegroundSmokeTrace.accepts(tag: ForegroundSmokeTrace.inputTag, sourcePID: 42, currentPID: 42))
        XCTAssertTrue(ForegroundSmokeTrace.accepts(tag: EventEngine.syntheticTag, sourcePID: 42, currentPID: 42))
        let unrelatedTags: [Int64] = [0, 1, -1, ForegroundSmokeTrace.inputTag + 1, EventEngine.syntheticTag + 1]
        for tag in unrelatedTags {
            XCTAssertFalse(ForegroundSmokeTrace.accepts(tag: tag, sourcePID: 42, currentPID: 42))
        }
    }

    func testForeignOrMissingSourcePIDCannotBroadenFixtureCorrelation() {
        let unrelatedPIDs: [Int64] = [0, -1, 41, 43]
        for tag in [ForegroundSmokeTrace.inputTag, EventEngine.syntheticTag] {
            for sourcePID in unrelatedPIDs {
                XCTAssertFalse(ForegroundSmokeTrace.accepts(tag: tag, sourcePID: sourcePID, currentPID: 42))
            }
            XCTAssertFalse(ForegroundSmokeTrace.accepts(tag: tag, sourcePID: 0, currentPID: 0))
        }
    }

    func testSourceDescriptionDistinguishesReadbackTagsAndObservedProcessMatch() {
        let input = ForegroundSmokeTrace.describeSource(tag: ForegroundSmokeTrace.inputTag, sourcePID: 42, currentPID: 42)
        XCTAssertTrue(input.contains("tagClass=fixture-input-tag"))
        XCTAssertTrue(input.contains("observedSourcePID=42 sourceProcessMatch=true"))
        let foreignOutput = ForegroundSmokeTrace.describeSource(tag: EventEngine.syntheticTag, sourcePID: 43, currentPID: 42)
        XCTAssertTrue(foreignOutput.contains("tagClass=engine-synthetic-tag"))
        XCTAssertTrue(foreignOutput.contains("observedSourcePID=43 sourceProcessMatch=false"))
        let unknown = ForegroundSmokeTrace.describeSource(tag: 0, sourcePID: 0, currentPID: 42)
        XCTAssertTrue(unknown.contains("observedTag=0 tagClass=unknown/unconfirmed-tag"))
        XCTAssertTrue(unknown.contains("observedSourcePID=0 sourceProcessMatch=false"))
        XCTAssertFalse(unknown.contains("engine-synthetic"))
    }

    func testMouseEventDescriptionUsesActualTagAndPIDReadback() throws {
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                                          mouseCursorPosition: .zero, mouseButton: .center))
        event.setIntegerValueField(.eventSourceUserData, value: ForegroundSmokeTrace.inputTag)
        // Some CGEvent constructors may ignore a tag setter. Assert what was
        // read back rather than requiring or fabricating the requested value.
        let tag = event.getIntegerValueField(.eventSourceUserData)
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        let description = ForegroundSmokeTrace.describe(event)
        XCTAssertTrue(description.contains("observedTag=\(tag)"))
        XCTAssertTrue(description.contains("observedSourcePID=\(sourcePID)"))
        XCTAssertTrue(description.contains(ForegroundSmokeTrace.describeSource(tag: tag, sourcePID: sourcePID)))
        if tag != ForegroundSmokeTrace.inputTag && tag != EventEngine.syntheticTag {
            XCTAssertTrue(description.contains("unknown/unconfirmed-tag"))
            XCTAssertFalse(description.contains("engine-synthetic-tag"))
        }
    }

    func testEngineSyntheticReplayAndUnrelatedKeysAreNotFixtureOutputs() {
        let fixtureKeys: [Int64] = [37, 38]
        for type in [CGEventType.keyDown, .keyUp] {
            for keyCode in fixtureKeys {
                XCTAssertTrue(ForegroundSmokeTrace.acceptsOutput(type: type, keyCode: keyCode))
            }
            XCTAssertFalse(ForegroundSmokeTrace.acceptsOutput(type: type, keyCode: 0))
            XCTAssertFalse(ForegroundSmokeTrace.acceptsOutput(type: type, keyCode: 40))
        }
        for type in [CGEventType.otherMouseDown, .otherMouseUp, .scrollWheel] {
            XCTAssertFalse(ForegroundSmokeTrace.acceptsOutput(type: type, keyCode: 37))
        }
    }

    func testConcurrentProducerAndWatchdogSnapshotsRemainBounded() {
        let trace = ForegroundSmokeTrace(capacity: 32)
        trace.start(at: 0)
        DispatchQueue.concurrentPerform(iterations: 128) { index in
            trace.record("action worker", at: Double(index))
            _ = trace.snapshot()
        }
        let snapshot = trace.snapshot()
        XCTAssertEqual(snapshot.entries.count, 32)
        XCTAssertEqual(snapshot.dropped, 96)
    }
}
#endif
