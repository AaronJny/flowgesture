#if os(macOS)
import CoreGraphics
import FlowGestureCore
import XCTest
@testable import FlowGestureApp

final class ScrollEventTransformerTests: XCTestCase {
    private let integerFields: [CGEventField] = [.scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1,
                                                .scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2]
    private let fixedFields: [CGEventField] = [.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2]

    /// Real CGEvent instances, only modified in memory; nothing is posted to the OS.
    private func event(continuous: Bool = false, phase: Int64 = 0, momentum: Int64 = 0) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 3,
                                          wheel1: 3, wheel2: -2, wheel3: 1))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 3)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 30)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 3.5)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -2)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -20)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -2.25)
        event.flags = [.maskShift, .maskAlternate]
        event.location = CGPoint(x: 123, y: 456)
        event.timestamp = 123_456_789
        event.setIntegerValueField(.eventSourceUserData, value: 42)
        return event
    }

    func testUnknownDiscreteWheelReversesEveryDeltaRepresentation() throws {
        let event = try event()
        let integers = integerFields.map { event.getIntegerValueField($0) }
        let fixed = fixedFields.map { event.getDoubleValueField($0) }
        let configuration = ScrollConfiguration(isEnabled: true, reverseVertical: true, reverseHorizontal: true, smooth: false)
        XCTAssertTrue(ScrollEventTransformer.transform(event, deviceKind: .unknown, configuration: configuration))
        for (index, field) in integerFields.enumerated() { XCTAssertEqual(event.getIntegerValueField(field), -integers[index]) }
        for (index, field) in fixedFields.enumerated() { XCTAssertEqual(event.getDoubleValueField(field), -fixed[index], accuracy: 0.00001) }
    }

    func testUnknownDiscreteWheelSmoothPathReversesActualPixelEvents() throws {
        let input = try event()
        let configuration = ScrollConfiguration(isEnabled: true, reverseVertical: true)
        XCTAssertTrue(configuration.smooth)
        XCTAssertEqual(configuration.effectiveSmoothingDuration, 0.12)
        XCTAssertTrue(ScrollEventTransformer.shouldTransform(input, deviceKind: .unknown, configuration: configuration))
        let inputVertical = input.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let inputHorizontal = input.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        XCTAssertGreaterThan(inputVertical, 0)
        let transformed = configuration.transform(vertical: Double(inputVertical) * 10,
                                                    horizontal: Double(inputHorizontal) * 10,
                                                    isContinuous: false)
        var smoother = ScrollSmoother()
        smoother.add(vertical: transformed.vertical, horizontal: transformed.horizontal)
        var emittedCount = 0
        var totalVertical: Int64 = 0
        var totalHorizontal: Int64 = 0
        for _ in 0..<1_000 {
            let step = smoother.step(deltaTime: 1.0 / 120, duration: configuration.effectiveSmoothingDuration)
            guard step.vertical != 0 || step.horizontal != 0 else { continue }
            // Mirror EventEngine.tickScroll's pixel event construction, without posting.
            let output = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                               wheel1: step.vertical, wheel2: step.horizontal, wheel3: 0))
            let vertical = output.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            let horizontal = output.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
            XCTAssertLessThan(vertical, 0, "Every emitted vertical step must reverse the positive wheel input")
            XCTAssertLessThanOrEqual(horizontal, 0, "Vertical reversal must not reverse the negative horizontal input")
            totalVertical += vertical
            totalHorizontal += horizontal
            emittedCount += 1
        }
        XCTAssertGreaterThan(emittedCount, 1, "120 ms smoothing should produce multiple pixel events")
        XCTAssertEqual(totalVertical, -inputVertical * 10)
        XCTAssertEqual(totalHorizontal, inputHorizontal * 10)
        XCTAssertEqual(smoother.pendingVertical, 0)
        XCTAssertEqual(smoother.pendingHorizontal, 0)
    }

    func testAxesReverseAndScaleIndependently() throws {
        let event = try event()
        let before = integerFields.map { event.getIntegerValueField($0) }
        let fixedBefore = fixedFields.map { event.getDoubleValueField($0) }
        let configuration = ScrollConfiguration(isEnabled: true, reverseHorizontal: true, verticalMultiplier: 2, horizontalMultiplier: 3)
        XCTAssertTrue(ScrollEventTransformer.transform(event, deviceKind: .mouse, configuration: configuration))
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), before[0] * 2)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), before[1] * 2)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis2), before[2] * -3)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), before[3] * -3)
        XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), fixedBefore[0] * 2, accuracy: 0.00001)
        XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2), fixedBefore[1] * -3, accuracy: 0.00001)
    }

    func testKnownTrackpadNeverChangesByDefaultEvenWithDiscreteFlag() throws {
        for continuous in [false, true] {
            let event = try event(continuous: continuous)
            let before = integerFields.map { event.getIntegerValueField($0) }
            let fixed = fixedFields.map { event.getDoubleValueField($0) }
            XCTAssertFalse(ScrollEventTransformer.transform(event, deviceKind: .trackpad,
                configuration: ScrollConfiguration(isEnabled: true, reverseVertical: true)))
            XCTAssertEqual(integerFields.map { event.getIntegerValueField($0) }, before)
            XCTAssertEqual(fixedFields.map { event.getDoubleValueField($0) }, fixed)
        }
    }

    func testUnknownContinuousOrPhasedEventsStayUntouchedByDefault() throws {
        for (continuous, phase, momentum) in [(true, Int64(0), Int64(0)), (false, 1, 0), (false, 0, 1)] {
            let event = try event(continuous: continuous, phase: phase, momentum: momentum)
            let before = integerFields.map { event.getIntegerValueField($0) }
            XCTAssertFalse(ScrollEventTransformer.transform(event, deviceKind: .unknown,
                configuration: ScrollConfiguration(isEnabled: true, reverseVertical: true)))
            XCTAssertEqual(integerFields.map { event.getIntegerValueField($0) }, before)
        }
    }

    func testKnownContinuousMouseWorksAndPreservesNativeMetadata() throws {
        let event = try event(continuous: true, phase: 2, momentum: 1)
        let thirdAxis = event.getIntegerValueField(.scrollWheelEventDeltaAxis3)
        let fixedThird = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis3)
        let vertical = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        XCTAssertTrue(ScrollEventTransformer.transform(event, deviceKind: .mouse,
            configuration: ScrollConfiguration(isEnabled: true, reverseVertical: true)))
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -vertical)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventIsContinuous), 1)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventScrollPhase), 2)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventMomentumPhase), 1)
        XCTAssertEqual(event.flags, [.maskShift, .maskAlternate])
        XCTAssertEqual(event.location, CGPoint(x: 123, y: 456))
        XCTAssertEqual(event.timestamp, 123_456_789)
        XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), 42)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis3), thirdAxis)
        XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis3), fixedThird)
    }

    func testExplicitTouchOptInAllowsTrackpadAndUnknownContinuous() throws {
        let configuration = ScrollConfiguration(isEnabled: true, reverseVertical: true, affectsContinuousScrolling: true)
        for device in [TouchDeviceKind.trackpad, .unknown] {
            let event = try event(continuous: true, phase: 1, momentum: 1)
            XCTAssertTrue(ScrollEventTransformer.transform(event, deviceKind: device, configuration: configuration))
            XCTAssertLessThan(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 0)
        }
    }

    func testDisabledConfigurationNeverMutatesEvenWithOptIn() throws {
        let event = try event()
        let before = integerFields.map { event.getIntegerValueField($0) }
        let configuration = ScrollConfiguration(isEnabled: false, reverseVertical: true, affectsContinuousScrolling: true)
        for device in [TouchDeviceKind.mouse, .trackpad, .unknown] {
            XCTAssertFalse(ScrollEventTransformer.transform(event, deviceKind: device, configuration: configuration))
        }
        XCTAssertEqual(integerFields.map { event.getIntegerValueField($0) }, before)
    }

    func testNonScrollEventsAreRejected() throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        XCTAssertFalse(ScrollEventTransformer.transform(event, deviceKind: .mouse,
            configuration: ScrollConfiguration(isEnabled: true, reverseVertical: true)))
    }

    func testMalformedMultiplierFallsBackAndLargeIntegerDeltaIsBounded() throws {
        let event = try event()
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 2_000_000_000)
        let configuration = ScrollConfiguration(isEnabled: true, reverseVertical: true,
            verticalMultiplier: .nan, horizontalMultiplier: .infinity)
        XCTAssertTrue(ScrollEventTransformer.transform(event, deviceKind: .mouse, configuration: configuration))
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -1_000_000_000)
        XCTAssertTrue(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1).isFinite)
    }
}
#endif
