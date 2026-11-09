import XCTest
@testable import FlowGestureCore

/// All fixtures are SIMULATED channel orderings, not captured physical traces.
/// The invented build string and affirmative source/identity evidence only exercise
/// caller contracts. They are NOT a macOS capability profile or hardware validation.
final class NativeRawGestureCoordinatorTests: XCTestCase {
    typealias C = NativeRawGestureCoordinator
    typealias A = NativeHorizontalSwipeArbitrator
    private let pad = C.RawDevice(deviceID: 7, registryID: 42, scope: .trackpad)
    private let otherPad = C.RawDevice(deviceID: 8, registryID: 43, scope: .trackpad)
    // Authored fixtures explicitly assume the native/raw pairing. This bookkeeping
    // is NOT a production correlation algorithm or evidence that timing proves it.
    private var simulatedCorrelations: [ObjectIdentifier: [UInt64: C.RawSession]] = [:]
    private let simulatedGate = A.TestGate(explicitlyEnabled: true,
        runningOSBuild: "SIMULATED-NOT-A-MACOS-BUILD", validatedOSBuild: "SIMULATED-NOT-A-MACOS-BUILD",
        completeStreamValidated: true)
    private func eligibility(_ sender: UInt64 = 42) -> A.Eligibility {
        .init(senderRegistryID: sender, leftActionID: "simulated-left", rightActionID: "simulated-right",
              wholeFamilyEligible: true)
    }
    private func event(_ phase: NativeHorizontalSwipeEvent.Phase, sender: UInt64 = 42,
                       progress: Double = 0, eventClass: Int64 = 30) -> NativeHorizontalSwipeEvent {
        .init(eventClass: eventClass, hidType: 23, axis: 1, phase: phase.rawValue,
              senderRegistryID: sender, progress: progress,
              sourceProvenance: .independentlyVerifiedPhysical)
    }
    private func frame(_ time: Double, x: Double = 0.2, count: Int = 3) -> TouchFrame {
        .init(timestamp: time, touches: (0..<count).map {
            TouchSample(id: $0, location: .init(x: x + Double($0) * 0.15, y: 0.5))
        })
    }
    private func native(_ c: C, _ phase: NativeHorizontalSwipeEvent.Phase,
                        sender: UInt64 = 42, progress: Double = 0) -> C.NativeDecision {
        c.processNative(event(phase, sender: sender, progress: progress),
                        gate: simulatedGate, eligibility: eligibility(sender),
                        correlatedRawSession: simulatedCorrelations[ObjectIdentifier(c)]?[sender])
    }
    private func acquire(_ c: C, _ time: Double, x: Double = 0.2, count: Int = 3,
                         device: C.RawDevice? = nil) throws -> C.RawFrameTicket {
        let source = device ?? pad
        let ticket = try XCTUnwrap(c.acquireRawFrame(device: source, frame: frame(time, x: x, count: count)))
        if let registryID = source.registryID {
            simulatedCorrelations[ObjectIdentifier(c), default: [:]][registryID] = ticket.session
        }
        return ticket
    }
    private func rawCandidate(_ c: C, time: Double = 0, device: C.RawDevice? = nil) throws -> C.ActionTicket {
        let down = try acquire(c, time, device: device)
        let moved = try acquire(c, time + 0.1, x: 0.4, device: device)
        XCTAssertNil(c.deliverRawFrame(down))
        return try XCTUnwrap(c.deliverRawFrame(moved))
    }

    func testDefaultGateAndUnknownProvenanceDoNotReserveRaw() throws {
        for unverifiedSource in [false, true] {
            let c = C()
            let raw = try rawCandidate(c)
            let input = unverifiedSource
                ? NativeHorizontalSwipeEvent(eventClass: 30, hidType: 23, axis: 1, phase: 1,
                                             senderRegistryID: 42)
                : event(.began)
            let result = c.processNative(input, gate: unverifiedSource ? simulatedGate : .init(),
                                         eligibility: eligibility(), correlatedRawSession: raw.session)
            XCTAssertFalse(result.consume)
            XCTAssertNil(result.action)
            XCTAssertEqual(c.takeAction(raw), .raw(deviceID: 7, gesture: .swipe(fingers: 3, direction: .right)))
        }
    }

