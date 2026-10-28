import XCTest
@testable import FlowGestureCore

final class ShapeGestureRecognizerTests: XCTestCase {
    private let recognizer = ShapeGestureRecognizer()
    private func point(_ x: Double, _ y: Double) -> GesturePoint { GesturePoint(x: x, y: y) }
    private var hook: [GesturePoint] { [point(0, 100), point(0, 0), point(80, 0), point(80, 55)] }

    func testUniformScaleAndTranslationPreserveMatch() throws {
        let moved = hook.map { point($0.x * 3.5 - 1200, $0.y * 3.5 + 300) }
        XCTAssertEqual(try XCTUnwrap(recognizer.similarity(moved, to: hook)), 1, accuracy: 1e-10)
        XCTAssertTrue(recognizer.matches(moved, template: hook))
        XCTAssertEqual(ShapeGestureRecognizer.normalizedPath(hook).count, 64)
    }

    func testSamplingSpeedAndConsecutiveDuplicatesDoNotMatter() throws {
        let sparse = [point(0, 0), point(100, 0), point(100, 100)]
        let dense = [point(0, 0), point(0, 0), point(1, 0), point(5, 0), point(90, 0), point(100, 0), point(100, 2), point(100, 100)]
        XCTAssertEqual(try XCTUnwrap(recognizer.similarity(sparse, to: dense)), 1, accuracy: 1e-10)
    }

    func testOrientationDirectionAndAspectRatioRemainSignificant() {
        let rotated = hook.map { point(-$0.y, $0.x) }
        let mirrored = hook.map { point(-$0.x, $0.y) }
        let stretched = hook.map { point($0.x * 0.1, $0.y) }
        XCTAssertFalse(recognizer.matches(rotated, template: hook))
        XCTAssertFalse(recognizer.matches(mirrored, template: hook))
        XCTAssertFalse(recognizer.matches(Array(hook.reversed()), template: hook))
        XCTAssertFalse(recognizer.matches(stretched, template: hook, tolerance: 0.1))
    }

    func testClosedShapesKeepStartPointAndDirection() {
        let square = [point(0, 0), point(100, 0), point(100, 100), point(0, 100), point(0, 0)]
        let shiftedStart = [point(100, 0), point(100, 100), point(0, 100), point(0, 0), point(100, 0)]
        XCTAssertTrue(recognizer.matches(square, template: square))
        XCTAssertFalse(recognizer.matches(shiftedStart, template: square))
        XCTAssertFalse(recognizer.matches(Array(square.reversed()), template: square))
    }

    func testModerateDrawingNoiseMatchesAndDifferentShapeDoesNot() {
        let noisy = [point(3, 100), point(-2, 50), point(0, 2), point(40, -2), point(81, 0), point(78, 30), point(82, 56)]
        XCTAssertTrue(recognizer.matches(noisy, template: hook))
        XCTAssertFalse(recognizer.matches([point(0, 0), point(100, 100)], template: hook))
    }

    func testInvalidDegenerateOversizedAndOverflowPathsFailClosed() {
        XCTAssertNil(recognizer.similarity([], to: hook))
        XCTAssertNil(recognizer.similarity([point(1, 1), point(1, 1)], to: hook))
        XCTAssertNil(recognizer.similarity([point(0, 0), point(.nan, 1)], to: hook))
        XCTAssertNil(recognizer.similarity([point(-Double.greatestFiniteMagnitude, 0), point(Double.greatestFiniteMagnitude, 0)], to: hook))
        XCTAssertNil(recognizer.similarity(Array(repeating: point(0, 0), count: 2_049), to: hook))
        XCTAssertFalse(recognizer.matches(hook, template: hook, tolerance: .nan))
        XCTAssertFalse(recognizer.matches(hook, template: hook, tolerance: 0))
        XCTAssertFalse(recognizer.matches(hook, template: hook, tolerance: 1))
    }

    func testTemplatePointRoundTripAndRuleBookCompatibility() throws {
        let rule = Rule(name: "Hook", trigger: .shape(ShapeGestureTrigger(points: ShapeGestureRecognizer.normalizedPath(hook))), actions: [.system(.showDesktop)])
        let book = RuleBook(rules: [rule])
        let decoded = try JSONDecoder().decode(RuleBook.self, from: JSONEncoder().encode(book))
        XCTAssertEqual(book, decoded)
        XCTAssertTrue(decoded.validationIssues().isEmpty)
        // Adding a new associated enum case must not change existing rule JSON.
        let oldRule = Rule(name: "Existing direction", trigger: .draw(DrawGestureTrigger(directions: [.left])), actions: [.system(.showDesktop)])
        let oldDecoded = try JSONDecoder().decode(Rule.self, from: JSONEncoder().encode(oldRule))
        XCTAssertEqual(oldRule, oldDecoded)
    }

    func testShapeMatchingUsesTemplateToleranceAndExistingAppPrecedence() {
        let global = Rule(name: "Global", trigger: .shape(ShapeGestureTrigger(points: hook)), actions: [.system(.showDesktop)], priority: 100)
        let scoped = Rule(name: "Scoped", trigger: .shape(ShapeGestureTrigger(points: hook)), scope: AppScope(bundleIdentifiers: ["com.example.editor"]), actions: [.system(.missionControl)])
        let actual = InputTrigger.shape(ShapeGestureTrigger(points: hook.map { point($0.x * 2 + 50, $0.y * 2 - 25) }, tolerance: 0.4))
        XCTAssertEqual(RuleMatcher.bestMatch(for: actual, in: "com.example.editor", rules: [global, scoped])?.id, scoped.id)
        XCTAssertEqual(RuleMatcher.bestMatch(for: actual, in: "com.example.other", rules: [global, scoped])?.id, global.id)
        XCTAssertNil(RuleMatcher.bestMatch(for: actual, in: "com.example.editor", rules: [global, scoped], excludedBundleIdentifiers: ["com.example.editor"]))
        let wrongButton = InputTrigger.shape(ShapeGestureTrigger(button: .middle, points: hook))
        XCTAssertNil(RuleMatcher.bestMatch(for: wrongButton, in: "com.example.editor", rules: [global, scoped]))
    }

    func testShapeValidationAndPhysicalExtentHelper() throws {
        let invalid = Rule(name: "Incomplete", trigger: .shape(ShapeGestureTrigger(points: [], tolerance: 0.7)), actions: [.system(.showDesktop)])
        XCTAssertEqual(RuleBook(rules: [invalid]).validationIssues().count, 2)
        XCTAssertEqual(try XCTUnwrap(ShapeGestureRecognizer.strokeExtent(hook)), 100, accuracy: 0.001)
        XCTAssertNil(ShapeGestureRecognizer.strokeExtent([point(0, 0)]))
        XCTAssertNil(ShapeGestureRecognizer.strokeExtent([point(0, 0), point(.infinity, 0)]))
    }
}
