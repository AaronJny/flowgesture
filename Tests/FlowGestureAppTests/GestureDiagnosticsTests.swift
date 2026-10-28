#if os(macOS)
import CoreGraphics
import Foundation
import XCTest
@testable import FlowGestureApp

final class GestureDiagnosticsTests: XCTestCase {
    func testRingPreservesChronologicalOrderAndBoundsMemory() {
        var buffer = GestureDiagnosticBuffer(capacity: 3)
        XCTAssertTrue(buffer.snapshot().isEmpty)
        for value in 0..<7 { buffer.append(GestureDiagnosticRecord(receiptTime: Double(value), rawType: UInt32(value))) }
        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.dropped, 4)
        XCTAssertEqual(buffer.snapshot().map(\.receiptTime), [4, 5, 6])
    }

    func testUnknownRecordEncodesOnlyReceiptAndRawType() throws {
        let record = GestureDiagnosticRecord(receiptTime: 0.25, rawType: 29)
        let data = try JSONEncoder().encode(record)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["receiptTime", "rawType"])
    }

    func testTouchAndSenderIdentitiesRemainSeparate() throws {
        let record = GestureDiagnosticRecord(receiptTime: 1, touchDeviceID: 42, contactCount: 3, cancelled: true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["receiptTime", "touchDeviceID", "contactCount", "cancelled"])
        XCTAssertNil(object["senderID"])
    }

    func testDurationIsFinitePositiveAndAtMostSixtySeconds() {
        XCTAssertEqual(GestureDiagnostics.validatedDuration(60), 60)
        XCTAssertEqual(GestureDiagnostics.validatedDuration(600), 60)
        XCTAssertEqual(GestureDiagnostics.validatedDuration(0.5), 0.5)
        for invalid in [0, -1, Double.infinity, Double.nan] {
            XCTAssertNil(GestureDiagnostics.validatedDuration(invalid))
        }
    }

    func testMaskExcludesKeyboardPointerButtonsAndTabletsButKeepsScroll() {
        let mask = GestureDiagnostics.observationMask
        let excluded: [CGEventType] = [.null, .keyDown, .keyUp, .flagsChanged, .mouseMoved,
                                      .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                      .otherMouseDown, .otherMouseUp, .leftMouseDragged,
                                      .rightMouseDragged, .otherMouseDragged, .tabletPointer, .tabletProximity]
        for type in excluded { XCTAssertEqual(mask & (1 << type.rawValue), 0) }
        XCTAssertNotEqual(mask & (1 << CGEventType.scrollWheel.rawValue), 0)
    }

    func testRecognitionNamesRejectUserTextAndKeepOnlyKnownGestureVocabulary() {
        for name in ["tap.1", "tap.5", "swipe.3.up", "swipe.4.downRight", "pinch.inward", "pinch.outward"] {
            XCTAssertTrue(GestureDiagnostics.isAllowedRecognitionName(name), name)
        }
        for name in ["", "My private rule", "https://example.com", "tap.03", "tap.6", "tap.-1",
                     "swipe.3.sideways", "swipe.3.up.secret", "pinch.inward\n", "key.8", "tap..3"] {
            XCTAssertFalse(GestureDiagnostics.isAllowedRecognitionName(name), name)
        }
    }

    @MainActor func testDefaultSnapshotIsIdleEmptyAndDoesNotOpenATap() async throws {
        XCTAssertTrue(Thread.isMainThread)
        let diagnostics = GestureDiagnostics()
        diagnostics.recordTouchFrame(deviceID: 1, contacts: 2, cancelled: false)
        diagnostics.recordRecognition("tap.2")
        diagnostics.stop()
        let result = try JSONDecoder().decode(GestureDiagnosticSnapshot.self, from: diagnostics.snapshotData())
        XCTAssertFalse(diagnostics.isRunning)
        XCTAssertFalse(result.isRunning)
        XCTAssertEqual(result.capacity, 512)
        XCTAssertTrue(result.records.isEmpty)
    }
}
#endif
