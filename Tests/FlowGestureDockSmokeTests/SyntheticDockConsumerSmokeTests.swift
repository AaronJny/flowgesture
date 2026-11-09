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
                XCTAssertEqual(packet.progressStorage.requested, Double(direction.rawValue) * 0.000016)
                XCTAssertEqual(fields.progress, Double(Float(packet.progressStorage.requested)))
                XCTAssertEqual(packet.progressStorage.observedStored, fields.progress)
                XCTAssertTrue(packet.progressStorage.observedDiffersFromRequested)
                XCTAssertTrue(packet.progressStorage.matchesExpectedStored)
                XCTAssertEqual(fields.velocityX, Double(direction.rawValue) * 2000)
                XCTAssertEqual(fields.velocityY, Double(direction.rawValue) * 2000)
            }
        }
    }

    func testProgressStorageAcceptsOnlyTheExactSinglePrecisionRoundTrip() {
        let directions: [DockSmokeFixture.Direction] = [.left, .right]
        for direction in directions {
            let requested = Double(direction.rawValue) * 0.000016
            let stored = Double(Float(requested))
            XCTAssertEqual(abs(stored), 1.5999999959603883e-05, "pinned observed round trip")
            let accepted = DockSmokeFixture.ProgressStorage(direction: direction, observedStored: stored)
            XCTAssertEqual(accepted.requested, requested)
            XCTAssertEqual(accepted.expectedStored, stored)
            XCTAssertTrue(accepted.matchesExpectedStored)
            XCTAssertTrue(accepted.observedDiffersFromRequested)
            // Even a one-ULP Double difference is forbidden. Adjacent Float
            // values, the unrounded recipe, nonfinite values, and wrong signs
            // are not alternatives to this one observed storage model.
            let rejected: [Double] = [requested, stored.nextUp, stored.nextDown,
                Double(Float(requested).nextUp), Double(Float(requested).nextDown),
                0, -stored, .nan, .infinity, -.infinity]
            for value in rejected {
                XCTAssertFalse(DockSmokeFixture.ProgressStorage(direction: direction,
                    observedStored: value).matchesExpectedStored, "unexpected stored value \(value)")
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
        let allFields = DockSmokeFixture.constructionMismatches(packet.posted, phase: 1,
            direction: .right, tag: 41, pid: Int64(getpid()), includeMatches: true)
        XCTAssertEqual(allFields.count, 11)
        let progress = try XCTUnwrap(allFields.first { $0.hasPrefix("progress124:") })
        XCTAssertTrue(progress.contains("expectedStored="))
        XCTAssertTrue(progress.contains("requested="))
        XCTAssertTrue(progress.contains("model=Double(Float(requested))"))
        XCTAssertTrue(progress.contains("differsFromRequested=true"))
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

        // Every payload guard is exercised with an explicit value snapshot,
        // independent of which private/source CGEvent setters Quartz honors.
        typealias Fields = DockSmokeFixture.Fields
        let baseline = packet.posted
        XCTAssertEqual(Fields(syntheticCopying: baseline), baseline)
        let replacements: [(String, Fields)] = [
            ("eventType", Fields(syntheticCopying: baseline, eventType: 31)),
            ("sourceTag", Fields(syntheticCopying: baseline, tag: baseline.tag + 1)),
            ("sourcePID", Fields(syntheticCopying: baseline, pid: baseline.pid + 1)),
            ("selector55", Fields(syntheticCopying: baseline, selector: 31)),
            ("hidType110", Fields(syntheticCopying: baseline, hidType: 24)),
            ("axis123", Fields(syntheticCopying: baseline, axis: 2)),
            ("phase132", Fields(syntheticCopying: baseline, phase: 2)),
            ("progress124", Fields(syntheticCopying: baseline, progress: baseline.progress.nextUp)),
            ("velocityX129", Fields(syntheticCopying: baseline, velocityX: baseline.velocityX.nextUp)),
            ("velocityY130", Fields(syntheticCopying: baseline, velocityY: baseline.velocityY.nextUp)),
            ("nonfinite progress", Fields(syntheticCopying: baseline, progress: .nan)),
            ("nonfinite velocityX", Fields(syntheticCopying: baseline, velocityX: .infinity)),
            ("nonfinite velocityY", Fields(syntheticCopying: baseline, velocityY: -.infinity))
        ]
        for (name, replaced) in replacements {
            print("Pure synthetic snapshot replacement \(name): before=\(baseline), after=\(replaced)")
            XCTAssertNotEqual(replaced, baseline, "negative snapshot must differ: \(name)")
            XCTAssertFalse(replaced.matchesPayload(baseline), "strict payload guard: \(name)")
        }

        // Quartz ignored a sourceTag setter on a copied event in hosted runs.
        // Build a separate complete, UNPOSTED batch so this negative control
        // compares actual reads of two factory-assigned tags, not setter intent.
        let differentlyTaggedPacket = try XCTUnwrap(DockSmokeFixture.prepare(name: "unposted-other-tag",
            direction: .right, mode: .consume, tags: [51, 52, 53]).packets.first)
        let differentlyTaggedFields = Fields(differentlyTaggedPacket.event)
        print("Separate unposted factory sourceTag field=\(CGEventField.eventSourceUserData.rawValue) baseline=\(baseline.tag) requested=51 observed=\(differentlyTaggedFields.tag)")
        XCTAssertEqual(differentlyTaggedFields.tag, 51)
        XCTAssertNotEqual(differentlyTaggedFields.tag, baseline.tag)
        XCTAssertEqual(Fields(syntheticCopying: differentlyTaggedFields, tag: baseline.tag), baseline,
                       "the actual negative control must differ only in its source tag")
        XCTAssertFalse(differentlyTaggedFields.matchesPayload(baseline), "actual differing source tags must be rejected")

        // These setters are diagnostic only. An ignored write is not a matcher
        // failure; the pure replacements above cover each guard either way.
        let diagnosticFields: [(String, CGEventField)] = [("sourceTag", .eventSourceUserData),
            ("sourcePID", .eventSourceUnixProcessID),
            ("selector", CGEventField(rawValue: 55)!), ("hidType", CGEventField(rawValue: 110)!),
            ("axis", CGEventField(rawValue: 123)!)]
        for (name, field) in diagnosticFields {
            let copy = try XCTUnwrap(packet.event.copy())
            let before = copy.getIntegerValueField(field)
            copy.setIntegerValueField(field, value: before + 1)
            let after = copy.getIntegerValueField(field)
            let diagnostic = "\(name) field=\(field.rawValue) before=\(before) requested=\(before + 1) after=\(after)"
            print("Unposted observational setter diagnostic \(diagnostic)")
            if after != before {
                XCTAssertFalse(Fields(copy).matchesPayload(baseline), diagnostic)
            }
        }
        // Only independently observed writable fields are API mutation fixtures.
        // Began (1) changes to valid changed (2), rather than an arbitrary phase.
        let integerFields: [(String, CGEventField)] = [("phase", CGEventField(rawValue: 132)!)]
        for (name, field) in integerFields {
            let copy = try XCTUnwrap(packet.event.copy())
            let before = copy.getIntegerValueField(field)
            copy.setIntegerValueField(field, value: before + 1)
            let after = copy.getIntegerValueField(field)
            let diagnostic = "\(name) field=\(field.rawValue) before=\(before) requested=\(before + 1) after=\(after)"
            print("Unposted setter diagnostic \(diagnostic)")
            XCTAssertNotEqual(after, before, "negative fixture was not changed: \(diagnostic)")
            guard after != before else { continue }
            XCTAssertFalse(DockSmokeFixture.Fields(copy).matchesPayload(packet.posted), diagnostic)
        }
        for (name, raw) in [("progress", UInt32(124)), ("velocityX", 129), ("velocityY", 130)] {
            let copy = try XCTUnwrap(packet.event.copy())
            let field = try XCTUnwrap(CGEventField(rawValue: raw))
            let before = copy.getDoubleValueField(field)
            copy.setDoubleValueField(field, value: 0)
            let after = copy.getDoubleValueField(field)
            let diagnostic = "\(name) field=\(raw) before=\(String(format: "%.17g", before)) requested=0 after=\(String(format: "%.17g", after))"
            print("Unposted setter diagnostic \(diagnostic)")
            XCTAssertNotEqual(after, before, "negative fixture was not changed: \(diagnostic)")
            guard after != before else { continue }
            XCTAssertFalse(DockSmokeFixture.Fields(copy).matchesPayload(packet.posted), diagnostic)
        }
        let adjacentProgress = try XCTUnwrap(packet.event.copy())
        let progressField = try XCTUnwrap(CGEventField(rawValue: 124))
        let requestedProgress = Double(Float(packet.posted.progress).nextUp)
        adjacentProgress.setDoubleValueField(progressField, value: requestedProgress)
        let observedProgress = adjacentProgress.getDoubleValueField(progressField)
        let progressDiagnostic = "adjacent progress field=124 before=\(String(format: "%.17g", packet.posted.progress)) requested=\(String(format: "%.17g", requestedProgress)) after=\(String(format: "%.17g", observedProgress))"
        print("Unposted setter diagnostic \(progressDiagnostic)")
        XCTAssertNotEqual(observedProgress, packet.posted.progress, "negative fixture was not changed: \(progressDiagnostic)")
        if observedProgress != packet.posted.progress {
            XCTAssertFalse(DockSmokeFixture.Fields(adjacentProgress).matchesPayload(packet.posted),
                           "transport comparison must not allow nearby progress values: \(progressDiagnostic)")
        }
        XCTAssertEqual(DockSmokeFixture.Fields(packet.event), packet.posted, "the real unposted fixture remains unchanged")
    }
}
