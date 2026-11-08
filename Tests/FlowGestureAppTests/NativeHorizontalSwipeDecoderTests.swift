import XCTest
import CoreGraphics
@testable import FlowGestureApp

final class NativeHorizontalSwipeDecoderTests: XCTestCase {
    func testNativeFieldExtractionUsesExactSourceIdentityAndFingerprint() throws {
        let event = try XCTUnwrap(CGEvent(source: nil))
        event.setIntegerValueField(try XCTUnwrap(CGEventField(rawValue: 55)), value: 30)
        event.setIntegerValueField(try XCTUnwrap(CGEventField(rawValue: 110)), value: 23)
        event.setIntegerValueField(try XCTUnwrap(CGEventField(rawValue: 123)), value: 1)
        event.setIntegerValueField(try XCTUnwrap(CGEventField(rawValue: 132)), value: 2)
        event.setDoubleValueField(try XCTUnwrap(CGEventField(rawValue: 124)), value: 0.25)
        event.setDoubleValueField(try XCTUnwrap(CGEventField(rawValue: 129)), value: 100)
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        let decoded = try XCTUnwrap(NativeHorizontalSwipeDecoder.decode(type: try XCTUnwrap(CGEventType(rawValue: 30)),
                                                                        event: event, senderRegistryID: 42))
        XCTAssertTrue(decoded.hasHorizontalFingerprint)
        XCTAssertEqual(decoded.phase, .changed)
        XCTAssertEqual(decoded.senderRegistryID, 42)
        XCTAssertEqual(decoded.progress, 0.25)
        XCTAssertEqual(decoded.velocityX, 100)
    }

    func testSelectorMismatchAndPublicEventsAreRejected() throws {
        let event = try XCTUnwrap(CGEvent(source: nil))
        XCTAssertNil(NativeHorizontalSwipeDecoder.decode(type: .scrollWheel, event: event, senderRegistryID: 42))
        event.setIntegerValueField(try XCTUnwrap(CGEventField(rawValue: 55)), value: 29)
        XCTAssertNil(NativeHorizontalSwipeDecoder.decode(type: try XCTUnwrap(CGEventType(rawValue: 30)), event: event, senderRegistryID: 42))
    }

    func testMissingSenderIsNotSubstitutedWithMultitouchIdentity() throws {
        let event = try XCTUnwrap(CGEvent(source: nil))
        event.setIntegerValueField(try XCTUnwrap(CGEventField(rawValue: 55)), value: 30)
        let decoded = try XCTUnwrap(NativeHorizontalSwipeDecoder.decode(type: try XCTUnwrap(CGEventType(rawValue: 30)), event: event, senderRegistryID: nil))
        XCTAssertNil(decoded.senderRegistryID)
        XCTAssertFalse(decoded.hasHorizontalFingerprint)
    }
}