    func testReservationRevokesRawCandidateBeforeReturningConsume() throws {
        let c = C()
        let raw = try rawCandidate(c)
        XCTAssertTrue(native(c, .began).consume)
        // This dispatch attempt immediately follows the consuming opening result.
        XCTAssertNil(c.takeAction(raw))
        let action = try XCTUnwrap(native(c, .changed, progress: 0.2).action)
        XCTAssertEqual(c.takeAction(action), .native(deviceID: 7, actionID: "simulated-right"))
        XCTAssertNil(c.takeAction(action))
        XCTAssertNil(native(c, .changed, progress: -0.8).action)
    }

    func testRawDispatchWinsBeforeNativeOpeningAndWholeSequencePasses() throws {
        let c = C()
        let raw = try rawCandidate(c)
        XCTAssertNotNil(c.takeAction(raw))
        for phase in [NativeHorizontalSwipeEvent.Phase.mayBegin, .began, .changed, .ended] {
            let result = native(c, phase, progress: 0.4)
            XCTAssertFalse(result.consume)
            XCTAssertNil(result.action)
        }
        XCTAssertNil(c.takeAction(raw))
    }

    func testNativeReservationBlocksLateQueuedRecognitionAndStaggeredRelease() throws {
        let c = C()
        let down = try acquire(c, 0)
        let moved = try acquire(c, 0.1, x: 0.4)
        XCTAssertTrue(native(c, .began).consume)
        let action = try XCTUnwrap(native(c, .changed, progress: 0.2).action)
        XCTAssertTrue(native(c, .ended).consume) // native end is NOT raw all-up
        let two = try acquire(c, 0.2, x: 0.4, count: 2)
        let one = try acquire(c, 0.3, x: 0.4, count: 1)
        let up = try acquire(c, 0.4, count: 0)
        XCTAssertEqual(down.session, up.session)
        for ticket in [down, moved, two, one, up] { XCTAssertNil(c.deliverRawFrame(ticket)) }
        XCTAssertEqual(c.takeAction(action), .native(deviceID: 7, actionID: "simulated-right"))
        let next = try rawCandidate(c, time: 1)
        XCTAssertNotEqual(next.session, down.session)
        XCTAssertNotNil(c.takeAction(next))
    }

    func testRawAllUpBeforeNativeTerminalStillAllowsOneDeferredNativeAction() throws {
        let c = C()
        let down = try acquire(c, 0)
        XCTAssertTrue(native(c, .began).consume)
        let up = try acquire(c, 0.1, count: 0)
        XCTAssertNil(c.deliverRawFrame(down))
        XCTAssertNil(c.deliverRawFrame(up))
        let ended = native(c, .ended, progress: -0.2)
        XCTAssertTrue(ended.consume)
        let action = try XCTUnwrap(ended.action)
        XCTAssertEqual(c.takeAction(action), .native(deviceID: 7, actionID: "simulated-left"))
        XCTAssertNil(c.takeAction(action))
    }

    func testNativeCancellationRevokesTicketAndNeverReleasesRawEarly() throws {
        let c = C()
        let raw = try rawCandidate(c)
        XCTAssertTrue(native(c, .began).consume)
        let action = try XCTUnwrap(native(c, .changed, progress: 0.2).action)
        XCTAssertTrue(native(c, .cancelled).consume)
        XCTAssertNil(c.takeAction(action))
        XCTAssertNil(c.takeAction(raw))
        let late = try acquire(c, 0.2, x: 0.45)
        XCTAssertNil(c.deliverRawFrame(late))
        let up = try acquire(c, 0.3, count: 0)
        XCTAssertNil(c.deliverRawFrame(up))
        XCTAssertNotNil(c.takeAction(try rawCandidate(c, time: 1)))
    }

