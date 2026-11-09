import CoreGraphics
import Foundation
import XCTest
@testable import FlowGestureApp

final class QuartzReplayProbeTests: XCTestCase {
    func testOptInLiveQuartzReplay() throws {
        guard ProcessInfo.processInfo.environment["FLOWGESTURE_RUN_QUARTZ_REPLAY"] == "1" else {
            throw XCTSkip("Live Quartz posting is opt-in; use scripts/test-quartz-replay.sh on a disposable macOS session")
        }
        let probe = try QuartzReplayProbe()
        let path = ProcessInfo.processInfo.environment["FLOWGESTURE_QUARTZ_REPLAY_REPORT"]
        do {
            try probe.run()
            if let path { try probe.writeReport(to: path) }
        } catch {
            if let path { try probe.writeReport(to: path) }
            throw error
        }
        XCTAssertEqual(probe.report.status, "passed")
        XCTAssertEqual(probe.report.deliveries.count, 11)
        XCTAssertEqual(probe.report.admittedHarmlessCounters, 3)
        XCTAssertEqual(probe.report.tapGenerations, 2)
        XCTAssertEqual(probe.report.invalidatedTaps, 6)
        print("PASS: live public Quartz fixture routing, exact source tags, admission, forwarding, consumption and teardown; NOT physical/native gesture suppression")
    }

    func testFixtureGateRejectsMotionModifiersPhasesAndCallbackMismatch() throws {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                        wheel1: 0, wheel2: 0, wheel3: 0))
        event.flags = []
        XCTAssertTrue(QuartzReplayProbe.isHarmlessFixture(type: .scrollWheel, event: event))
        XCTAssertFalse(QuartzReplayProbe.isHarmlessFixture(type: .mouseMoved, event: event))
        XCTAssertFalse(QuartzReplayProbe.isHarmlessFixture(type: try XCTUnwrap(CGEventType(rawValue: 30)), event: event))
        event.flags = .maskCommand
        XCTAssertFalse(QuartzReplayProbe.isHarmlessFixture(type: .scrollWheel, event: event))
        event.flags = []
        let fields: [CGEventField] = [.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2, .scrollWheelEventDeltaAxis3,
                                    .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis3,
                                    .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventPointDeltaAxis3,
                                    .scrollWheelEventScrollPhase, .scrollWheelEventMomentumPhase]
        for field in fields {
            event.setDoubleValueField(field, value: 1)
            XCTAssertFalse(QuartzReplayProbe.isHarmlessFixture(type: .scrollWheel, event: event), "\(field)")
            event.setDoubleValueField(field, value: 0)
        }
    }

    func testSyntheticAdmissionIsOneUseAndInterruptionRevokesIt() throws {
        let admission = try QuartzReplayProbe.Admission()
        XCTAssertTrue(try admission.take())
        XCTAssertFalse(try admission.take())
        XCTAssertEqual(admission.count, 1)
        let interrupted = try QuartzReplayProbe.Admission()
        interrupted.coordinator.interrupt()
        XCTAssertFalse(try interrupted.take())
        XCTAssertEqual(interrupted.count, 0)
    }

    private func delivery(_ stages: [QuartzReplayProbe.Stage], expected: [QuartzReplayProbe.Stage],
                          firstOrdinal: Int = 1, tag: Int64 = 7) -> QuartzReplayProbe.Delivery {
        QuartzReplayProbe.Delivery(name: "test", sourceTag: tag, expectedStages: expected,
                                   observations: stages.enumerated().map { offset, stage in
            QuartzReplayProbe.Observation(ordinal: firstOrdinal + offset, stage: stage,
                callbackType: CGEventType.scrollWheel.rawValue, eventType: CGEventType.scrollWheel.rawValue,
                sourceTag: tag, sourcePID: 123, uptime: 0)
        })
    }
    func testEvidenceRequiresPositiveControlsAndExactOrdering() {
        let forward: [QuartzReplayProbe.Stage] = [.head, .admission, .tail]
        let consume: [QuartzReplayProbe.Stage] = [.head, .admission]
        let consumed = delivery(consume, expected: consume)
        let sentinel = delivery(forward, expected: forward, firstOrdinal: 3)
        XCTAssertTrue(QuartzReplayProbe.validationErrors([consumed, sentinel]).isEmpty)
        XCTAssertFalse(QuartzReplayProbe.validationErrors([]).isEmpty)
        XCTAssertFalse(QuartzReplayProbe.validationErrors([consumed]).isEmpty)
        XCTAssertFalse(QuartzReplayProbe.validationErrors([delivery([], expected: forward)]).isEmpty)
        XCTAssertFalse(QuartzReplayProbe.validationErrors([delivery(forward, expected: consume), sentinel]).isEmpty)
        XCTAssertFalse(QuartzReplayProbe.validationErrors([delivery([.admission, .head, .tail], expected: forward)]).isEmpty)
        XCTAssertFalse(QuartzReplayProbe.validationErrors([consumed, delivery(forward, expected: forward)]).isEmpty)
        XCTAssertFalse(QuartzReplayProbe.validationErrors([delivery([.head, .admission, .tail, .tail], expected: forward)]).isEmpty)
    }

    func testEvidenceRejectsCallbackOrSourceTagMutation() {
        let stages: [QuartzReplayProbe.Stage] = [.head, .admission, .tail]
        var fixture = delivery(stages, expected: stages)
        fixture.observations[1] = QuartzReplayProbe.Observation(ordinal: 2, stage: .admission,
            callbackType: 30, eventType: CGEventType.scrollWheel.rawValue, sourceTag: 7, sourcePID: 123, uptime: 0)
        XCTAssertFalse(QuartzReplayProbe.validationErrors([fixture]).isEmpty)
        fixture = delivery(stages, expected: stages)
        fixture.observations[1] = QuartzReplayProbe.Observation(ordinal: 2, stage: .admission,
            callbackType: CGEventType.scrollWheel.rawValue, eventType: CGEventType.scrollWheel.rawValue,
            sourceTag: 8, sourcePID: 123, uptime: 0)
        XCTAssertFalse(QuartzReplayProbe.validationErrors([fixture]).isEmpty)
    }
}
