import Foundation
import XCTest
@testable import FlowGestureCore

final class TouchDeviceScopeTests: XCTestCase {
    private let gesture = TouchGesture.tap(fingers: 2)
    private let modifiers: ModifierKeys = .option

    private func trigger(_ device: TouchDeviceScope) -> InputTrigger {
        .touch(TouchGestureTrigger(gesture: gesture, modifiers: modifiers, device: device))
    }
    private func rule(_ device: TouchDeviceScope, priority: Int = 0,
                      scope: AppScope = .allApplications) -> Rule {
        Rule(name: device.rawValue, trigger: trigger(device), scope: scope,
             actions: [.shortcut(KeyboardShortcut(keyCode: 8, modifiers: .command))], priority: priority)
    }
    private func encodedObject(_ device: TouchDeviceScope) throws -> [String: Any] {
        let value = TouchGestureTrigger(gesture: gesture, modifiers: modifiers, device: device)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
    private func decode(_ object: [String: Any]) throws -> TouchGestureTrigger {
        try JSONDecoder().decode(TouchGestureTrigger.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testAnyIsTheSourceCompatibleDefault() {
        XCTAssertEqual(TouchGestureTrigger().device, .any)
        XCTAssertEqual(TouchGestureTrigger(gesture: .pinch(.inward), modifiers: .shift).device, .any)
    }

    func testAllDeviceScopesRoundTripThroughJSON() throws {
        for device in TouchDeviceScope.allCases {
            let original = TouchGestureTrigger(gesture: gesture, modifiers: modifiers, device: device)
            let restored = try JSONDecoder().decode(TouchGestureTrigger.self, from: JSONEncoder().encode(original))
            XCTAssertEqual(restored, original)
        }
    }

    func testLegacyJSONWithoutDeviceDecodesAsAny() throws {
        var object = try encodedObject(.trackpad)
        object.removeValue(forKey: "device")
        let restored = try decode(object)
        XCTAssertEqual(restored.device, .any)
        XCTAssertEqual(restored.gesture, gesture)
        XCTAssertEqual(restored.modifiers, modifiers)
    }

    func testLegacyRuleBookImportsWithDeviceAndVersionMigration() throws {
        let original = RuleBook(rules: [rule(.trackpad)])
        func removeDeviceKeys(_ object: Any) -> Any {
            if var dictionary = object as? [String: Any] {
                dictionary.removeValue(forKey: "device")
                return dictionary.mapValues(removeDeviceKeys)
            }
            if let array = object as? [Any] { return array.map(removeDeviceKeys) }
            return object
        }
        let encoded = try JSONEncoder().encode(original)
        var legacy = try XCTUnwrap(removeDeviceKeys(try JSONSerialization.jsonObject(with: encoded)) as? [String: Any])
        legacy["schemaVersion"] = 1
        let restored = try JSONDecoder().decode(RuleBook.self, from: JSONSerialization.data(withJSONObject: legacy))
        var expected = original
        expected.rules[0].trigger = trigger(.any)
        XCTAssertEqual(restored, expected)
        XCTAssertTrue(restored.validationIssues().isEmpty)
    }

    func testNullDeviceDefaultsToAnyButInvalidExplicitDeviceIsRejected() throws {
        var object = try encodedObject(.trackpad)
        object["device"] = NSNull()
        XCTAssertEqual(try decode(object).device, .any)
        object["device"] = "keyboard"
        XCTAssertThrowsError(try decode(object))
        object["device"] = 1
        XCTAssertThrowsError(try decode(object))
    }

    func testAnyRuleMatchesEachObservedDevice() {
        let any = rule(.any)
        for device in TouchDeviceScope.allCases {
            XCTAssertEqual(RuleMatcher.bestMatch(for: trigger(device), in: nil, rules: [any])?.id, any.id)
        }
    }

    func testTrackpadAndMouseRulesAreIndependent() {
        let trackpad = rule(.trackpad)
        let mouse = rule(.mouse)
        let rules = [trackpad, mouse]
        XCTAssertEqual(RuleMatcher.matchingRules(for: trigger(.trackpad), in: nil, rules: rules).map(\.id), [trackpad.id])
        XCTAssertEqual(RuleMatcher.matchingRules(for: trigger(.mouse), in: nil, rules: rules).map(\.id), [mouse.id])
    }

    func testUnknownObservedDeviceDoesNotMatchTargetedRules() {
        XCTAssertTrue(RuleMatcher.matchingRules(for: trigger(.any), in: nil,
                                               rules: [rule(.trackpad), rule(.mouse)]).isEmpty)
    }

    func testDeviceWildcardDoesNotRelaxGestureOrModifierMatching() {
        let any = rule(.any)
        let wrongModifiers = InputTrigger.touch(TouchGestureTrigger(gesture: gesture, modifiers: [], device: .trackpad))
        let wrongGesture = InputTrigger.touch(TouchGestureTrigger(gesture: .tap(fingers: 3), modifiers: modifiers, device: .trackpad))
        let wrongKind = InputTrigger.mouseButton(MouseButtonTrigger(button: .middle, modifiers: modifiers))
        for observed in [wrongModifiers, wrongGesture, wrongKind] {
            XCTAssertNil(RuleMatcher.bestMatch(for: observed, in: nil, rules: [any]))
        }
    }

    func testDeviceMatchingPreservesApplicationPriorityAndSavedOrder() {
        let firstAny = rule(.any, priority: 10)
        let specific = rule(.trackpad, priority: 10)
        let high = rule(.trackpad, priority: 20)
        let app = rule(.any, scope: AppScope(bundleIdentifiers: ["com.example.editor"]))
        let rules = [firstAny, specific, high, app]
        XCTAssertEqual(RuleMatcher.matchingRules(for: trigger(.trackpad), in: "com.example.editor", rules: rules).map(\.id),
                       [app.id, high.id, firstAny.id, specific.id])
        XCTAssertNil(RuleMatcher.bestMatch(for: trigger(.trackpad), in: "com.example.editor", rules: rules,
                                          excludedBundleIdentifiers: ["com.example.editor"]))
    }
}