    func testCaptureInterruptionUsesAcquisitionNotDeliveryState() throws {
        for releaseAlreadyAcquired in [false, true] {
            let c = C()
            let down = try acquire(c, 0)
            XCTAssertTrue(native(c, .began).consume)
            let nativeAction = try XCTUnwrap(native(c, .changed, progress: 0.2).action)
            let moved = try acquire(c, 0.1, x: 0.4)
            let up = releaseAlreadyAcquired ? try acquire(c, 0.2, count: 0) : nil
            c.interrupt()
            XCTAssertNil(c.takeAction(nativeAction))
            XCTAssertNil(c.deliverRawFrame(down))
            XCTAssertNil(c.deliverRawFrame(moved))
            if let up { XCTAssertNil(c.deliverRawFrame(up)) }
            if !releaseAlreadyAcquired {
                XCTAssertFalse(c.resetAfterVerifiedIdle(deviceID: 7, nativeStreamIsIdle: true))
                XCTAssertNil(c.acquireRawFrame(device: pad, frame: frame(0.3, x: 0.4, count: 1)))
                XCTAssertNil(c.acquireRawFrame(device: pad, frame: frame(0.4, count: 0)))
            }
            XCTAssertFalse(c.resetAfterVerifiedIdle(deviceID: 7, nativeStreamIsIdle: false))
            XCTAssertTrue(c.resetAfterVerifiedIdle(deviceID: 7, nativeStreamIsIdle: true))
            XCTAssertNotNil(c.takeAction(try rawCandidate(c, time: 1)))
        }
    }

    func testAppOrConfigurationChangeRetainsNativeDecisionButRevokesActions() throws {
        for releaseAlreadyAcquired in [false, true] {
            let c = C()
            let down = try acquire(c, 0)
            XCTAssertTrue(native(c, .began).consume)
            let oldAction = try XCTUnwrap(native(c, .changed, progress: 0.2).action)
            let moved = try acquire(c, 0.1, x: 0.4)
            let up = releaseAlreadyAcquired ? try acquire(c, 0.2, count: 0) : nil
            c.cancelForContextChange()
            XCTAssertNil(c.takeAction(oldAction))
            XCTAssertNil(c.deliverRawFrame(down))
            XCTAssertNil(c.deliverRawFrame(moved))
            if let up { XCTAssertNil(c.deliverRawFrame(up)) }
            let changed = native(c, .changed, progress: -0.3)
            XCTAssertTrue(changed.consume)
            XCTAssertNil(changed.action)
            let end = native(c, .ended)
            XCTAssertTrue(end.consume)
            XCTAssertNil(end.action)
            if !releaseAlreadyAcquired {
                XCTAssertNil(c.acquireRawFrame(device: pad, frame: frame(0.3, count: 1)))
                XCTAssertNil(c.acquireRawFrame(device: pad, frame: frame(0.4, count: 0)))
            }
            XCTAssertNotNil(c.takeAction(try rawCandidate(c, time: 1)))
        }
    }

    func testContextChangeBeforeNativeThresholdDoesNotCreateNewAction() throws {
        let c = C()
        _ = try acquire(c, 0)
        XCTAssertTrue(native(c, .began).consume)
        c.cancelForContextChange()
        let changed = native(c, .changed, progress: 0.3)
        XCTAssertTrue(changed.consume)
        XCTAssertNil(changed.action)
        XCTAssertTrue(native(c, .ended).consume)
    }

    func testContextChangeRevokesRawTicketAndDoesNotBlockAlreadyAcquiredRelease() throws {
        let c = C()
        let raw = try rawCandidate(c)
        let up = try acquire(c, 0.2, count: 0)
        c.cancelForContextChange()
        XCTAssertNil(c.takeAction(raw))
        XCTAssertNil(c.deliverRawFrame(up))
        XCTAssertNotNil(c.takeAction(try rawCandidate(c, time: 1)))
    }

    func testInterruptionRevokesAnUnreservedQueuedRawAction() throws {
        let c = C()
        let raw = try rawCandidate(c)
        _ = try acquire(c, 0.2, count: 0)
        c.interrupt()
        XCTAssertNil(c.takeAction(raw))
        XCTAssertNotNil(c.takeAction(try rawCandidate(c, time: 1)))
    }

