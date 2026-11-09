import Foundation
import XCTest
@testable import FlowGestureCapture

final class CaptureTests: XCTestCase {
    private func options(limit: Int = 8192, duration: Double = 1) throws -> CaptureOptions {
        try CaptureOptions.parse(["--self-test", "--duration", String(duration), "--output", "/unused/new.json", "--max-records", String(limit)])
    }
    private func quartz(timestamp: UInt64 = 99, sender: UInt64? = nil, type: UInt32 = 30,
                        phase: Int64 = 1, progress: Double = 0.2, velocity: Double = 10) -> CaptureQuartzFields {
        CaptureQuartzFields(callbackClass: type, eventClass: type, sourceTimestamp: timestamp,
                            sourcePID: 0, sourceUserData: Int64.min, senderAPIAvailable: true, senderID: sender,
                            privateFields: type == 29 || type == 30 ? CapturePrivateFields(callbackClass: type, selector: Int64(type),
                                                                                       hidType: 23, axis: 1, progress: progress,
                                                                                       velocityX: velocity, phase: phase) : nil)
    }
    private func raw(_ store: CaptureStore, at acquired: UInt64, time: Double, count: Int,
                     device: UInt64 = 7, cancelled: Bool = false) {
        store.observeRaw(deviceID: device, sourceTimestamp: time, frameNumber: acquired, bridgeContactCount: count,
                         contacts: (0..<count).map { CaptureContact(identifier: Int32($0), state: 4, normalizedX: 0.3, normalizedY: 0.7) },
                         cancelled: cancelled, acquiredAt: acquired)
    }
    private func report(_ store: CaptureStore, at: UInt64 = 999, devices: [CaptureDevice] = []) -> CaptureReport {
        store.finish(.selfTestComplete, at: at)
        return store.report(environment: CaptureSelfTest.environment, devices: devices)
    }
    private func json(_ report: CaptureReport) throws -> [String: Any] {
        let bytes = try JSONEncoder().encode(report)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    func testExplicitOptInDurationOutputAndUniqueArgumentsRequired() throws {
        for arguments in [[], ["--duration", "1", "--output", "x"], ["--capture", "--output", "x"],
                          ["--capture", "--duration", "1"], ["--capture", "--self-test", "--duration", "1", "--output", "x"],
                          ["--capture", "--duration", "1", "--output", "x", "--output", "y"],
                          ["--capture", "--duration", "1", "--output", "x", "--unknown", "private text"]] {
            XCTAssertThrowsError(try CaptureOptions.parse(arguments))
        }
        XCTAssertEqual(try options().mode, .selfTest)
        XCTAssertEqual(try CaptureOptions.parse(["--capture", "--duration", "60", "--output", "x"]).duration, 60)
    }

    func testDurationRecordAndLabelBounds() throws {
        for value in ["nan", "inf", "-inf", "0", "-1", "0.09", "60.001", "1e100"] {
            XCTAssertThrowsError(try CaptureOptions.parse(["--capture", "--duration", value, "--output", "x"]))
        }
        for value in ["0", "-1", "10001", "nan", "1.5"] {
            XCTAssertThrowsError(try CaptureOptions.parse(["--capture", "--duration", "1", "--output", "x", "--max-records", value]))
        }
        XCTAssertThrowsError(try CaptureOptions.parse(["--capture", "--duration", "1", "--output", "x", "--scenario", "private app/window name"]))
        XCTAssertThrowsError(try CaptureOptions.parse(["--capture", "--duration", "1", "--output", "x", "--revision", "not-a-commit"]))
        let revision = String(repeating: "A", count: 40)
        XCTAssertEqual(try CaptureOptions.parse(["--capture", "--duration", "1", "--output", "x", "--revision", revision]).reportedRevision,
                       revision.lowercased())
    }

    func testSyntheticSelfTestHasNoRuntimeHardwareCapabilities() throws {
        let result = try CaptureSelfTest.run(options: options())
        XCTAssertEqual(result.mode, .selfTest)
        XCTAssertEqual(result.evidenceScope, "synthetic_in_memory_serialization_only")
        XCTAssertEqual(result.records.count, 4)
        XCTAssertEqual(result.outcome, "completed_unverified_evidence")
        XCTAssertNil(result.runtime.listenPermissionPreflight)
        XCTAssertNil(result.runtime.senderAPIAvailable)
        XCTAssertNil(result.runtime.quartzTapEnabledElapsedNanoseconds)
        XCTAssertNil(result.environment.exactOSBuild)
        XCTAssertFalse(result.scenarioVerified)
        let bytes = try JSONEncoder().encode(result)
        let roundTrip = try JSONDecoder().decode(CaptureReport.self, from: bytes)
        XCTAssertEqual(roundTrip.records.count, result.records.count)
    }

    func testAcquisitionAndSourceTimestampsAreSeparateAndLossless() throws {
        let store = CaptureStore(options: try options(), originNanoseconds: 1_000)
        store.observeQuartz(quartz(timestamp: UInt64.max), acquiredAt: 1_050)
        raw(store, at: 1_051, time: 456.125, count: 0)
        let result = report(store, at: 1_060)
        XCTAssertEqual(result.records[0].acquiredElapsedNanoseconds, "50")
        XCTAssertEqual(result.records[0].quartz?.sourceTimestampNanoseconds, "18446744073709551615")
        XCTAssertEqual(result.records[1].acquiredElapsedNanoseconds, "51")
        XCTAssertEqual(result.records[1].raw?.bridgeTimestampSeconds, 456.125)
        XCTAssertEqual(result.records[0].quartz?.sourceUserDataSignedDecimal, String(Int64.min))
        let encoded = try json(result)
        let records = try XCTUnwrap(encoded["records"] as? [[String: Any]])
        XCTAssertEqual(records[0]["acquiredElapsedNanoseconds"] as? String, "50")
    }

    func testIdentityNamespacesRemainDistinctEvenWhenNumbersCoincide() throws {
        let store = CaptureStore(options: try options(), originNanoseconds: 0)
        raw(store, at: 1, time: 1, count: 0, device: UInt64.max)
        store.observeQuartz(quartz(sender: 987), acquiredAt: 2)
        let device = CaptureDevice(opaqueSessionDeviceID: String(UInt64.max), registryEntryID: "987",
                                   multitouchFrameworkDeviceID: "987", kindCode: 2, classificationEvidenceCode: 1,
                                   vendorID: 1452, productID: nil, builtIn: nil, started: true, startError: 0)
        let result = report(store, devices: [device])
        XCTAssertEqual(result.devices[0].opaqueSessionDeviceID, "18446744073709551615")
        XCTAssertEqual(result.devices[0].registryEntryID, "987")
        XCTAssertEqual(result.devices[0].multitouchFrameworkDeviceID, "987")
        XCTAssertEqual(result.records[1].quartz?.ioHIDSenderID, "987")
        XCTAssertTrue(result.records[1].quartz!.physicalProvenance.contains("unverified"))
        XCTAssertTrue(result.records[1].quartz!.senderToRawDeviceAssociation.contains("unverified"))
        XCTAssertEqual(result.identityNamespaces.count, 5)
        XCTAssertNil(quartz(sender: 0).ioHIDSenderID)
        XCTAssertEqual(try JSONDecoder().decode(CaptureReport.self, from: JSONEncoder().encode(result)).devices, [device])
    }

    func testOverflowStopsAndCountsEveryLaterCallbackWithoutGrowingStorage() throws {
        let store = CaptureStore(options: try options(limit: 2), originNanoseconds: 0)
        store.observeQuartz(quartz(), acquiredAt: 1)
        raw(store, at: 2, time: 1, count: 0)
        store.observeQuartz(quartz(), acquiredAt: 3)
        raw(store, at: 4, time: 2, count: 0)
        let result = report(store)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.counts.observedQuartz, 2)
        XCTAssertEqual(result.counts.observedRaw, 2)
        XCTAssertEqual(result.counts.droppedRecordLimit, 1)
        XCTAssertEqual(result.counts.droppedAfterStop, 1)
        XCTAssertEqual(result.stopReason, "record_limit_exceeded")
        XCTAssertEqual(result.failureReasons, ["record_limit_exceeded"])
    }

