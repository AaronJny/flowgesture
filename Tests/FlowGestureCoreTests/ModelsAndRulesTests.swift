import Foundation
import XCTest
@testable import FlowGestureCore

final class ModelsAndRulesTests: XCTestCase {
    private let trigger = InputTrigger.keyboard(KeyboardShortcut(keyCode: 8, modifiers: [.command, .shift]))
    private let action = Action.shortcut(KeyboardShortcut(keyCode: 9, modifiers: .command))

    func testAllModelVariantsRoundTripThroughJSON() throws {
        let triggers: [InputTrigger] = [
            .mouseButton(MouseButtonTrigger(button: .back, clickCount: 2, modifiers: .option)),
            .draw(DrawGestureTrigger(button: .right, directions: [.left, .down], modifiers: .control)),
            trigger,
            .touch(TouchGestureTrigger(gesture: .tap(fingers: 3))),
            .touch(TouchGestureTrigger(gesture: .swipe(fingers: 4, direction: .up))),
            .touch(TouchGestureTrigger(gesture: .pinch(.inward))),
            .screenCorner(ScreenCornerTrigger(corner: .bottomRight, modifiers: .shift))
        ]
        let actions: [Action] = [
            action, .openURL("https://example.com"), .openApplication("com.apple.finder"), .openPath("~/Documents"),
            .appleScript("return 1"), .menuItem(["File", "New Window"]), .window(.leftHalf),
            .windowFrame(x: 0.1, y: 0.2, width: 0.5, height: 0.5), .system(.missionControl)
        ]
        let rules = triggers.enumerated().map { Rule(name: "Rule \($0.offset)", trigger: $0.element,
            scope: AppScope(bundleIdentifiers: ["com.example.editor"], excludedBundleIdentifiers: ["com.example.passwords"]),
            actions: actions, priority: $0.offset) }
        let book = RuleBook(rules: rules,
                            scroll: ScrollConfiguration(isEnabled: true, reverseVertical: true, verticalMultiplier: 1.5),
                            excludedBundleIdentifiers: ["com.example.game"])
        let encoded = try JSONEncoder().encode(book)
        XCTAssertEqual(try JSONDecoder().decode(RuleBook.self, from: encoded), book)
        XCTAssertTrue(book.validationIssues().isEmpty)
    }

    func testAppSpecificRuleWinsOverHighPriorityGlobalRule() {
        let global = Rule(name: "Global", trigger: trigger, actions: [action], priority: 100)
        let app = Rule(name: "Editor", trigger: trigger, scope: AppScope(bundleIdentifiers: ["com.example.editor"]), actions: [action])
        XCTAssertEqual(RuleMatcher.bestMatch(for: trigger, in: "com.example.editor", rules: [global, app])?.id, app.id)
        XCTAssertEqual(RuleMatcher.bestMatch(for: trigger, in: "com.example.browser", rules: [global, app])?.id, global.id)
    }

    func testPriorityThenSavedOrderBreakTies() {
        let first = Rule(name: "First", trigger: trigger, actions: [action], priority: 1)
        let second = Rule(name: "Second", trigger: trigger, actions: [action], priority: 1)
        var high = Rule(name: "High", trigger: trigger, actions: [action], priority: 2)
        XCTAssertEqual(RuleMatcher.matchingRules(for: trigger, in: "com.example.app", rules: [first, second, high]).map(\.id), [high.id, first.id, second.id])
        high.isEnabled = false
        XCTAssertEqual(RuleMatcher.bestMatch(for: trigger, in: nil, rules: [first, second, high])?.id, first.id)
    }

    func testExclusionsOverrideAppInclusionsAndGlobalRules() {
        let app = "com.example.editor"
        let scope = AppScope(bundleIdentifiers: [app], excludedBundleIdentifiers: [app])
        let rule = Rule(trigger: trigger, scope: scope, actions: [action])
        XCTAssertNil(RuleMatcher.bestMatch(for: trigger, in: app, rules: [rule]))
        let global = Rule(trigger: trigger, actions: [action])
        XCTAssertNil(RuleMatcher.bestMatch(for: trigger, in: app, rules: [global], excludedBundleIdentifiers: [app]))
        XCTAssertNil(RuleMatcher.bestMatch(for: trigger, in: nil, rules: [global], excludedBundleIdentifiers: [app]))
        XCTAssertFalse(AppScope(excludedBundleIdentifiers: [app]).includes(nil))
        XCTAssertFalse(scope.includes(nil))
    }

    func testModifiersAndTriggerDetailsMatchExactly() {
        let rule = Rule(trigger: trigger, actions: [action])
        let withoutShift = InputTrigger.keyboard(KeyboardShortcut(keyCode: 8, modifiers: .command))
        XCTAssertNil(RuleMatcher.bestMatch(for: withoutShift, in: nil, rules: [rule]))
        XCTAssertNotNil(RuleMatcher.bestMatch(for: trigger, in: nil, ruleBook: RuleBook(rules: [rule])))
    }

    func testValidationRejectsUnsupportedSchemaDuplicatesAndMalformedRules() {
        let invalid = Rule(name: "  ", trigger: .draw(DrawGestureTrigger(directions: [.left, .left])), actions: [])
        let book = RuleBook(schemaVersion: 9, rules: [invalid, invalid], scroll: ScrollConfiguration(verticalMultiplier: -1))
        let paths = Set(book.validationIssues().map(\.path))
        XCTAssertTrue(paths.contains("schemaVersion"))
        XCTAssertTrue(paths.contains("rules[1].id"))
        XCTAssertTrue(paths.contains("rules[0].name"))
        XCTAssertTrue(paths.contains("rules[0].trigger"))
        XCTAssertTrue(paths.contains("rules[0].actions"))
        XCTAssertTrue(paths.contains("scroll.verticalMultiplier"))
    }

    func testValidationRejectsUnsafeMalformedActionPayloads() {
        let bad: [Action] = [.openURL("relative/path"), .openApplication(""), .openPath("relative/path"),
                             .appleScript(" "), .menuItem(["File", ""]), .windowFrame(x: 0.9, y: 0, width: 0.5, height: 1)]
        let book = RuleBook(rules: [Rule(trigger: trigger, actions: bad)])
        XCTAssertEqual(book.validationIssues().count, bad.count)
    }

    func testDisabledScrollAndContinuousScrollRemainUnchanged() {
        let disabled = ScrollConfiguration(reverseVertical: true, verticalMultiplier: 2)
        XCTAssertEqual(disabled.transform(vertical: 3, horizontal: 2).vertical, 3)
        let wheelOnly = ScrollConfiguration(isEnabled: true, reverseVertical: true, verticalMultiplier: 2)
        XCTAssertEqual(wheelOnly.transform(vertical: 3, horizontal: 2, isContinuous: true).vertical, 3)
        XCTAssertEqual(wheelOnly.transform(vertical: 3, horizontal: 2).vertical, -6)
    }

    func testScrollTransformAndSmoothingDefendAgainstInvalidValues() {
        let invalid = ScrollConfiguration(isEnabled: true, reverseHorizontal: true, verticalMultiplier: .infinity,
                                          horizontalMultiplier: 99, smoothingDuration: .nan)
        XCTAssertEqual(invalid.transform(vertical: 3, horizontal: 2).vertical, 3)
        XCTAssertEqual(invalid.transform(vertical: 3, horizontal: 2).horizontal, -20)
        XCTAssertEqual(invalid.effectiveSmoothingDuration, 0.12)
        XCTAssertEqual(ScrollConfiguration(smoothingDuration: 99).effectiveSmoothingDuration, 0.5)
    }
}