    func testSimultaneousDevicesRemainIndependent() throws {
        let c = C()
        let rawA = try rawCandidate(c)
        let rawB = try rawCandidate(c, device: otherPad)
        XCTAssertTrue(native(c, .began).consume)
        let nativeA = try XCTUnwrap(native(c, .changed, progress: 0.2).action)
        XCTAssertNil(c.takeAction(rawA))
        XCTAssertEqual(c.takeAction(rawB), .raw(deviceID: 8, gesture: .swipe(fingers: 3, direction: .right)))
        // B's already dispatched raw action declines B only, without quarantining A.
        XCTAssertFalse(native(c, .began, sender: 43).consume)
        XCTAssertEqual(c.takeAction(nativeA), .native(deviceID: 7, actionID: "simulated-right"))
        XCTAssertTrue(native(c, .ended).consume)
    }

    func testTwoNativeOwnedDevicesHaveIndependentDeferredActions() throws {
        let c = C()
        _ = try acquire(c, 0)
        _ = try acquire(c, 0, device: otherPad)
        XCTAssertTrue(native(c, .began).consume)
        XCTAssertTrue(native(c, .began, sender: 43).consume)
        let a = try XCTUnwrap(native(c, .changed, progress: 0.2).action)
        let b = try XCTUnwrap(native(c, .changed, sender: 43, progress: -0.2).action)
        XCTAssertTrue(native(c, .cancelled).consume)
        XCTAssertNil(c.takeAction(a))
        XCTAssertEqual(c.takeAction(b), .native(deviceID: 8, actionID: "simulated-left"))
        XCTAssertTrue(native(c, .ended, sender: 43).consume)
    }

    func testMissingMouseAndAmbiguousRegistryAssociationsNeverClaim() throws {
        for device in [C.RawDevice(deviceID: 42),
                       C.RawDevice(deviceID: 7, registryID: 42, scope: .mouse),
                       C.RawDevice(deviceID: 7, registryID: 42, scope: .any)] {
            let c = C()
            let raw = try rawCandidate(c, device: device)
            XCTAssertFalse(native(c, .began).consume)
            XCTAssertNotNil(c.takeAction(raw))
        }
        let c = C()
        let rawA = try rawCandidate(c)
        let rawB = try rawCandidate(c, device: .init(deviceID: 9, registryID: 42, scope: .trackpad))
        XCTAssertFalse(native(c, .began).consume)
        XCTAssertNotNil(c.takeAction(rawA))
        XCTAssertNotNil(c.takeAction(rawB))
    }

    func testLateNativeOpeningCannotReserveNextRawSessionWithoutCorrectPairing() throws {
        for earlierAlreadyDispatched in [false, true] {
            for supplyEarlierSession in [false, true] {
                let c = C()
                let earlier = try rawCandidate(c)
                let up = try acquire(c, 0.2, count: 0)
                XCTAssertNil(c.deliverRawFrame(up))
                if earlierAlreadyDispatched { XCTAssertNotNil(c.takeAction(earlier)) }
                let nextDown = try acquire(c, 1)
                XCTAssertNil(c.deliverRawFrame(nextDown))
                let lateOpening = c.processNative(event(.began), gate: simulatedGate, eligibility: eligibility(),
                    correlatedRawSession: supplyEarlierSession ? earlier.session : nil)
                XCTAssertFalse(lateOpening.consume)
                XCTAssertNil(lateOpening.action)
                XCTAssertFalse(native(c, .changed, progress: 0.3).consume)
                XCTAssertFalse(native(c, .ended).consume)
                if !earlierAlreadyDispatched { XCTAssertNotNil(c.takeAction(earlier)) }
                let nextMove = try acquire(c, 1.1, x: 0.4)
                let nextAction = try XCTUnwrap(c.deliverRawFrame(nextMove))
                XCTAssertNotNil(c.takeAction(nextAction))
                XCTAssertNotEqual(earlier.session, nextAction.session)
            }
        }
    }

