import XCTest
import CoreGraphics
import FlowGestureCore
@testable import FlowGestureApp

/// Synthetic in-process replay. These CGEvents are never posted to WindowServer.
/// Source/registry attestations below are fixture assumptions, not hardware evidence.
final class NativeRawGestureReplayTests: XCTestCase {
    private typealias C = NativeRawGestureCoordinator
    private let device = C.RawDevice(deviceID: 7, registryID: 42, scope: .trackpad)
    private let gate = NativeHorizontalSwipeArbitrator.TestGate(
        explicitlyEnabled: true, runningOSBuild: "synthetic-replay-only",
        validatedOSBuild: "synthetic-replay-only", completeStreamValidated: true)
    private let eligibility = NativeHorizontalSwipeArbitrator.Eligibility(
        senderRegistryID: 42, leftActionID: "left", rightActionID: "right", wholeFamilyEligible: true)

    private func frame(_ time: Double, moved: Bool = false, lifted: Bool = false) -> TouchFrame {
        TouchFrame(timestamp: time, touches: lifted ? [] : (1...3).map { id in
            TouchSample(id: id, location: GesturePoint(x: Double(id) * 0.2 + (moved ? 0.15 : 0), y: 0.5))
        })
    }
    private func packet(_ phase: Int64, progress: Double = 0,
                        provenance: NativeHorizontalSwipeEvent.SourceProvenance = .independentlyVerifiedPhysical) throws -> NativeHorizontalSwipeEvent {
        let event = try XCTUnwrap(CGEvent(source: nil))
        for (field, value) in [(UInt32(55), Int64(30)), (110, 23), (123, 1), (132, phase)] {
            event.setIntegerValueField(try XCTUnwrap(CGEventField(rawValue: field)), value: value)
        }
        event.setDoubleValueField(try XCTUnwrap(CGEventField(rawValue: 124)), value: progress)
        event.setDoubleValueField(try XCTUnwrap(CGEventField(rawValue: 129)), value: 0)
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        return try XCTUnwrap(NativeHorizontalSwipeDecoder.decode(
            type: try XCTUnwrap(CGEventType(rawValue: 30)), event: event,
            senderRegistryID: 42, sourceProvenance: provenance))
    }
    @discardableResult
    private func start(_ coordinator: C, device: C.RawDevice? = nil) throws -> C.RawSession {
        let ticket = try XCTUnwrap(coordinator.acquireRawFrame(device: device ?? self.device, frame: frame(0)))
        XCTAssertNil(coordinator.deliverRawFrame(ticket))
        return ticket.session
    }
    private func candidate(_ coordinator: C, device: C.RawDevice? = nil) throws -> C.ActionTicket {
        let frameTicket = try XCTUnwrap(coordinator.acquireRawFrame(device: device ?? self.device, frame: frame(0.1, moved: true)))
        return try XCTUnwrap(coordinator.deliverRawFrame(frameTicket))
    }

    func testDecodedNativeClaimInvalidatesAlreadyQueuedRawAction() throws {
        let c = C()
        let session = try start(c)
        let raw = try candidate(c)
        XCTAssertTrue(c.processNative(try packet(1), gate: gate, eligibility: eligibility, correlatedRawSession: session).consume)
        XCTAssertNil(c.takeAction(raw))
        let native = try XCTUnwrap(c.processNative(try packet(2, progress: 0.3), gate: gate, eligibility: eligibility, correlatedRawSession: session).action)
        XCTAssertEqual(c.takeAction(native), .native(deviceID: 7, actionID: "right"))
        XCTAssertNil(c.takeAction(native))
        XCTAssertNil(c.takeAction(raw))
    }

    func testAcquiredButUndeliveredRawFrameCannotEscapeNativeReservation() throws {
        let c = C()
        let session = try start(c)
        let queuedFrame = try XCTUnwrap(c.acquireRawFrame(device: device, frame: frame(0.1, moved: true)))
        XCTAssertTrue(c.processNative(try packet(1), gate: gate, eligibility: eligibility, correlatedRawSession: session).consume)
        XCTAssertNil(c.deliverRawFrame(queuedFrame))
        let native = try XCTUnwrap(c.processNative(try packet(4, progress: 0.3), gate: gate, eligibility: eligibility, correlatedRawSession: session).action)
        XCTAssertEqual(c.takeAction(native), .native(deviceID: 7, actionID: "right"))
    }

