import XCTest
@testable import FlowGestureCore

final class DrawGestureRecognizerTests: XCTestCase {
    private func point(_ x: Double, _ y: Double) -> GesturePoint { GesturePoint(x: x, y: y) }

    func testStraightNoisyLineSimplifiesDeterministically() {
        let points = [point(0, 0), point(10, 1), point(20, -2), point(30, 2), point(80, 0)]
        XCTAssertEqual(DrawGestureRecognizer.simplify(points, tolerance: 3), [point(0, 0), point(80, 0)])
        XCTAssertEqual(DrawGestureRecognizer().directions(for: points), [.right])
    }

    func testRightAngleAndReturnPathKeepCorners() {
        let recognizer = DrawGestureRecognizer()
        XCTAssertEqual(recognizer.directions(for: [point(0, 0), point(100, 0), point(100, 100)]), [.right, .up])
        XCTAssertEqual(recognizer.directions(for: [point(0, 0), point(100, 0), point(0, 0)]), [.right, .left])
    }

    func testJitterAndDuplicatePointsDoNotTrigger() {
        let points = [point(0, 0), point(0, 0), point(2, 1), point(1, 2), point(0, 0)]
        XCTAssertEqual(DrawGestureRecognizer().directions(for: points), [])
        XCTAssertEqual(DrawGestureRecognizer.simplify([point(1, 1), point(1, 1)], tolerance: 0), [point(1, 1)])
    }

    func testAllEightDirectionsUsePositiveYUp() {
        let vectors: [(Double, Double, GestureDirection)] = [
            (1, 0, .right), (1, 1, .upRight), (0, 1, .up), (-1, 1, .upLeft),
            (-1, 0, .left), (-1, -1, .downLeft), (0, -1, .down), (1, -1, .downRight)
        ]
        for (x, y, expected) in vectors { XCTAssertEqual(DrawGestureRecognizer.direction(dx: x, dy: y), expected) }
        XCTAssertEqual(DrawGestureRecognizer.direction(dx: 1, dy: 2, includesDiagonals: false), .up)
        XCTAssertNil(DrawGestureRecognizer.direction(dx: 0, dy: 0))
    }

    func testRepeatedDirectionsAreCollapsedAndMatchingIsExact() {
        let recognizer = DrawGestureRecognizer(configuration: DrawGestureConfiguration(simplificationTolerance: 0, minimumSegmentLength: 5))
        let points = [point(0, 0), point(20, 1), point(40, 0), point(40, -40)]
        XCTAssertTrue(recognizer.matches(points, directions: [.right, .down]))
        XCTAssertFalse(recognizer.matches(points, directions: [.right]))
        XCTAssertFalse(recognizer.matches([], directions: []))
    }

    func testOverlongAndMalformedPathsRejectRatherThanTruncate() {
        let recognizer = DrawGestureRecognizer(configuration: DrawGestureConfiguration(maximumDirections: 1))
        XCTAssertEqual(recognizer.directions(for: [point(0, 0), point(100, 0), point(100, 100)]), [])
        XCTAssertEqual(recognizer.directions(for: [point(0, 0), point(.nan, 10), point(100, 0)]), [])
        XCTAssertEqual(DrawGestureRecognizer.simplify([point(0, 0)], tolerance: -1), [])
        XCTAssertNil(DrawGestureRecognizer.direction(dx: .infinity, dy: 1))
    }
}