    func testWrongDeviceForeignAndStaleCorrelationTokensCannotClaim() throws {
        for kind in 0..<3 {
            let c = C()
            let wrong: C.RawSession
            switch kind {
            case 0:
                wrong = try acquire(c, 0, device: otherPad).session
            case 1:
                let foreign = C()
                wrong = try acquire(foreign, 0).session
            default:
                wrong = try acquire(c, 0).session
                c.resetCapture()
            }
            _ = try acquire(c, 0)
            XCTAssertFalse(c.processNative(event(.began), gate: simulatedGate, eligibility: eligibility(),
                                           correlatedRawSession: wrong).consume)
            // Supplying the correct association late must not acquire midstream.
            XCTAssertFalse(native(c, .changed, progress: 0.3).consume)
            XCTAssertFalse(native(c, .ended).consume)
        }
    }

    func testMissingCorrelationAtMayBeginCannotBeAddedMidstream() throws {
        let c = C()
        _ = try acquire(c, 0)
        XCTAssertFalse(c.processNative(event(.mayBegin), gate: simulatedGate, eligibility: eligibility()).consume)
        XCTAssertFalse(native(c, .began).consume)
        XCTAssertFalse(native(c, .changed, progress: 0.3).consume)
        XCTAssertFalse(native(c, .ended).consume)
        XCTAssertTrue(native(c, .began).consume)
    }

    func testOwnedContinuationAllowsNilAndRejectsContradictoryCorrelation() throws {
        let c = C()
        _ = try acquire(c, 0)
        XCTAssertTrue(native(c, .began).consume)
        let changed = c.processNative(event(.changed, progress: 0.3), gate: simulatedGate,
                                      eligibility: eligibility()) // no repeated attestation needed
        XCTAssertTrue(changed.consume)
        let pending = try XCTUnwrap(changed.action)
        let foreign = C()
        let contradiction = try acquire(foreign, 0).session
        let rejected = c.processNative(event(.changed, progress: 0.4), gate: simulatedGate,
                                       eligibility: eligibility(), correlatedRawSession: contradiction)
        XCTAssertFalse(rejected.consume)
        XCTAssertTrue(rejected.requiresIdleReset)
        XCTAssertNil(c.takeAction(pending))
    }

    func testMissingSenderOpeningQuarantinesLaterIdentifiedOpeningUntilGlobalIdle() throws {
        for sender in [UInt64?.none, .some(0)] {
            let c = C()
            let unidentified = NativeHorizontalSwipeEvent(eventClass: 30, hidType: 23, axis: 1,
                phase: 128, senderRegistryID: sender, sourceProvenance: .independentlyVerifiedPhysical)
            XCTAssertFalse(c.processNative(unidentified, gate: simulatedGate, eligibility: eligibility()).consume)
            let down = try acquire(c, 0)
            XCTAssertFalse(native(c, .began).consume)
            XCTAssertFalse(native(c, .changed, progress: 0.3).consume)
            XCTAssertFalse(native(c, .ended).consume)
            XCTAssertFalse(c.resetAfterVerifiedGlobalIdle(nativeStreamsAreIdle: true))
            let up = try acquire(c, 0.1, count: 0)
            XCTAssertNil(c.deliverRawFrame(down))
            _ = c.deliverRawFrame(up)
            XCTAssertFalse(c.resetAfterVerifiedIdle(deviceID: 7, nativeStreamIsIdle: true))
            XCTAssertFalse(c.resetAfterVerifiedGlobalIdle(nativeStreamsAreIdle: false))
            XCTAssertTrue(c.resetAfterVerifiedGlobalIdle(nativeStreamsAreIdle: true))
            _ = try acquire(c, 1)
            XCTAssertTrue(native(c, .began).consume)
        }
    }

    func testCaptureResetClearsMissingSenderQuarantine() throws {
        let c = C()
        let unidentified = NativeHorizontalSwipeEvent(eventClass: 30, hidType: 23, axis: 1,
            phase: 128, senderRegistryID: nil, sourceProvenance: .independentlyVerifiedPhysical)
        XCTAssertFalse(c.processNative(unidentified, gate: simulatedGate, eligibility: eligibility()).consume)
        c.resetCapture()
        _ = try acquire(c, 0)
        XCTAssertTrue(native(c, .began).consume)
    }

