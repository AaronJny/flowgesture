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
        XCTAssertEqual(probe.report.transportEnvelopes.count, 2)
        XCTAssertEqual(probe.report.transportEnvelopes.map(\.tapGeneration), [1, 2])
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

    private var emptyFixtureFields: QuartzReplayProbe.FixtureFields {
        .init(flagsRawValue: 0, publicMotionFields: [:])
    }

    func testFieldDiagnosticsRetainExactFlagsAndCheckedMotionValues() throws {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                        wheel1: 0, wheel2: 0, wheel3: 0))
        event.flags = []
        let before = QuartzReplayProbe.fixtureFields(event)
        XCTAssertEqual(before.flagsRawValue, 0)
        XCTAssertEqual(before.publicMotionFields.count, 11)
        XCTAssertTrue(before.publicMotionFields.values.allSatisfy { $0 == 0 })
        event.flags = .maskNonCoalesced
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: 1)
        let after = QuartzReplayProbe.fixtureFields(event)
        XCTAssertEqual(after.flagsRawValue, CGEventFlags.maskNonCoalesced.rawValue)
        XCTAssertEqual(after.publicMotionFields["pointDeltaAxis2"], 1)
        XCTAssertEqual(QuartzReplayProbe.fixtureRejections(type: .scrollWheel, event: event),
                       ["flags=0x\(String(CGEventFlags.maskNonCoalesced.rawValue, radix: 16))", "pointDeltaAxis2=1.0"])
        XCTAssertFalse(QuartzReplayProbe.isHarmlessFixture(type: .scrollWheel, event: event))
        // Capturing diagnostics must not mutate an event or its source tag.
        XCTAssertEqual(QuartzReplayProbe.fixtureFields(event), after)
    }

    private func transportControl(flags: [UInt64], pids: [Int64] = [123, 123, 123]) throws -> QuartzReplayProbe.Delivery {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                        wheel1: 0, wheel2: 0, wheel3: 0))
        event.flags = []
        let posted = QuartzReplayProbe.fixtureFields(event)
        let stages: [QuartzReplayProbe.Stage] = [.head, .admission, .tail]
        let observations = stages.enumerated().map { index, stage in
            QuartzReplayProbe.Observation(ordinal: index + 1, stage: stage,
                callbackType: CGEventType.scrollWheel.rawValue, eventType: CGEventType.scrollWheel.rawValue,
                sourceTag: 7, sourcePID: pids[index], uptime: 0,
                fields: .init(flagsRawValue: flags[index], publicMotionFields: posted.publicMotionFields))
        }
        return QuartzReplayProbe.Delivery(name: "control", sourceTag: 7, expectedStages: stages,
            observations: observations, postedFields: posted, postedSourcePID: 123, calibrationControl: true)
    }

    func testTransportCalibrationRequiresCompleteConsistentPositiveControl() throws {
        let flag = QuartzReplayProbe.observedPostedFlag
        for value in [UInt64(0), flag] {
            let envelope = try QuartzReplayProbe.establishEnvelope(transportControl(flags: [value, value, value]), generation: 1)
            XCTAssertEqual(envelope.flagsRawValue, value)
            XCTAssertEqual(envelope.controlTag, 7)
            XCTAssertEqual(envelope.sourcePID, 123)
        }
        XCTAssertThrowsError(try QuartzReplayProbe.establishEnvelope(transportControl(flags: [flag, 0, flag]), generation: 1))
        XCTAssertThrowsError(try QuartzReplayProbe.establishEnvelope(transportControl(flags: [flag, flag, flag], pids: [123, 124, 123]), generation: 1))
        XCTAssertThrowsError(try QuartzReplayProbe.establishEnvelope(transportControl(flags: [flag | 1, flag | 1, flag | 1]), generation: 1))
        var control = try transportControl(flags: [flag, flag, flag])
        control.observations.removeLast()
        XCTAssertThrowsError(try QuartzReplayProbe.establishEnvelope(control, generation: 1))
        control = try transportControl(flags: [flag, flag, flag])
        control.calibrationControl = false
        XCTAssertThrowsError(try QuartzReplayProbe.establishEnvelope(control, generation: 1))
        control = try transportControl(flags: [flag, flag, flag])
        control.postedFields = .init(flagsRawValue: flag, publicMotionFields: try XCTUnwrap(control.postedFields).publicMotionFields)
        XCTAssertThrowsError(try QuartzReplayProbe.establishEnvelope(control, generation: 1))
        control = try transportControl(flags: [flag, flag, flag])
        var fields = try XCTUnwrap(control.postedFields).publicMotionFields
        fields["scrollPhase"] = 1
        control.postedFields = .init(flagsRawValue: 0, publicMotionFields: fields)
        XCTAssertThrowsError(try QuartzReplayProbe.establishEnvelope(control, generation: 1))
    }

    func testReceivedEnvelopeRejectsEveryAdditionalFlagAndCannotRelearn() throws {
        let flag = QuartzReplayProbe.observedPostedFlag
        let envelope = try QuartzReplayProbe.establishEnvelope(transportControl(flags: [flag, flag, flag]), generation: 1)
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                        wheel1: 0, wheel2: 0, wheel3: 0))
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 123)
        event.flags = CGEventFlags(rawValue: flag)
        func reasons(_ selected: QuartzReplayProbe.TransportEnvelope? = nil, control: Bool = false, pid: Int64? = 123) -> [String] {
            QuartzReplayProbe.receivedFixtureRejections(type: .scrollWheel, event: event,
                expectedPID: pid, envelope: selected, calibrationControl: control)
        }
        XCTAssertTrue(reasons(envelope).isEmpty)
        XCTAssertFalse(QuartzReplayProbe.isHarmlessFixture(type: .scrollWheel, event: event), "posting remains strictly zero-flags")
        XCTAssertFalse(reasons().isEmpty, "ordinary fixtures cannot calibrate")
        XCTAssertTrue(reasons(control: true).isEmpty, "only the pass-only control may be observed before calibration")
        XCTAssertFalse(reasons(envelope, control: true).isEmpty, "cannot recalibrate mid-generation")
        XCTAssertFalse(reasons(envelope, pid: nil).isEmpty)
        XCTAssertFalse(reasons(envelope, pid: 0).isEmpty)
        XCTAssertFalse(reasons(envelope, pid: 124).isEmpty)
        event.flags = []
        XCTAssertFalse(reasons(envelope).isEmpty, "even removing bit 29 violates the frozen received envelope")
        // Check the entire raw mask without depending on CGEventSetFlags to
        // retain undocumented bits when constructing an unposted test object.
        for bit in 0..<64 where bit != 29 {
            XCTAssertFalse(QuartzReplayProbe.recognizedFixtureTransportFlags(flag | (UInt64(1) << bit)), "additional bit \(bit)")
        }
        for additional in [UInt64(1), CGEventFlags.maskCommand.rawValue, CGEventFlags.maskNonCoalesced.rawValue] {
            event.flags = CGEventFlags(rawValue: flag | additional)
            XCTAssertFalse(reasons(envelope).isEmpty)
            XCTAssertFalse(reasons(control: true).isEmpty)
        }
        event.flags = CGEventFlags(rawValue: flag)
        event.setDoubleValueField(.scrollWheelEventScrollPhase, value: 1)
        XCTAssertFalse(reasons(envelope).isEmpty)
        XCTAssertFalse(reasons(control: true).isEmpty)
    }

    private func delivery(_ stages: [QuartzReplayProbe.Stage], expected: [QuartzReplayProbe.Stage],
                          firstOrdinal: Int = 1, tag: Int64 = 7) -> QuartzReplayProbe.Delivery {
        QuartzReplayProbe.Delivery(name: "test", sourceTag: tag, expectedStages: expected,
                                   observations: stages.enumerated().map { offset, stage in
            QuartzReplayProbe.Observation(ordinal: firstOrdinal + offset, stage: stage,
                callbackType: CGEventType.scrollWheel.rawValue, eventType: CGEventType.scrollWheel.rawValue,
                sourceTag: tag, sourcePID: 123, uptime: 0, fields: emptyFixtureFields)
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
            callbackType: 30, eventType: CGEventType.scrollWheel.rawValue, sourceTag: 7, sourcePID: 123, uptime: 0, fields: emptyFixtureFields)
        XCTAssertFalse(QuartzReplayProbe.validationErrors([fixture]).isEmpty)
        fixture = delivery(stages, expected: stages)
        fixture.observations[1] = QuartzReplayProbe.Observation(ordinal: 2, stage: .admission,
            callbackType: CGEventType.scrollWheel.rawValue, eventType: CGEventType.scrollWheel.rawValue,
            sourceTag: 8, sourcePID: 123, uptime: 0, fields: emptyFixtureFields)
        XCTAssertFalse(QuartzReplayProbe.validationErrors([fixture]).isEmpty)
    }
}
