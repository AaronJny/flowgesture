import XCTest
import CoreGraphics
import FlowGestureCore
@testable import FlowGestureApp

/// External browser-navigation fixtures, not physical Spaces captures.
/// Only the decoder's classification fields are copied into unposted CGEvents.
final class WebKitNegativeReplayTests: XCTestCase {
    func testAllUpstreamBrowserBackPacketsRemainOutsideNativeSpacesOwnership() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "browser-back", withExtension: "json",
                                                 subdirectory: "Fixtures/WebKitBrowserBack"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(root["revision"] as? String, "f310728c7012151f30108f04e7d56101bf0ac05d")
        let streams = try XCTUnwrap(root["streams"] as? [String: [[String: Any]]])
        let coordinator = NativeRawGestureCoordinator()
        var packetCount = 0
        var gestureEnds: [Int] = []
        var scrollEnds: [Int] = []
        for name in ["beginSwipeBackEventStream", "completeSwipeBackEventStream"] {
            let packets = try XCTUnwrap(streams[name])
            var previousTime = -1
            for packet in packets {
                packetCount += 1
                let time = try XCTUnwrap(packet["relativeTimeMS"] as? Int)
                XCTAssertGreaterThanOrEqual(time, previousTime)
                previousTime = time
                let kind = try XCTUnwrap(packet["kCGSEventTypeField"] as? Int)
                XCTAssertTrue(kind == 22 || kind == 29)
                XCTAssertNil(packet["senderRegistryID"])
                let event = try XCTUnwrap(CGEvent(source: nil))
                event.setIntegerValueField(try XCTUnwrap(CGEventField(rawValue: 55)), value: Int64(kind))
                for (name, field) in [("kCGEventGestureHIDType", UInt32(110)), ("kCGEventGesturePhase", 132)] {
                    if let value = packet[name] as? Int {
                        event.setIntegerValueField(try XCTUnwrap(CGEventField(rawValue: field)), value: Int64(value))
                    }
                }
                // Deliberately do not fabricate sender identity, origin, axis,
                // Dock progress or velocity absent from the upstream stream.
                let decoded = NativeHorizontalSwipeDecoder.decode(
                    type: try XCTUnwrap(CGEventType(rawValue: UInt32(kind))), event: event, senderRegistryID: nil)
                if kind == 22 {
                    XCTAssertNil(decoded)
                    if packet["kCGScrollWheelEventScrollPhase"] as? Int == 4 { scrollEnds.append(time) }
                } else {
                    let value = try XCTUnwrap(decoded)
                    XCTAssertFalse(value.hasHorizontalFingerprint)
                    XCTAssertEqual(value.sourceProvenance, .unverified)
                    let result = coordinator.processNative(value)
                    XCTAssertFalse(result.consume)
                    XCTAssertNil(result.action)
                    if packet["kCGEventGesturePhase"] as? Int == 4 { gestureEnds.append(time) }
                }
            }
        }
        XCTAssertEqual(packetCount, 33)
        XCTAssertEqual(gestureEnds, [121])
        XCTAssertEqual(scrollEnds, [139]) // End boundaries differ across channels.
    }
}
