import XCTest
@testable import FlowGestureCore

final class ScrollSmootherTests: XCTestCase {
    func testIntegerDeltasAreConservedOnIndependentOppositeAxes() {
        var smoother = ScrollSmoother()
        smoother.add(vertical: 997, horizontal: -311)
        var vertical = 0, horizontal = 0
        for _ in 0..<1_000 {
            let value = smoother.step(deltaTime: 1.0 / 120, duration: 0.12)
            XCTAssertGreaterThanOrEqual(value.vertical, 0)
            XCTAssertLessThanOrEqual(value.horizontal, 0)
            vertical += Int(value.vertical)
            horizontal += Int(value.horizontal)
        }
        XCTAssertEqual(vertical, 997)
        XCTAssertEqual(horizontal, -311)
        XCTAssertEqual(smoother.pendingVertical, 0)
        XCTAssertEqual(smoother.pendingHorizontal, 0)
    }

    func testReversalCancelsPendingInputIndependently() {
        var smoother = ScrollSmoother()
        smoother.add(vertical: 100, horizontal: 20)
        smoother.add(vertical: -140, horizontal: 30)
        var vertical = 0, horizontal = 0
        for _ in 0..<100 {
            let value = smoother.step(deltaTime: 1.0 / 120, duration: 0.12)
            XCTAssertLessThanOrEqual(value.vertical, 0)
            XCTAssertGreaterThanOrEqual(value.horizontal, 0)
            vertical += Int(value.vertical)
            horizontal += Int(value.horizontal)
        }
        XCTAssertEqual(vertical, -40)
        XCTAssertEqual(horizontal, 50)
    }

    func testFractionalTailsNeverOscillateAndAccumulateFutureInput() {
        var smoother = ScrollSmoother()
        smoother.add(vertical: 0.75, horizontal: -0.75)
        for _ in 0..<100 {
            let value = smoother.step(deltaTime: 1.0 / 120, duration: 0.12)
            XCTAssertEqual(value.vertical, 0)
            XCTAssertEqual(value.horizontal, 0)
        }
        smoother.add(vertical: 0.5, horizontal: -0.5)
        let value = smoother.step(deltaTime: 1.0 / 120, duration: 0.12)
        XCTAssertEqual(value.vertical, 1)
        XCTAssertEqual(value.horizontal, -1)
        XCTAssertEqual(smoother.pendingVertical, 0.25)
        XCTAssertEqual(smoother.pendingHorizontal, -0.25)
        for _ in 0..<100 {
            let tail = smoother.step(deltaTime: 1.0 / 120, duration: 0.12)
            XCTAssertEqual(tail.vertical, 0)
            XCTAssertEqual(tail.horizontal, 0)
        }
    }

    func testNonFiniteInputsAndInvalidTimeCannotCorruptState() {
        var smoother = ScrollSmoother()
        smoother.add(vertical: .nan, horizontal: 5)
        smoother.add(vertical: 10, horizontal: .infinity)
        for dt in [0.0, -1.0, .nan, .infinity] {
            let result = smoother.step(deltaTime: dt, duration: 0.12)
            XCTAssertEqual(result.vertical, 0)
            XCTAssertEqual(result.horizontal, 0)
        }
        XCTAssertEqual(smoother.pendingVertical, 10)
        XCTAssertEqual(smoother.pendingHorizontal, 5)
        let result = smoother.step(deltaTime: 1.0 / 120, duration: .nan)
        XCTAssertGreaterThan(result.vertical, 0)
        XCTAssertGreaterThan(result.horizontal, 0)
    }

    func testAccumulationAndStepBoundsPreventIntegerOverflow() {
        var smoother = ScrollSmoother()
        smoother.add(vertical: Double.greatestFiniteMagnitude, horizontal: -Double.greatestFiniteMagnitude)
        XCTAssertEqual(smoother.pendingVertical, ScrollSmoother.maximumPendingMagnitude)
        XCTAssertEqual(smoother.pendingHorizontal, -ScrollSmoother.maximumPendingMagnitude)
        let value = smoother.step(deltaTime: 100, duration: -1)
        XCTAssertEqual(value.vertical, ScrollSmoother.maximumStepMagnitude)
        XCTAssertEqual(value.horizontal, -ScrollSmoother.maximumStepMagnitude)
        XCTAssertEqual(smoother.pendingVertical, 990_000)
        XCTAssertEqual(smoother.pendingHorizontal, -990_000)
    }

    func testResetClearsWholeAndFractionalPendingInput() {
        var smoother = ScrollSmoother()
        smoother.add(vertical: 30.5, horizontal: -0.3)
        smoother.reset()
        let value = smoother.step(deltaTime: 1, duration: 0.12)
        XCTAssertEqual(value.vertical, 0)
        XCTAssertEqual(value.horizontal, 0)
        XCTAssertEqual(smoother.pendingVertical, 0)
        XCTAssertEqual(smoother.pendingHorizontal, 0)
    }
}