    func testAlreadyDispatchedRawActionPreventsLateNativeClaim() throws {
        let c = C()
        let session = try start(c)
        let raw = try candidate(c)
        XCTAssertEqual(c.takeAction(raw), .raw(deviceID: 7, gesture: .swipe(fingers: 3, direction: .right)))
        for phase in [Int64(1), 2, 4] {
            let result = c.processNative(try packet(phase, progress: 0.3), gate: gate, eligibility: eligibility, correlatedRawSession: session)
            XCTAssertFalse(result.consume)
            XCTAssertNil(result.action)
        }
        XCTAssertNil(c.takeAction(raw))
    }

    func testNativeTerminalDoesNotReleaseRawReservationPrematurely() throws {
        let c = C()
        let session = try start(c)
        XCTAssertTrue(c.processNative(try packet(1), gate: gate, eligibility: eligibility, correlatedRawSession: session).consume)
        let native = try XCTUnwrap(c.processNative(try packet(4, progress: 0.3), gate: gate, eligibility: eligibility, correlatedRawSession: session).action)
        XCTAssertEqual(c.takeAction(native), .native(deviceID: 7, actionID: "right"))
        let lateMove = try XCTUnwrap(c.acquireRawFrame(device: device, frame: frame(0.1, moved: true)))
        XCTAssertNil(c.deliverRawFrame(lateMove))
        let up = try XCTUnwrap(c.acquireRawFrame(device: device, frame: frame(0.2, lifted: true)))
        XCTAssertNil(c.deliverRawFrame(up))
        let nextDown = try XCTUnwrap(c.acquireRawFrame(device: device, frame: frame(1)))
        XCTAssertNil(c.deliverRawFrame(nextDown))
        let nextMove = try XCTUnwrap(c.acquireRawFrame(device: device, frame: frame(1.1, moved: true)))
        let raw = try XCTUnwrap(c.deliverRawFrame(nextMove))
        XCTAssertEqual(c.takeAction(raw), .raw(deviceID: 7, gesture: .swipe(fingers: 3, direction: .right)))
    }

    func testUnverifiedPIDZeroPacketCannotClaimOrDispatchQueuedNativeAction() throws {
        let c = C()
        let session = try start(c)
        let unknown = c.processNative(try packet(1, provenance: .unverified), gate: gate, eligibility: eligibility, correlatedRawSession: session)
        XCTAssertFalse(unknown.consume)
        XCTAssertNil(unknown.action)
        let fresh = C()
        let freshSession = try start(fresh)
        XCTAssertTrue(fresh.processNative(try packet(1), gate: gate, eligibility: eligibility, correlatedRawSession: freshSession).consume)
        let native = try XCTUnwrap(fresh.processNative(try packet(2, progress: 0.3), gate: gate, eligibility: eligibility, correlatedRawSession: freshSession).action)
        XCTAssertFalse(fresh.processNative(try packet(2, provenance: .unverified), gate: gate, eligibility: eligibility, correlatedRawSession: freshSession).consume)
        XCTAssertNil(fresh.takeAction(native))
    }

    func testSecondDeviceRemainsIndependentDuringDecodedNativeClaim() throws {
        let c = C()
        let second = C.RawDevice(deviceID: 8, registryID: 43, scope: .trackpad)
        let session = try start(c)
        try start(c, device: second)
        XCTAssertTrue(c.processNative(try packet(1), gate: gate, eligibility: eligibility, correlatedRawSession: session).consume)
        let otherRaw = try candidate(c, device: second)
        XCTAssertEqual(c.takeAction(otherRaw), .raw(deviceID: 8, gesture: .swipe(fingers: 3, direction: .right)))
        let native = try XCTUnwrap(c.processNative(try packet(2, progress: 0.3), gate: gate, eligibility: eligibility, correlatedRawSession: session).action)
        c.interrupt()
        XCTAssertNil(c.takeAction(native))
        XCTAssertNil(c.takeAction(otherRaw))
    }
}