    func testAcquiringDuplicateRegistryRevokesPendingNativeButNotUnrelatedDevice() throws {
        let c = C()
        _ = try acquire(c, 0)
        _ = try acquire(c, 0, device: otherPad)
        XCTAssertTrue(native(c, .began).consume)
        XCTAssertTrue(native(c, .began, sender: 43).consume)
        let actionA = try XCTUnwrap(native(c, .changed, progress: 0.2).action)
        let actionB = try XCTUnwrap(native(c, .changed, sender: 43, progress: -0.2).action)
        // No intervening native event: acquisition itself must revoke the old action.
        let duplicate = C.RawDevice(deviceID: 9, registryID: 42, scope: .trackpad)
        _ = try acquire(c, 0, device: duplicate)
        XCTAssertNil(c.takeAction(actionA))
        XCTAssertFalse(native(c, .changed, progress: 0.3).consume)
        XCTAssertEqual(c.takeAction(actionB), .native(deviceID: 8, actionID: "simulated-left"))
    }

    func testInvalidUnassociatedTerminalCannotPermitMidstreamClaim() throws {
        let invalidTerminals: [NativeHorizontalSwipeEvent] = [
            .init(eventClass: 30, hidType: 23, axis: 1, phase: 4, senderRegistryID: 42),
            .init(eventClass: 30, hidType: 23, axis: 1, phase: 8, senderRegistryID: 42),
            .init(eventClass: 30, hidType: 23, axis: 1, phase: 4, senderRegistryID: 42,
                  progress: .nan, sourceProvenance: .independentlyVerifiedPhysical),
            .init(eventClass: 30, hidType: 23, axis: 1, phase: 8, senderRegistryID: 42,
                  velocityX: .infinity, sourceProvenance: .independentlyVerifiedPhysical)
        ]
        for invalid in invalidTerminals {
            let c = C()
            XCTAssertFalse(native(c, .mayBegin).consume)
            _ = try acquire(c, 0)
            let result = c.processNative(invalid, gate: simulatedGate, eligibility: eligibility())
            XCTAssertFalse(result.consume)
            XCTAssertTrue(result.requiresIdleReset)
            XCTAssertFalse(native(c, .began).consume)
            XCTAssertFalse(native(c, .changed, progress: 0.3).consume)
            // Only a separately verified well-formed terminal establishes the boundary.
            XCTAssertFalse(native(c, .ended).consume)
            XCTAssertTrue(native(c, .began).consume)
        }
    }

    func testOpeningBeforeRawAcquisitionCannotClaimAtLaterBegan() throws {
        let c = C()
        XCTAssertFalse(native(c, .mayBegin).consume)
        let raw = try rawCandidate(c)
        XCTAssertFalse(native(c, .began).consume)
        XCTAssertFalse(native(c, .changed, progress: 0.3).consume)
        XCTAssertFalse(native(c, .ended).consume)
        XCTAssertNotNil(c.takeAction(raw))
    }

    func testChangedIdentityBlocksOldSessionUntilActualAllUp() throws {
        let c = C()
        let raw = try rawCandidate(c)
        let replacement = C.RawDevice(deviceID: 7, registryID: 99, scope: .trackpad)
        XCTAssertNil(c.acquireRawFrame(device: replacement, frame: frame(0.2, x: 0.4)))
        XCTAssertNil(c.takeAction(raw))
        XCTAssertNil(c.acquireRawFrame(device: replacement, frame: frame(0.3, count: 0)))
        XCTAssertTrue(c.resetAfterVerifiedIdle(deviceID: 7, nativeStreamIsIdle: true))
        _ = try acquire(c, 1, device: replacement)
        XCTAssertTrue(native(c, .began, sender: 99).consume)
    }

    func testStaleOwnershipAfterNextSequenceResetAndForeignCoordinator() throws {
        let c = C()
        let firstDown = try acquire(c, 0)
        XCTAssertTrue(native(c, .began).consume)
        let first = try XCTUnwrap(native(c, .ended, progress: 0.2).action)
        let up = try acquire(c, 0.1, count: 0)
        XCTAssertNil(c.deliverRawFrame(firstDown))
        XCTAssertNil(c.deliverRawFrame(up))
        let nextDown = try acquire(c, 1)
        XCTAssertTrue(native(c, .began).consume)
        XCTAssertNil(c.takeAction(first))
        let second = try XCTUnwrap(native(c, .changed, progress: -0.2).action)
        let foreign = C()
        XCTAssertNil(foreign.takeAction(second))
        XCTAssertNil(foreign.deliverRawFrame(nextDown))
        c.resetCapture()
        XCTAssertNil(c.takeAction(second))
        XCTAssertNil(c.deliverRawFrame(nextDown))
        XCTAssertNotNil(c.takeAction(try rawCandidate(c))) // capture clock may restart
    }