    func testDeadlinePreventsLateAcquisitionAndDoesNotUseSourceClock() throws {
        let store = CaptureStore(options: try options(duration: 0.1), originNanoseconds: 100)
        store.observeQuartz(quartz(timestamp: UInt64.max), acquiredAt: 100_000_099)
        store.observeQuartz(quartz(timestamp: 1), acquiredAt: 100_000_100)
        let result = report(store, at: 100_000_101)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.counts.droppedAfterDeadline, 1)
        XCTAssertEqual(result.stopReason, "duration_elapsed")
    }

    func testClockBeforeOriginIsExplicitFailureRatherThanUnderflow() throws {
        let store = CaptureStore(options: try options(), originNanoseconds: 100)
        store.observeQuartz(quartz(), acquiredAt: 99)
        let result = report(store)
        XCTAssertEqual(result.records.count, 0)
        XCTAssertEqual(result.counts.droppedInvalidRecord, 1)
        XCTAssertEqual(result.failureReasons, ["acquisition_clock_precedes_start"])
    }

    func testSessionsRequireObservedAllUpAndDoNotEndAtStaggeredRelease() throws {
        let store = CaptureStore(options: try options(), originNanoseconds: 0)
        raw(store, at: 1, time: 1, count: 0)
        raw(store, at: 2, time: 2, count: 3)
        raw(store, at: 3, time: 3, count: 1)
        raw(store, at: 4, time: 4, count: 0)
        raw(store, at: 5, time: 5, count: 4)
        let frames = report(store).records.compactMap(\.raw)
        XCTAssertEqual(frames.map(\.boundary), ["observed_all_up", "session_began_after_observed_all_up", "session_continued",
                                                "session_ended_at_observed_all_up", "session_began_after_observed_all_up"])
        XCTAssertEqual(frames[1].observedSessionID, frames[3].observedSessionID)
        XCTAssertNotEqual(frames[1].observedSessionID, frames[4].observedSessionID)
        XCTAssertEqual(frames[2].activeContactCount, 1)
    }

    func testInitialActiveFrameAndCancellationNeverPretendVerifiedBoundary() throws {
        let store = CaptureStore(options: try options(), originNanoseconds: 0)
        raw(store, at: 1, time: 1, count: 3)
        raw(store, at: 2, time: 0, count: 0, cancelled: true)
        let result = report(store)
        XCTAssertEqual(result.records[0].raw?.boundary, "first_observed_active_boundary_unverified")
        XCTAssertEqual(result.records[1].raw?.boundary, "invalidated_bridge_cancelled")
        XCTAssertNil(result.records[1].raw?.activeContactCount)
        XCTAssertEqual(result.counts.rejectedRawFrames, 1)
        XCTAssertEqual(result.failureReasons, ["bridge_rejected_raw_frame"])
    }

    func testSourceClockRegressionInvalidatesRatherThanEndingSession() throws {
        let store = CaptureStore(options: try options(), originNanoseconds: 0)
        raw(store, at: 1, time: 10, count: 3)
        raw(store, at: 2, time: 9, count: 0)
        let result = report(store)
        XCTAssertEqual(result.records[1].raw?.boundary, "invalidated_source_time_regression")
        XCTAssertNil(result.records[1].raw?.activeContactCount)
        XCTAssertEqual(result.counts.timestampRegressions, 1)
        XCTAssertEqual(result.failureReasons, ["raw_source_timestamp_regression"])
    }

    func testNaNInfinityAndUnknownPrivatePhaseRemainSerializableAndExplicit() throws {
        let store = CaptureStore(options: try options(), originNanoseconds: 0)
        store.observeQuartz(quartz(phase: 3, progress: .nan, velocity: .infinity), acquiredAt: 1)
        raw(store, at: 2, time: .nan, count: 0)
        let result = report(store)
        XCTAssertNil(result.records[0].quartz?.privateFields?.progress124)
        XCTAssertNil(result.records[0].quartz?.privateFields?.velocityX129)
        XCTAssertEqual(result.records[0].quartz?.privateFields?.invalidNumericFields, ["progress124_nonfinite", "velocityX129_nonfinite"])
        XCTAssertNil(result.records[0].quartz?.privateFields?.recognizedPhaseName)
        XCTAssertNil(result.records[1].raw?.bridgeTimestampSeconds)
        XCTAssertEqual(result.records[1].raw?.sourceTimestampStatus, "invalid_source_value")
        XCTAssertEqual(result.counts.nonfinitePrivateFields, 1)
        XCTAssertEqual(result.counts.unknownPrivatePhase, 1)
        XCTAssertNoThrow(try json(result))
    }

    func testMalformedCoordinatesAreCountedAndExcludedBeforeSerialization() throws {
        for invalid in [Double.nan, .infinity, -.infinity, -0.1, 1.1] {
            let store = CaptureStore(options: try options(), originNanoseconds: 0)
            store.observeRaw(deviceID: 7, sourceTimestamp: 1, frameNumber: 1, bridgeContactCount: 1,
                             contacts: [CaptureContact(identifier: 1, state: 4, normalizedX: invalid, normalizedY: 0.5)],
                             cancelled: false, acquiredAt: 1)
            let result = report(store)
            XCTAssertTrue(result.records.isEmpty)
            XCTAssertEqual(result.counts.droppedInvalidRecord, 1)
            XCTAssertEqual(result.failureReasons, ["invalid_raw_record"])
            XCTAssertNoThrow(try json(result))
        }
    }

    func testContactAndDeviceLimitsAreHardBounds() throws {
        let invalidContacts = CaptureStore(options: try options(), originNanoseconds: 0)
        raw(invalidContacts, at: 1, time: 1, count: 65)
        XCTAssertEqual(report(invalidContacts).failureReasons, ["invalid_raw_record"])
        let devices = CaptureStore(options: try options(), originNanoseconds: 0)
        for id in 1...257 { raw(devices, at: UInt64(id), time: 1, count: 0, device: UInt64(id)) }
        let result = report(devices)
        XCTAssertEqual(result.records.count, 256)
        XCTAssertEqual(result.failureReasons, ["raw_device_limit_exceeded"])
    }

    func testConcurrentCallbacksAreBoundedAndCounted() throws {
        let store = CaptureStore(options: try options(limit: 128), originNanoseconds: 0)
        DispatchQueue.concurrentPerform(iterations: 512) { index in
            store.observeQuartz(self.quartz(), acquiredAt: UInt64(index + 1))
        }
        let result = report(store)
        XCTAssertEqual(result.records.count, 128)
        XCTAssertEqual(result.counts.observedQuartz, 512)
        XCTAssertEqual(result.counts.storedQuartz + result.counts.droppedRecordLimit + result.counts.droppedAfterStop, 512)
        XCTAssertEqual(result.records.map(\.ordinal), Array(1...128))
    }

    func testPublicKeyboardAndMouseClassesAreExcludedAndPrivacyKeysAreAllowlisted() throws {
        let store = CaptureStore(options: try options(), originNanoseconds: 0)
        for type: UInt32 in [1, 5, 10, 11, 12] { store.observeQuartz(quartz(type: type), acquiredAt: UInt64(type)) }
        let result = report(store)
        XCTAssertEqual(result.counts.droppedUnexpectedClass, 5)
        XCTAssertTrue(result.records.isEmpty)
        let object = try json(CaptureSelfTest.run(options: options()))
        func keys(_ value: Any) -> Set<String> {
            if let dictionary = value as? [String: Any] {
                return dictionary.values.reduce(Set(dictionary.keys)) { $0.union(keys($1)) }
            }
            if let array = value as? [Any] { return array.reduce(Set<String>()) { $0.union(keys($1)) } }
            return []
        }
        let forbidden = Set(["keyCode", "characters", "keyboardText", "mousePosition", "location", "windowName", "appName", "bundleID", "screenshot",
                             "serial", "serialNumber", "productName", "product_name", "quality", "pressure", "hostname", "username", "outputPath", "eventData"])
        XCTAssertTrue(keys(object).isDisjoint(with: forbidden))
        let records = try XCTUnwrap(object["records"] as? [[String: Any]])
        let fields = try XCTUnwrap(records[2]["quartz"] as? [String: Any])
        XCTAssertEqual(Set(fields.keys), Set(["callbackClass", "eventClass", "sourceTimestampNanoseconds", "sourceTimestampClock", "sourcePID",
                                             "sourceUserDataSignedDecimal", "flagsRawValue", "senderAPIAvailable", "ioHIDSenderID", "physicalProvenance",
                                             "senderToRawDeviceAssociation", "classificationStatus", "privateFields"]))
        XCTAssertTrue(CaptureStore.allowedQuartzClasses.isDisjoint(with: CaptureStore.excludedQuartzClasses))
        XCTAssertEqual(CaptureStore.allowedQuartzClasses.union(CaptureStore.excludedQuartzClasses), Set(UInt32(0)..<64))
        XCTAssertEqual(result.eventMaskHex, String(format: "0x%016llx", CaptureStore.eventMask))
    }

    func testUnknownAndWebKitBoundaryClassesKeepMetadataWithoutGuessedFields() throws {
        let store = CaptureStore(options: try options(), originNanoseconds: 0)
        for type: UInt32 in [8, 31, 61, 62, 63] {
            let injected = CaptureQuartzFields(callbackClass: type, eventClass: type, sourceTimestamp: 123,
                                                sourcePID: 0, sourceUserData: 1, senderAPIAvailable: false, senderID: nil,
                                                privateFields: quartz().privateFields, scrollPhase: 4, momentumPhase: 1)
            store.observeQuartz(injected, acquiredAt: UInt64(type))
        }
        let result = report(store)
        XCTAssertEqual(result.records.count, 5)
        for record in result.records {
            XCTAssertEqual(record.quartz?.classificationStatus, "unclassified_metadata_only")
            XCTAssertNil(record.quartz?.privateFields)
            XCTAssertNil(record.quartz?.scrollPhase)
            XCTAssertNil(record.quartz?.momentumPhase)
        }
        XCTAssertTrue(result.eventClassesRequested.contains(61))
        XCTAssertTrue(result.eventClassesRequested.contains(62))
        XCTAssertFalse(result.eventClassesRequested.contains(64))
        XCTAssertNoThrow(try json(result))
    }

    func testAllQuartzFlagBitsSerializeLosslesslyWithoutProvenanceInference() throws {
        let store = CaptureStore(options: try options(), originNanoseconds: 0)
        for (index, flags) in [UInt64(0x20000000), UInt64.max].enumerated() {
            store.observeQuartz(CaptureQuartzFields(callbackClass: 22, eventClass: 22, sourceTimestamp: 1,
                                                     sourcePID: 0, sourceUserData: 0, flagsRawValue: flags,
                                                     senderAPIAvailable: false, senderID: nil), acquiredAt: UInt64(index + 1))
        }
        let result = report(store)
        XCTAssertEqual(result.records[0].quartz?.flagsRawValue, "536870912")
        XCTAssertEqual(result.records[1].quartz?.flagsRawValue, "18446744073709551615")
        XCTAssertEqual(result.records[0].quartz?.physicalProvenance, "unverified_including_PID_zero")
        let records = try XCTUnwrap(json(result)["records"] as? [[String: Any]])
        XCTAssertEqual((records[1]["quartz"] as? [String: Any])?["flagsRawValue"] as? String, "18446744073709551615")
    }

    func testExclusiveOutputRefusesOverwriteAndSymlinksAndUsesOwnerOnlyPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("capture.json").path
        let writer = try ExclusiveCaptureOutput(path: path)
        try writer.write(CaptureSelfTest.run(options: options()))
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try ExclusiveCaptureOutput(path: path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(permissions & 0o077, 0)
        let link = directory.appendingPathComponent("link.json").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
        XCTAssertThrowsError(try ExclusiveCaptureOutput(path: link))
        let dangling = directory.appendingPathComponent("dangling.json").path
        try FileManager.default.createSymbolicLink(atPath: dangling, withDestinationPath: directory.appendingPathComponent("missing").path)
        XCTAssertThrowsError(try ExclusiveCaptureOutput(path: dangling))
    }

    func testPermissionTapAndLifecycleFailuresAreExplicitAndPreserveFirstStop() throws {
        for reason in [CaptureStore.StopReason.missingListenPermission, .tapCreationFailed, .tapDisabled, .sleep, .sessionLost, .devicesChanged, .interrupted] {
            let store = CaptureStore(options: try options(), originNanoseconds: 0)
            store.finish(reason, at: 1)
            store.observeQuartz(quartz(), acquiredAt: 2)
            let result = report(store)
            XCTAssertEqual(result.failureReasons, [reason.rawValue])
            XCTAssertEqual(result.stopReason, reason.rawValue)
            XCTAssertEqual(result.counts.droppedAfterStop, 1)
            XCTAssertEqual(result.outcome, "failed_incomplete_evidence")
        }
    }
}
