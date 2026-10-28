import Foundation
import XCTest
@testable import FlowGestureCore

final class RuleBookSchemaTests: XCTestCase {
    private func object(_ book: RuleBook = RuleBook()) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(book)) as? [String: Any])
    }
    private func decode(_ object: [String: Any]) throws -> RuleBook {
        try JSONDecoder().decode(RuleBook.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testVersionOneMigratesToCurrentVersionTwoInMemory() throws {
        var legacy = try object()
        legacy["schemaVersion"] = 1
        let restored = try decode(legacy)
        XCTAssertEqual(RuleBook.currentSchemaVersion, 2)
        XCTAssertEqual(restored.schemaVersion, 2)
        XCTAssertTrue(restored.validationIssues().isEmpty)
    }

    func testVersionTwoRoundTripPreservesDeviceScopeAndOtherFields() throws {
        let rule = Rule(name: "Trackpad only", trigger: .touch(TouchGestureTrigger(device: .trackpad)),
                        actions: [.shortcut(KeyboardShortcut(keyCode: 8, modifiers: .command))])
        let original = RuleBook(rules: [rule], excludedBundleIdentifiers: ["com.example.game"])
        let restored = try decode(object(original))
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.schemaVersion, 2)
    }

    func testEncodingAlwaysAdvertisesCurrentVersionTwo() throws {
        let legacyInMemory = RuleBook(schemaVersion: 1)
        XCTAssertEqual(try object(legacyInMemory)["schemaVersion"] as? Int, 2)
        XCTAssertEqual(try object()["schemaVersion"] as? Int, 2)
        var legacy = try object()
        legacy["schemaVersion"] = 1
        let migrated = try decode(legacy)
        XCTAssertEqual(try object(migrated)["schemaVersion"] as? Int, 2)
    }

    func testFutureVersionIsRetainedAndRejectedByValidation() throws {
        var future = try object()
        future["schemaVersion"] = 99
        let restored = try decode(future)
        XCTAssertEqual(restored.schemaVersion, 99)
        XCTAssertTrue(restored.validationIssues().contains { $0.path == "schemaVersion" })
    }

    func testUnknownOlderVersionIsNotSilentlyMigrated() throws {
        var unknown = try object()
        unknown["schemaVersion"] = 0
        let restored = try decode(unknown)
        XCTAssertEqual(restored.schemaVersion, 0)
        XCTAssertTrue(restored.validationIssues().contains { $0.path == "schemaVersion" })
    }

    func testVersionMigrationDoesNotMakeInvalidRulesValid() throws {
        let invalid = RuleBook(rules: [Rule(name: "", actions: [])])
        var legacy = try object(invalid)
        legacy["schemaVersion"] = 1
        let restored = try decode(legacy)
        XCTAssertEqual(restored.schemaVersion, 2)
        let issues = restored.validationIssues()
        XCTAssertTrue(issues.contains { $0.path == "rules[0].name" })
        XCTAssertTrue(issues.contains { $0.path == "rules[0].actions" })
    }

    func testMalformedLegacyEnvelopeStillFailsDecoding() throws {
        var malformed = try object()
        malformed["schemaVersion"] = 1
        malformed.removeValue(forKey: "rules")
        XCTAssertThrowsError(try decode(malformed))
        malformed = try object()
        malformed.removeValue(forKey: "schemaVersion")
        XCTAssertThrowsError(try decode(malformed))
        malformed["schemaVersion"] = "1"
        XCTAssertThrowsError(try decode(malformed))
    }
}