    func testMalformedAndCancelledAllUpCannotClearInterruption() throws {
        for bad in [frame(.nan, count: 0), frame(-1, count: 0)] {
            let c = C()
            _ = try acquire(c, 0)
            c.interrupt()
            XCTAssertNil(c.acquireRawFrame(device: pad, frame: bad))
            XCTAssertNil(c.acquireRawFrame(device: pad, frame: frame(0.1, count: 0), cancelled: true))
            XCTAssertFalse(c.resetAfterVerifiedIdle(deviceID: 7, nativeStreamIsIdle: true))
            XCTAssertNil(c.acquireRawFrame(device: pad, frame: frame(0.2, count: 0)))
            XCTAssertTrue(c.resetAfterVerifiedIdle(deviceID: 7, nativeStreamIsIdle: true))
        }
    }

    func testOutOfOrderAndDuplicateDeliveryDoNotInventActions() throws {
        let c = C()
        let down = try acquire(c, 0)
        let moved = try acquire(c, 0.1, x: 0.4)
        XCTAssertNil(c.deliverRawFrame(moved)) // missing down invalidates this device
        XCTAssertNil(c.deliverRawFrame(down))
        XCTAssertNil(c.acquireRawFrame(device: pad, frame: frame(0.2, count: 0)))
        let nextDown = try acquire(c, 1)
        let nextMoved = try acquire(c, 1.1, x: 0.4)
        XCTAssertNil(c.deliverRawFrame(nextDown))
        XCTAssertNil(c.deliverRawFrame(nextDown))
        let action = try XCTUnwrap(c.deliverRawFrame(nextMoved))
        XCTAssertNil(c.deliverRawFrame(nextMoved))
        XCTAssertNotNil(c.takeAction(action))
        XCTAssertNil(c.takeAction(action))
    }

    func testUnknownNonzeroSenderInvalidatesOwnedActionWithoutGuessingDevice() throws {
        for terminalAlreadyReceived in [false, true] {
            let c = C()
            _ = try acquire(c, 0)
            XCTAssertTrue(native(c, .began).consume)
            let action = try XCTUnwrap(native(c, .changed, progress: 0.2).action)
            if terminalAlreadyReceived { XCTAssertTrue(native(c, .ended).consume) }
            let unknown = native(c, .changed, sender: 999, progress: 0.3)
            XCTAssertFalse(unknown.consume)
            XCTAssertTrue(unknown.requiresIdleReset)
            XCTAssertNil(c.takeAction(action))
        }
    }

    func testUnverifiedMappedPacketRevokesPendingNativeAction() throws {
        let c = C()
        _ = try acquire(c, 0)
        XCTAssertTrue(native(c, .began).consume)
        let action = try XCTUnwrap(native(c, .changed, progress: 0.2).action)
        let unverified = NativeHorizontalSwipeEvent(eventClass: 30, hidType: 23, axis: 1,
                                                   phase: 2, senderRegistryID: 42)
        let result = c.processNative(unverified, gate: simulatedGate, eligibility: eligibility())
        XCTAssertFalse(result.consume)
        XCTAssertTrue(result.requiresIdleReset)
        XCTAssertNil(c.takeAction(action))
    }

    func testClass29CompanionsNeverReserveAdvanceOrTerminate() throws {
        let c = C()
        let raw = try rawCandidate(c)
        XCTAssertFalse(c.processNative(event(.began, eventClass: 29), gate: simulatedGate,
                                       eligibility: eligibility()).consume)
        XCTAssertTrue(native(c, .began).consume)
        XCTAssertFalse(c.processNative(event(.ended, eventClass: 29), gate: simulatedGate,
                                       eligibility: eligibility()).consume)
        XCTAssertNil(c.takeAction(raw))
        XCTAssertNotNil(native(c, .changed, progress: 0.2).action)
    }

