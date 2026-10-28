import XCTest
@testable import FlowGestureCore

final class ClickSequenceResolverTests: XCTestCase {
    func testSingleWaitsForPossibleDoubleThenDeliversOnce() {
        var resolver = ClickSequenceResolver()
        XCTAssertEqual(resolver.evaluate(count: 1, maxRegisteredClickCount: 2, now: 0, interval: 0.5), .deferred(deadline: 0.5))
        XCTAssertNil(resolver.advance(now: 0.49))
        XCTAssertEqual(resolver.advance(now: 0.5), 1)
        XCTAssertNil(resolver.advance(now: 1))
    }

    func testDoubleSupersedesSingleWithoutPrematureAction() {
        var resolver = ClickSequenceResolver()
        _ = resolver.evaluate(count: 1, maxRegisteredClickCount: 2, now: 0, interval: 0.5)
        XCTAssertEqual(resolver.evaluate(count: 2, maxRegisteredClickCount: 2, now: 0.2, interval: 0.5), .deliver(count: 2))
        XCTAssertNil(resolver.advance(now: 1))
        XCTAssertEqual(resolver.evaluate(count: 2, maxRegisteredClickCount: 2, now: 1, interval: 0.5), .ignored)
    }

    func testTripleSupersedesBothLowerCandidates() {
        var resolver = ClickSequenceResolver()
        _ = resolver.evaluate(count: 1, maxRegisteredClickCount: 3, now: 0, interval: 0.5)
        XCTAssertEqual(resolver.evaluate(count: 2, maxRegisteredClickCount: 3, now: 0.2, interval: 0.5), .deferred(deadline: 0.7))
        XCTAssertEqual(resolver.evaluate(count: 3, maxRegisteredClickCount: 3, now: 0.4, interval: 0.5), .deliver(count: 3))
        XCTAssertNil(resolver.advance(now: 1))
    }

    func testDoubleExpiresWhenThirdClickNeverArrives() {
        var resolver = ClickSequenceResolver()
        _ = resolver.evaluate(count: 1, hasHigherCount: true, now: 0, interval: 0.5)
        _ = resolver.evaluate(count: 2, hasHigherCount: true, now: 0.2, interval: 0.5)
        XCTAssertEqual(resolver.pendingCount, 2)
        XCTAssertNil(resolver.advance(now: 0.6))
        XCTAssertEqual(resolver.advance(now: 0.7), 2)
    }

    func testSingleOnlyBindingHandlesEveryPhysicalClickImmediately() {
        var resolver = ClickSequenceResolver()
        for count in 1...4 {
            XCTAssertEqual(resolver.evaluate(count: count, maxRegisteredClickCount: 1, now: Double(count), interval: 0.5), .deliver(count: 1))
        }
        XCTAssertNil(resolver.deadline)
    }

    func testCancellationDiscardsPendingAndResetsClock() {
        var resolver = ClickSequenceResolver()
        _ = resolver.evaluate(count: 1, maxRegisteredClickCount: 3, now: 100, interval: 0.5)
        resolver.cancel()
        XCTAssertNil(resolver.advance(now: 0))
        XCTAssertEqual(resolver.evaluate(count: 1, maxRegisteredClickCount: 2, now: 0, interval: 0.5), .deferred(deadline: 0.5))
    }

    func testInvalidTimeAndCountsDoNotReplaceCandidate() {
        var resolver = ClickSequenceResolver()
        _ = resolver.evaluate(count: 1, maxRegisteredClickCount: 2, now: 1, interval: 0.5)
        XCTAssertEqual(resolver.evaluate(count: 2, maxRegisteredClickCount: 2, now: 0.5, interval: 0.5), .ignored)
        XCTAssertEqual(resolver.evaluate(count: 2, maxRegisteredClickCount: 2, now: 1.1, interval: .nan), .ignored)
        XCTAssertEqual(resolver.evaluate(count: 0, maxRegisteredClickCount: 2, now: 1.1, interval: 0.5), .ignored)
        XCTAssertNil(resolver.advance(now: .nan))
        XCTAssertEqual(resolver.advance(now: 1.5), 1)
    }

    func testAdvanceBeforeNewSequencePreservesBothDeliveries() {
        var resolver = ClickSequenceResolver()
        _ = resolver.evaluate(count: 1, maxRegisteredClickCount: 2, now: 0, interval: 0.5)
        XCTAssertEqual(resolver.advance(now: 1), 1)
        XCTAssertEqual(resolver.evaluate(count: 1, maxRegisteredClickCount: 2, now: 1, interval: 0.5), .deferred(deadline: 1.5))
        XCTAssertEqual(resolver.advance(now: 1.5), 1)
    }
}
