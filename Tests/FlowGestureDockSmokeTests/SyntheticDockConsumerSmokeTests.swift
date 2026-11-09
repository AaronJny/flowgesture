import AppKit
import CoreGraphics
import Darwin
import Foundation
import XCTest
@testable import FlowGestureDockSmokeHarness

final class SyntheticDockConsumerSmokeTests: XCTestCase {
    func testLiveAdmissionRequiresExplicitDisposableHostedLegacyOS() {
        let permitted = ["FLOWGESTURE_RUN_DOCK_SMOKE": "1", "GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted"]
        XCTAssertNil(DockSmokeFixture.admissionReason(environment: permitted, majorVersion: 15))
        XCTAssertNil(DockSmokeFixture.admissionReason(environment: permitted, majorVersion: 26))
        for version in [0, 13, 14, 16, 25, 27, 28] {
            XCTAssertNotNil(DockSmokeFixture.admissionReason(environment: permitted, majorVersion: version))
        }
        for key in permitted.keys {
            var missing = permitted
            missing.removeValue(forKey: key)
            XCTAssertNotNil(DockSmokeFixture.admissionReason(environment: missing, majorVersion: 15))
        }
        var selfHosted = permitted
        selfHosted["RUNNER_ENVIRONMENT"] = "self-hosted"
        XCTAssertNotNil(DockSmokeFixture.admissionReason(environment: selfHosted, majorVersion: 15))
    }

    func testLegacyFactoryPreparesEveryPhaseAndBothSignedVelocityFields() throws {
        let directions: [DockSmokeFixture.Direction] = [.left, .right]
        for direction in directions {
            let batch = try DockSmokeFixture.prepare(name: "unposted", direction: direction, mode: .forward, tags: [11, 12, 13])
            XCTAssertEqual(batch.packets.map { $0.posted.phase }, [1, 2, 4])
            XCTAssertEqual(batch.packets.map { $0.posted.tag }, [11, 12, 13])
            for packet in batch.packets {
                let fields = packet.posted
                XCTAssertEqual(fields.pid, Int64(getpid()))
                XCTAssertEqual(fields.eventType, 30)
                XCTAssertEqual(fields.selector, 30)
                XCTAssertEqual(fields.hidType, 23)
                XCTAssertEqual(fields.axis, 1)
                XCTAssertEqual(fields.flags, 0)
                XCTAssertEqual(fields.progress, Double(direction.rawValue) * 0.000016)
                XCTAssertEqual(fields.velocityX, Double(direction.rawValue) * 2000)
                XCTAssertEqual(fields.velocityY, Double(direction.rawValue) * 2000)
            }
        }
    }

    func testConstructionDiagnosticNamesActualAndExpectedSourceAndFields() throws {
        let packet = try XCTUnwrap(DockSmokeFixture.prepare(name: "unposted", direction: .right,
            mode: .forward, tags: [41, 42, 43]).packets.first)
        let diagnostics = DockSmokeFixture.constructionMismatches(packet.posted, phase: 2,
            direction: .left, tag: 999, pid: Int64(getpid()) + 1)
        XCTAssertTrue(diagnostics.contains("phase132: actual=1, expected=2"))
        XCTAssertTrue(diagnostics.contains("sourceTag: actual=41, expected=999"))
        XCTAssertTrue(diagnostics.contains("sourcePID: actual=\(getpid()), expected=\(Int64(getpid()) + 1)"))
        XCTAssertTrue(diagnostics.contains { $0.hasPrefix("progress124: actual=") })
        XCTAssertTrue(diagnostics.contains { $0.hasPrefix("velocityX129: actual=") })
        XCTAssertTrue(diagnostics.contains { $0.hasPrefix("velocityY130: actual=") })
        XCTAssertEqual(diagnostics.count, 6)
        XCTAssertEqual(DockSmokeFixture.constructionMismatches(packet.posted, phase: 1,
            direction: .right, tag: 41, pid: Int64(getpid()), includeMatches: true).count, 11)
    }

    func testFullscreenCleanupCannotCloseDuringUnsettledTransition() {
        XCTAssertTrue(DockSmokeFullscreenPhase.windowed.canCloseWithoutTransition)
        let unsafe: [DockSmokeFullscreenPhase] = [.entering, .fullscreen, .exiting, .failed]
        for phase in unsafe { XCTAssertFalse(phase.canCloseWithoutTransition) }
        XCTAssertTrue(DockSmokeFullscreenPhase.entering.transitioning)
        XCTAssertTrue(DockSmokeFullscreenPhase.exiting.transitioning)
        XCTAssertFalse(DockSmokeFullscreenPhase.fullscreen.transitioning)
        XCTAssertFalse(DockSmokeFullscreenPhase.failed.transitioning)
        let phases: [DockSmokeFullscreenPhase] = [.windowed, .entering, .fullscreen, .exiting, .failed]
        for phase in phases {
            XCTAssertEqual(phase.invalidatesFixture(duringExperiment: true), phase != .fullscreen)
            XCTAssertFalse(phase.invalidatesFixture(duringExperiment: false))
        }
    }