    func testIdentityCacheIsBoundedUntilCaptureReset() throws {
        let c = C()
        for id in UInt64(1)...256 {
            XCTAssertNil(c.acquireRawFrame(device: .init(deviceID: id), frame: frame(0, count: 0)))
        }
        let nextDevice = C.RawDevice(deviceID: 257, registryID: 999, scope: .trackpad)
        XCTAssertNil(c.acquireRawFrame(device: nextDevice, frame: frame(0)))
        c.resetCapture()
        XCTAssertNotNil(c.acquireRawFrame(device: nextDevice, frame: frame(0)))
    }

    func testQueueOverflowInvalidatesPendingActionsAndRequiresRelease() throws {
        let c = C()
        let raw = try rawCandidate(c)
        for i in 0..<256 { _ = c.acquireRawFrame(device: pad, frame: frame(1 + Double(i) / 1000)) }
        XCTAssertNil(c.acquireRawFrame(device: pad, frame: frame(2)))
        XCTAssertNil(c.takeAction(raw))
        XCTAssertNil(c.acquireRawFrame(device: pad, frame: frame(3, count: 0)))
        XCTAssertNotNil(c.takeAction(try rawCandidate(c, time: 4)))
    }

    func testEveryOrderedAcquisitionDeliveryAndNativeInterleavingDispatchesAtMostOnce() throws {
        // 330 fixed shuffles, preserving raw acquisition/delivery order and native order.
        // Acquisition and delivery are different steps; no wall clock or thread scheduler.
        enum Step { case down, move, deliverDown, deliverMove, dispatchRaw, up, deliverUp
                    case begin, change, dispatchNative, end }
        let rawSteps: [Step] = [.down, .move, .deliverDown, .deliverMove, .dispatchRaw, .up, .deliverUp]
        let nativeSteps: [Step] = [.begin, .change, .dispatchNative, .end]
        func shuffles(_ a: [Step], _ b: [Step]) -> [[Step]] {
            if a.isEmpty { return [b] }
            if b.isEmpty { return [a] }
            return shuffles(Array(a.dropFirst()), b).map { [a[0]] + $0 } +
                   shuffles(a, Array(b.dropFirst())).map { [b[0]] + $0 }
        }
        let traces = shuffles(rawSteps, nativeSteps)
        XCTAssertEqual(traces.count, 330)
        for trace in traces {
            let c = C()
            // An unrelated physical device must remain actionable for every shuffle.
            let unrelated = try rawCandidate(c, device: otherPad)
            var down: C.RawFrameTicket?, moved: C.RawFrameTicket?, up: C.RawFrameTicket?
            var rawAction: C.ActionTicket?, nativeAction: C.ActionTicket?
            var dispatches = 0
            for step in trace {
                switch step {
                case .down: down = try acquire(c, 0)
                case .move: moved = try acquire(c, 0.1, x: 0.4)
                case .deliverDown: XCTAssertNil(c.deliverRawFrame(try XCTUnwrap(down)))
                case .deliverMove: rawAction = c.deliverRawFrame(try XCTUnwrap(moved))
                case .dispatchRaw:
                    if let rawAction, c.takeAction(rawAction) != nil { dispatches += 1 }
                case .up: up = try acquire(c, 0.2, count: 0)
                case .deliverUp: XCTAssertNil(c.deliverRawFrame(try XCTUnwrap(up)))
                case .begin: _ = native(c, .began)
                case .change: nativeAction = native(c, .changed, progress: 0.2).action
                case .dispatchNative:
                    if let nativeAction, c.takeAction(nativeAction) != nil { dispatches += 1 }
                case .end: _ = native(c, .ended)
                }
            }
            XCTAssertLessThanOrEqual(dispatches, 1, "Simulated trace: \(trace)")
            XCTAssertEqual(c.takeAction(unrelated), .raw(deviceID: 8, gesture: .swipe(fingers: 3, direction: .right)))
            if let rawAction { XCTAssertNil(c.takeAction(rawAction)) }
            if let nativeAction { XCTAssertNil(c.takeAction(nativeAction)) }
        }
    }
}
