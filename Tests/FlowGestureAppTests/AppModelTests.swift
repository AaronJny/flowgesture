import XCTest
import Foundation
import FlowGestureCore
@testable import FlowGestureApp

final class AppModelTests: XCTestCase {
    @MainActor private func isolated(_ operation: (URL) throws -> Void) throws {
        let defaults = UserDefaults.standard
        let keys = ["FlowGesture.enabled", "FlowGesture.needsRuleReview", "FlowGesture.syncFolderBookmark"]
        let previous = keys.map { ($0, defaults.object(forKey: $0)) }
        keys.forEach { defaults.removeObject(forKey: $0) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            for (key, value) in previous { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } }
            try? FileManager.default.removeItem(at: directory)
        }
        try operation(directory)
    }

    @MainActor func testPendingImportedRuleReviewRemainsPausedAcrossLaunch() async throws {
        try isolated { directory in
            UserDefaults.standard.set(true, forKey: "FlowGesture.enabled")
            UserDefaults.standard.set(true, forKey: "FlowGesture.needsRuleReview")
            let model = AppModel(directory: directory)
            XCTAssertTrue(model.needsRuleReview)
            XCTAssertFalse(model.isEnabled)
            var enabled: Bool?
            model.onEnabledChanged = { enabled = $0 }
            model.publishConfiguration()
            XCTAssertEqual(enabled, false)
        }
    }

    @MainActor func testCorruptConfigurationIsPreservedAndPaused() async throws {
        try isolated { directory in
            let url = directory.appendingPathComponent("rules.json")
            let corrupt = Data("not JSON".utf8)
            try corrupt.write(to: url)
            let model = AppModel(directory: directory)
            XCTAssertNotNil(model.configurationLoadError)
            XCTAssertFalse(model.isEnabled)
            XCTAssertEqual(try Data(contentsOf: url), corrupt)
        }
    }

    @MainActor func testAuthoringRulePersistsValidatedSchemaAndBackup() async throws {
        try isolated { directory in
            let model = AppModel(directory: directory)
            let rule = Rule(name: "Copy", trigger: .keyboard(KeyboardShortcut(keyCode: 8, modifiers: .command)), actions: [.shortcut(KeyboardShortcut(keyCode: 8, modifiers: .command))])
            XCTAssertTrue(model.saveRule(rule))
            let saved = try JSONDecoder().decode(RuleBook.self, from: BoundedFileReader.read(at: model.configurationURL))
            XCTAssertEqual(saved.rules, [rule])
            XCTAssertEqual(saved.schemaVersion, 2)
            XCTAssertFalse(model.needsRuleReview)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("rules.backup.json").path))
        }
    }
    @MainActor func testScrollTogglePublishesAndPersistsWholeConfiguration() async throws {
        try isolated { directory in
            let model = AppModel(directory: directory)
            var values: [Bool] = []
            model.onConfigurationChanged = { values.append($0.scroll.reverseVertical) }
            model.book.scroll.reverseVertical = true
            model.book.scroll.reverseVertical = false
            XCTAssertEqual(values, [true, false])
            let saved = try JSONDecoder().decode(RuleBook.self, from: BoundedFileReader.read(at: model.configurationURL))
            XCTAssertFalse(saved.scroll.reverseVertical)
        }
    }

}
