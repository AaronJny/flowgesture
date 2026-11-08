import XCTest
@testable import FlowGestureCore

final class NativeHorizontalSwipeArbitratorTests: XCTestCase {
    typealias A = NativeHorizontalSwipeArbitrator
    private let gate = A.TestGate(explicitlyEnabled: true, runningOSBuild: "fixture-build",
                                  validatedOSBuild: "fixture-build", completeStreamValidated: true)
    private let eligible = A.Eligibility(senderRegistryID: 42, leftActionID: "left", rightActionID: "right", wholeFamilyEligible: true)
    private func event(_ phase: Int64, sender: UInt64? = 42, progress: Double = 0,
                       velocity: Double = 0, kind: Int64 = 30, hid: Int64 = 23,
                       axis: Int64 = 1, pid: Int64 = 0) -> NativeHorizontalSwipeEvent {
        .init(eventClass: kind, hidType: hid, axis: axis, phase: phase, senderRegistryID: sender,
              sourcePID: pid, progress: progress, velocityX: velocity)
    }
    func testDefaultAndMismatchedGateNeverClaim() {
        for g in [A.TestGate(), A.TestGate(explicitlyEnabled: true, runningOSBuild: "new",
                                          validatedOSBuild: "old", completeStreamValidated: true),
                  A.TestGate(explicitlyEnabled: true, runningOSBuild: "same", validatedOSBuild: "same")] {
            var a = A()
            XCTAssertFalse(a.process(event(1), gate: g, eligibility: eligible).consume)
            XCTAssertFalse(a.process(event(2, progress: 1), gate: gate, eligibility: eligible).consume)
        }
    }
    func testOwnershipFreezesEligibilityAndFiresOnce() {
        var a = A()
        let begin = a.process(event(1), gate: gate, eligibility: eligible)
        XCTAssertTrue(begin.consume)
        let changed = a.process(event(2, progress: 0.2), gate: gate, eligibility: nil)
        XCTAssertEqual(changed.actionID, "right")
        XCTAssertEqual(changed.ownership, begin.ownership)
        XCTAssertNil(a.process(event(2, progress: -1), gate: gate, eligibility: eligible).actionID)
        let end = a.process(event(4, progress: -1), gate: gate, eligibility: eligible)
        XCTAssertTrue(end.consume); XCTAssertTrue(end.terminal); XCTAssertNil(end.actionID)
        XCTAssertTrue(a.isCurrent(begin.ownership!))
        a.interrupt()
        XCTAssertFalse(a.isCurrent(begin.ownership!))
    }
    func testMayBeginThenBeginAndFlickFallback() {
        var a = A()
        XCTAssertTrue(a.process(event(128), gate: gate, eligibility: eligible).consume)
        XCTAssertTrue(a.process(event(1), gate: gate, eligibility: eligible).consume)
        XCTAssertEqual(a.process(event(4, velocity: -250), gate: gate, eligibility: eligible).actionID, "left")
    }
    func testPartialFamilyAndWrongSourceDoNotClaim() {
        for e in [A.Eligibility(senderRegistryID: 42, leftActionID: "left", rightActionID: "", wholeFamilyEligible: true),
                  A.Eligibility(senderRegistryID: 42, leftActionID: "left", rightActionID: "right", wholeFamilyEligible: false),
                  A.Eligibility(senderRegistryID: 99, leftActionID: "left", rightActionID: "right", wholeFamilyEligible: true)] {
            var a = A()
            XCTAssertFalse(a.process(event(128), gate: gate, eligibility: e).consume)
            XCTAssertFalse(a.process(event(1), gate: gate, eligibility: eligible).consume)
            XCTAssertFalse(a.process(event(2, progress: 1), gate: gate, eligibility: eligible).consume)
            XCTAssertFalse(a.process(event(4), gate: gate, eligibility: eligible).consume)
            XCTAssertTrue(a.process(event(1), gate: gate, eligibility: eligible).consume)
        }
    }
    func testOrphanCannotClaimMidstream() {
        var a = A()
        XCTAssertFalse(a.process(event(2, progress: 1), gate: gate, eligibility: eligible).consume)
        XCTAssertFalse(a.process(event(1), gate: gate, eligibility: eligible).consume)
        XCTAssertFalse(a.process(event(4), gate: gate, eligibility: eligible).consume)
        XCTAssertTrue(a.process(event(1), gate: gate, eligibility: eligible).consume)
    }
    func testMalformedOrSourceChangeRequiresVerifiedIdle() {
        for invalid in [event(2, sender: nil), event(2, sender: 0), event(2, sender: 99),
                        event(3), event(2, progress: .nan), event(2, velocity: .infinity), event(1), event(128), event(0)] {
            var a = A()
            let owner = a.process(event(1), gate: gate, eligibility: eligible).ownership!
            let result = a.process(invalid, gate: gate, eligibility: eligible)
            XCTAssertFalse(result.consume); XCTAssertTrue(result.requiresIdleReset)
            XCTAssertFalse(a.isCurrent(owner))
            XCTAssertFalse(a.process(event(4), gate: gate, eligibility: eligible).consume)
            XCTAssertFalse(a.process(event(1), gate: gate, eligibility: eligible).consume)
            a.resetAfterVerifiedIdle()
            XCTAssertTrue(a.process(event(1), gate: gate, eligibility: eligible).consume)
        }
    }
    func testCompanionsSyntheticAndOtherFamiliesNeverConsumed() {
        var a = A()
        _ = a.process(event(1), gate: gate, eligibility: eligible)
        for other in [event(2, progress: 1, kind: 29), event(4, pid: 123), event(2, kind: 22),
                      event(2, axis: 2), event(2, hid: 99)] {
            XCTAssertFalse(a.process(other, gate: gate, eligibility: eligible).consume)
        }
        XCTAssertEqual(a.process(event(2, progress: 0.2), gate: gate, eligibility: eligible).actionID, "right")
    }
    func testCancelAndUncommittedEndDoNotInventActionOrRepair() {
        for phase in [Int64(4), 8] {
            var a = A()
            _ = a.process(event(1), gate: gate, eligibility: eligible)
            let end = a.process(event(phase), gate: gate, eligibility: eligible)
            XCTAssertTrue(end.consume); XCTAssertTrue(end.terminal); XCTAssertNil(end.actionID)
        }
    }
    func testCancellationInvalidatesAnAlreadyQueuedAction() {
        var a = A()
        _ = a.process(event(1), gate: gate, eligibility: eligible)
        let changed = a.process(event(2, progress: 0.2), gate: gate, eligibility: eligible)
        XCTAssertEqual(changed.actionID, "right")
        let token = changed.ownership!
        XCTAssertTrue(a.isCurrent(token))
        let cancelled = a.process(event(8), gate: gate, eligibility: eligible)
        XCTAssertTrue(cancelled.consume)
        XCTAssertNil(cancelled.actionID)
        XCTAssertFalse(a.isCurrent(token))
    }

    func testGateWithdrawalAndTimeoutInvalidateTokens() {
        var a = A()
        let token = a.process(event(1), gate: gate, eligibility: eligible).ownership!
        XCTAssertTrue(a.process(event(2), gate: .init(), eligibility: eligible).requiresIdleReset)
        XCTAssertFalse(a.isCurrent(token))
        a.resetAfterVerifiedIdle()
        let next = a.process(event(1), gate: gate, eligibility: eligible).ownership!
        XCTAssertNotEqual(next, token)
        a.interrupt()
        XCTAssertFalse(a.isCurrent(next))
        XCTAssertFalse(a.process(event(1), gate: gate, eligibility: eligible).consume)
    }
    func testDecoderRecognizesOnlyExactDocumentedValues() {
        XCTAssertTrue(event(1, kind: 29).hasHorizontalFingerprint)
        XCTAssertFalse(event(1, kind: 31).hasHorizontalFingerprint)
        XCTAssertNil(event(3).phase) // Do not guess that phase fields are combinable masks.
        for phase in [Int64(0), 1, 2, 4, 8, 128] { XCTAssertNotNil(event(phase).phase) }
    }
}
