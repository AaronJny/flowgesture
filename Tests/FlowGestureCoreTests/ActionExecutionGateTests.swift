import XCTest
@testable import FlowGestureCore

final class ActionExecutionGateTests: XCTestCase {
    func testCancellationInvalidatesQueuedBatchButAllowsNewBatch() {
        let gate = ActionExecutionGate(), token = UInt64(0)
        XCTAssertEqual(gate.snapshot(), token)
        XCTAssertTrue(gate.isCurrent(token))
        gate.cancelPending()
        XCTAssertFalse(gate.isCurrent(token))
        XCTAssertTrue(gate.isCurrent(gate.snapshot()))
    }
    func testRepeatedCancellationNeverRevivesOldBatch() {
        let gate = ActionExecutionGate(), first = gate.snapshot()
        for _ in 0..<100 { gate.cancelPending() }
        XCTAssertFalse(gate.isCurrent(first))
        XCTAssertEqual(gate.snapshot(), 100)
    }
}