    func testConstructionRejectsMissingDuplicateOrZeroTagsBeforeAnyPost() {
        let cases: [[Int64]] = [[], [1], [1, 2], [1, 2, 3, 4], [1, 1, 3], [0, 2, 3], [-1, 2, 3]]
        for tags in cases {
            XCTAssertThrowsError(try DockSmokeFixture.prepare(name: "unposted", direction: .left, mode: .consume, tags: tags))
        }
    }

    func testStartedBatchCompletesEndedDespiteRecordedFailure() throws {
        let batch = try DockSmokeFixture.prepare(name: "unposted", direction: .left, mode: .consume, tags: [21, 22, 23])
        var phases: [Int64] = []
        var recordedFailure = false
        // Inject a failure flag after began. This closure never posts to Quartz.
        batch.postAll { event in
            phases.append(DockSmokeFixture.Fields(event).phase)
            recordedFailure = true
        }
        XCTAssertTrue(recordedFailure)
        XCTAssertEqual(phases, [1, 2, 4])
        XCTAssertEqual(batch.mode, .consume, "batch disposition is immutable")
    }

    func testCallbackOrderRejectsDuplicatesLateTagsAndOverlappingBatches() throws {
        var order = DockSmokeTapChain.TagOrder()
        try order.append(tags: [1, 2, 3], mode: .consume)
        XCTAssertThrowsError(try order.append(tags: [4, 5, 6], mode: .forward))
        XCTAssertTrue(order.takeNext(stage: .head, tag: 1))
        XCTAssertFalse(order.takeNext(stage: .head, tag: 1), "duplicate opening")
        XCTAssertFalse(order.takeNext(stage: .head, tag: 3), "out-of-order terminal")
        XCTAssertFalse(order.takeNext(stage: .tail, tag: 1), "consumed packet reached downstream")
        XCTAssertTrue(order.takeNext(stage: .head, tag: 2))
        XCTAssertTrue(order.takeNext(stage: .head, tag: 3))
        for tag in [Int64(1), 2, 3] { XCTAssertTrue(order.takeNext(stage: .filter, tag: tag)) }
        XCTAssertTrue(order.isDrained)
        XCTAssertFalse(order.takeNext(stage: .filter, tag: 3), "late terminal after verify")
        try order.append(tags: [4, 5, 6], mode: .forward)
        XCTAssertFalse(order.takeNext(stage: .filter, tag: 1), "retired batch cannot match a new batch")
        let stages: [DockSmokeTapChain.Stage] = [.head, .filter, .tail]
        for stage in stages {
            for tag in [Int64(4), 5, 6] { XCTAssertTrue(order.takeNext(stage: stage, tag: tag)) }
        }
        XCTAssertTrue(order.isDrained)
    }

    func testExactSourceAndKnownPacketFieldsCannotBeSubstituted() throws {
        let packet = try XCTUnwrap(DockSmokeFixture.prepare(name: "unposted", direction: .right,
            mode: .consume, tags: [31, 32, 33]).packets.first)
        XCTAssertTrue(DockSmokeFixture.Fields(packet.event).matchesPayload(packet.posted))
        let integerFields: [CGEventField] = [.eventSourceUnixProcessID, .eventSourceUserData,
            CGEventField(rawValue: 55)!, CGEventField(rawValue: 110)!, CGEventField(rawValue: 123)!, CGEventField(rawValue: 132)!]
        for field in integerFields {
            let copy = try XCTUnwrap(packet.event.copy())
            copy.setIntegerValueField(field, value: copy.getIntegerValueField(field) + 1)
            XCTAssertFalse(DockSmokeFixture.Fields(copy).matchesPayload(packet.posted))
        }
        for raw in [UInt32(124), 129, 130] {
            let copy = try XCTUnwrap(packet.event.copy())
            let field = try XCTUnwrap(CGEventField(rawValue: raw))
            copy.setDoubleValueField(field, value: 0)
            XCTAssertFalse(DockSmokeFixture.Fields(copy).matchesPayload(packet.posted))
        }
    }
}
