import AppKit
import Combine
import Foundation
import FlowGestureCore
import UniformTypeIdentifiers

/// Owns the persisted configuration; native input handling is attached through the callbacks.
@MainActor
final class AppModel: ObservableObject {
    @Published var book: RuleBook {
        didSet {
            guard !suppressPersistence else { return }
            guard configurationLoadError == nil else {
                suppressPersistence = true; book = oldValue; suppressPersistence = false
                return
            }
            do {
                try persist(book)
                onConfigurationChanged?(book)
                synchronize()
            } catch {
                suppressPersistence = true; book = oldValue; suppressPersistence = false
                errorMessage = error.localizedDescription
            }
        }
    }
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "FlowGesture.enabled")
            onEnabledChanged?(isEnabled && configurationLoadError == nil)
        }
    }
    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "FlowGesture.language") }
    }
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published private(set) var configurationLoadError: String?
    @Published private(set) var syncFolder: URL?
    @Published private(set) var syncStatus = "Not connected"
    @Published private(set) var hasSyncConflict = false
    @Published var accessibilityGranted = false
    @Published var inputMonitoringGranted = false
    @Published var engineStatus = "Not running"
    @Published var lastEvent = "No event yet"
    @Published var touchBackendStatus = "Not available"

    var onConfigurationChanged: ((RuleBook) -> Void)?
    var onEnabledChanged: ((Bool) -> Void)?
    var onInputCaptureChanged: ((Bool) -> Void)?
    var onRequestPermissions: (() -> Void)?
    var onRefreshDiagnostics: (() -> Void)?

    let configurationURL: URL
    private let backupURL: URL
    private let baselineURL: URL
    private var suppressPersistence = true
    private var isSynchronizing = false
    private var lastSyncedBook: RuleBook?
    private var securityScopedFolder: URL?
    private var syncTimer: Timer?

    init(directory: URL? = nil) {
        let support = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlowGesture", isDirectory: true)
        configurationURL = support.appendingPathComponent("rules.json")
        backupURL = support.appendingPathComponent("rules.backup.json")
        baselineURL = support.appendingPathComponent("sync-baseline.json")
        language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "FlowGesture.language") ?? "system") ?? .system
        isEnabled = UserDefaults.standard.object(forKey: "FlowGesture.enabled") as? Bool ?? true
        book = RuleBook()
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: configurationURL.path) {
                book = try Self.readBook(at: configurationURL)
            } else {
                try Self.encoded(book).write(to: configurationURL, options: .atomic)
            }
        } catch {
            configurationLoadError = error.localizedDescription
            isEnabled = false
        }
        suppressPersistence = false
        restoreSyncFolder()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.synchronize() }
        }
    }

    func t(_ key: String) -> String { L10n.text(key, language: language) }

    /// Invoke after assigning the native engine callbacks to apply the loaded state.
    func publishConfiguration() {
        onConfigurationChanged?(book)
        onEnabledChanged?(isEnabled && configurationLoadError == nil)
        onRefreshDiagnostics?()
    }

    func saveRule(_ rule: Rule) {
        var next = book
        if let index = next.rules.firstIndex(where: { $0.id == rule.id }) { next.rules[index] = rule }
        else { next.rules.append(rule) }
        book = next
    }

    func deleteRule(id: UUID) { book.rules.removeAll { $0.id == id } }
    func duplicateRule(_ rule: Rule) {
        var copy = rule
        copy.id = UUID()
        copy.name += language == .simplifiedChinese ? " 副本" : " copy"
        book.rules.append(copy)
    }
    func setRuleEnabled(id: UUID, enabled: Bool) {
        guard let index = book.rules.firstIndex(where: { $0.id == id }) else { return }
        book.rules[index].isEnabled = enabled
    }

    func showConfigurationFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([configurationURL])
    }

    func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let next = try Self.readBook(at: url)
            guard confirm(title: "Replace configuration?", message: "Importing replaces all rules and scroll settings. Review scripts and URLs before enabling imported rules.", primary: "Import paused") else { return }
            try replaceConfiguration(next, pause: true)
            notice = t("Imported rules are paused. Review them, then enable FlowGesture.")
        } catch { errorMessage = error.localizedDescription }
    }

    func exportConfiguration() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "FlowGesture-rules.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Self.encoded(book).write(to: url, options: .atomic)
            notice = t("Configuration exported")
        } catch { errorMessage = error.localizedDescription }
    }

    func restoreBackup() {
        do {
            let backup = try Self.readBook(at: backupURL)
            guard confirm(title: "Restore previous backup?", message: "Your current configuration will be archived before restoring the backup.", primary: "Restore") else { return }
            try replaceConfiguration(backup, pause: true)
            notice = t("Backup restored")
        } catch { errorMessage = error.localizedDescription }
    }

    func chooseSyncFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let accessed = folder.startAccessingSecurityScopedResource()
        do {
            let file = folder.appendingPathComponent("FlowGesture-rules.json")
            var selectedBook = book
            var useShared = false
            if FileManager.default.fileExists(atPath: file.path) {
                let shared = try Self.readBook(at: file)
                if shared != book {
                    let alert = NSAlert()
                    alert.messageText = t("Sync file already exists")
                    alert.informativeText = t("Use the shared file, or replace it with this Mac’s configuration?")
                    alert.addButton(withTitle: t("Use shared version"))
                    alert.addButton(withTitle: t("Publish local version"))
                    alert.addButton(withTitle: t("Cancel"))
                    switch alert.runModal() {
                    case .alertFirstButtonReturn: selectedBook = shared; useShared = true
                    case .alertSecondButtonReturn: break
                    default:
                        if accessed { folder.stopAccessingSecurityScopedResource() }
                        return
                    }
                }
            }
            let bookmark = try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            disconnectSync()
            securityScopedFolder = accessed ? folder : nil
            syncFolder = folder
            UserDefaults.standard.set(bookmark, forKey: "FlowGesture.syncFolderBookmark")
            isSynchronizing = true
            defer { isSynchronizing = false }
            if useShared { try replaceConfiguration(selectedBook, pause: true) }
            try writeShared(book)
            try recordBaseline(book)
            syncStatus = "Synchronized"
        } catch {
            if syncFolder != folder && accessed { folder.stopAccessingSecurityScopedResource() }
            errorMessage = error.localizedDescription
            syncStatus = error.localizedDescription
        }
    }

    func disconnectSync() {
        securityScopedFolder?.stopAccessingSecurityScopedResource()
        securityScopedFolder = nil
        syncFolder = nil
        lastSyncedBook = nil
        hasSyncConflict = false
        syncStatus = "Not connected"
        UserDefaults.standard.removeObject(forKey: "FlowGesture.syncFolderBookmark")
        try? FileManager.default.removeItem(at: baselineURL)
    }

    func synchronize() {
        guard !isSynchronizing, !hasSyncConflict, configurationLoadError == nil, let folder = syncFolder else { return }
        isSynchronizing = true
        defer { isSynchronizing = false }
        let sharedURL = folder.appendingPathComponent("FlowGesture-rules.json")
        do {
            guard FileManager.default.fileExists(atPath: sharedURL.path) else {
                // A previously synchronized file disappearing is not permission to recreate it.
                if lastSyncedBook != nil { syncStatus = "Shared sync file is unavailable; reconnect the folder to publish again."; return }
                try writeShared(book)
                try recordBaseline(book)
                syncStatus = "Synchronized"
                return
            }
            let shared = try readShared(at: sharedURL)
            if shared == book {
                try recordBaseline(book)
            } else if let baseline = lastSyncedBook, shared == baseline {
                try writeShared(book)
                try recordBaseline(book)
            } else if let baseline = lastSyncedBook, book == baseline {
                // Incoming configuration may contain executable actions. Do not auto-enable it.
                try replaceConfiguration(shared, pause: true)
                try recordBaseline(shared)
                notice = t("Imported rules are paused. Review them, then enable FlowGesture.")
            } else {
                hasSyncConflict = true
                syncStatus = "Local and shared files both changed. Choose which version to keep."
                return
            }
            syncStatus = "Synchronized"
        } catch { syncStatus = error.localizedDescription }
    }

    func resolveSyncConflict(useShared: Bool) {
        guard let folder = syncFolder else { return }
        isSynchronizing = true
        defer { isSynchronizing = false }
        do {
            if useShared {
                let shared = try readShared(at: folder.appendingPathComponent("FlowGesture-rules.json"))
                try replaceConfiguration(shared, pause: true)
            } else { try writeShared(book) }
            try recordBaseline(book)
            hasSyncConflict = false
            syncStatus = "Synchronized"
        } catch { errorMessage = error.localizedDescription }
    }

    func openPrivacySettings(accessibility: Bool) {
        let pane = accessibility ? "Privacy_Accessibility" : "Privacy_ListenEvent"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }

    func chooseApplication() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier ?? url.path
    }

    func triggerTitle(_ trigger: InputTrigger) -> String {
        switch trigger {
        case .mouseButton(let value): return "\(L10n.modifiers(value.modifiers))\(t(L10n.mouse(value.button))) ×\(value.clickCount)"
        case .draw(let value): return "\(L10n.modifiers(value.modifiers))\(t(L10n.mouse(value.button))) \(value.directions.map(L10n.arrow).joined(separator: " "))"
        case .keyboard(let value): return "\(L10n.modifiers(value.modifiers))#\(value.keyCode)"
        case .touch: return t("Touch gesture")
        case .screenCorner(let value): return "\(L10n.modifiers(value.modifiers))\(t(L10n.corner(value.corner)))"
        }
    }
    func actionTitle(_ action: Action) -> String {
        switch action {
        case .shortcut: return t("Keyboard shortcut")
        case .openURL(let value): return value
        case .openApplication(let value): return value
        case .openPath(let value): return value
        case .appleScript: return "AppleScript"
        case .menuItem(let path): return path.joined(separator: " › ")
        case .window(let value): return t(L10n.window(value))
        case .windowFrame: return t("Custom window frame")
        case .system(let value): return t(L10n.system(value))
        }
    }

    private func persist(_ value: RuleBook) throws {
        try Self.validate(value)
        let data = try Self.encoded(value)
        if FileManager.default.fileExists(atPath: configurationURL.path) {
            let previous = try Data(contentsOf: configurationURL)
            try previous.write(to: backupURL, options: .atomic)
        }
        try data.write(to: configurationURL, options: .atomic)
    }

    private func replaceConfiguration(_ value: RuleBook, pause: Bool) throws {
        try Self.validate(value)
        if FileManager.default.fileExists(atPath: configurationURL.path) {
            let archive = configurationURL.deletingLastPathComponent().appendingPathComponent("rules.archive.\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: configurationURL, to: archive)
        }
        // Stop native execution before swapping in potentially executable imported actions.
        if pause { isEnabled = false }
        try persist(value)
        suppressPersistence = true
        book = value
        configurationLoadError = nil
        suppressPersistence = false
        onConfigurationChanged?(book)
        onEnabledChanged?(isEnabled)
        synchronize()
    }

    private func restoreSyncFolder() {
        guard let bookmark = UserDefaults.standard.data(forKey: "FlowGesture.syncFolderBookmark") else { return }
        do {
            var stale = false
            let folder = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            if stale { throw ConfigurationError("The sync folder bookmark has expired. Choose the folder again.") }
            if folder.startAccessingSecurityScopedResource() { securityScopedFolder = folder }
            syncFolder = folder
            if FileManager.default.fileExists(atPath: baselineURL.path) { lastSyncedBook = try Self.readBook(at: baselineURL) }
            syncStatus = "Waiting for changes"
        } catch { syncStatus = error.localizedDescription }
    }

    private func readShared(at url: URL) throws -> RuleBook {
        var coordinationError: NSError?
        var result: Result<RuleBook, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try Self.readBook(at: coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ConfigurationError("The shared configuration could not be read.") }
        return try result.get()
    }

    private func writeShared(_ value: RuleBook) throws {
        guard let folder = syncFolder else { return }
        let data = try Self.encoded(value)
        let url = folder.appendingPathComponent("FlowGesture-rules.json")
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do { try data.write(to: coordinatedURL, options: .atomic) }
            catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    private func recordBaseline(_ value: RuleBook) throws {
        if lastSyncedBook != value { try Self.encoded(value).write(to: baselineURL, options: .atomic) }
        lastSyncedBook = value
    }

    private func confirm(title: String, message: String, primary: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = t(title)
        alert.informativeText = t(message)
        alert.addButton(withTitle: t(primary))
        alert.addButton(withTitle: t("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func encoded(_ value: RuleBook) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func readBook(at url: URL) throws -> RuleBook {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 8 * 1024 * 1024 else { throw ConfigurationError("Configuration exceeds the 8 MB size limit.") }
        let value = try JSONDecoder().decode(RuleBook.self, from: Data(contentsOf: url))
        try validate(value)
        return value
    }
    private static func validate(_ value: RuleBook) throws {
        let issues = value.validationIssues()
        guard issues.isEmpty else {
            throw ConfigurationError(issues.map { "\($0.path): \($0.message)" }.joined(separator: "\n"))
        }
    }
}

private struct ConfigurationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
