import Foundation

public enum RuleMatcher {
    /// Most-specific application rules win; explicit priority then saved order break ties.
    /// The caller normally executes only `bestMatch`, not every matching rule.
    public static func matchingRules(for trigger: InputTrigger, in bundleIdentifier: String?,
                                     rules: [Rule], excludedBundleIdentifiers: Set<String> = []) -> [Rule] {
        if let bundleIdentifier, excludedBundleIdentifiers.contains(bundleIdentifier) { return [] }
        // An unidentified foreground app cannot be proved safe against global exclusions.
        if bundleIdentifier == nil && !excludedBundleIdentifiers.isEmpty { return [] }
        return rules.enumerated()
            .filter { $0.element.isEnabled && $0.element.trigger == trigger && $0.element.scope.includes(bundleIdentifier) }
            .sorted { lhs, rhs in
                if lhs.element.scope.isGlobal != rhs.element.scope.isGlobal { return !lhs.element.scope.isGlobal }
                if lhs.element.priority != rhs.element.priority { return lhs.element.priority > rhs.element.priority }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    public static func bestMatch(for trigger: InputTrigger, in bundleIdentifier: String?, rules: [Rule],
                                 excludedBundleIdentifiers: Set<String> = []) -> Rule? {
        matchingRules(for: trigger, in: bundleIdentifier, rules: rules,
                      excludedBundleIdentifiers: excludedBundleIdentifiers).first
    }

    public static func bestMatch(for trigger: InputTrigger, in bundleIdentifier: String?, ruleBook: RuleBook) -> Rule? {
        bestMatch(for: trigger, in: bundleIdentifier, rules: ruleBook.rules,
                  excludedBundleIdentifiers: ruleBook.excludedBundleIdentifiers)
    }
}

public struct RuleValidationIssue: Hashable, Sendable {
    public var path: String
    public var message: String
    public init(path: String, message: String) { self.path = path; self.message = message }
}

public extension RuleBook {
    /// Validate before accepting imported settings. No scripts or actions are executed here.
    func validationIssues() -> [RuleValidationIssue] {
        var issues: [RuleValidationIssue] = []
        func add(_ path: String, _ message: String) { issues.append(RuleValidationIssue(path: path, message: message)) }
        if schemaVersion != Self.currentSchemaVersion { add("schemaVersion", "Unsupported settings version \(schemaVersion).") }
        if rules.count > 1_000 { add("rules", "At most 1,000 rules are supported.") }
        if !scroll.verticalMultiplier.isFinite || !(0.1...10).contains(scroll.verticalMultiplier) {
            add("scroll.verticalMultiplier", "Scroll speed must be between 0.1 and 10.")
        }
        if !scroll.horizontalMultiplier.isFinite || !(0.1...10).contains(scroll.horizontalMultiplier) {
            add("scroll.horizontalMultiplier", "Scroll speed must be between 0.1 and 10.")
        }
        if !scroll.smoothingDuration.isFinite || !(0.03...0.5).contains(scroll.smoothingDuration) {
            add("scroll.smoothingDuration", "Smoothing duration must be between 0.03 and 0.5 seconds.")
        }
        var ids: Set<UUID> = []
        for (index, rule) in rules.enumerated() {
            let prefix = "rules[\(index)]"
            if !ids.insert(rule.id).inserted { add(prefix + ".id", "Rule identifiers must be unique.") }
            if rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add(prefix + ".name", "A rule needs a name.") }
            if rule.actions.isEmpty { add(prefix + ".actions", "A rule needs at least one action.") }
            if rule.actions.count > 32 { add(prefix + ".actions", "At most 32 actions are supported per rule.") }
            var modifiers: ModifierKeys = []
            switch rule.trigger {
            case .mouseButton(let trigger):
                modifiers = trigger.modifiers
                if !(1...3).contains(trigger.clickCount) { add(prefix + ".trigger", "Click count must be 1, 2, or 3.") }
            case .draw(let trigger):
                modifiers = trigger.modifiers
                if trigger.directions.isEmpty || trigger.directions.count > 12 { add(prefix + ".trigger", "A drawing needs between 1 and 12 directions.") }
                if zip(trigger.directions, trigger.directions.dropFirst()).contains(where: { $0.0 == $0.1 }) {
                    add(prefix + ".trigger", "Consecutive drawing directions must differ.")
                }
            case .keyboard(let trigger): modifiers = trigger.modifiers
            case .touch(let trigger):
                modifiers = trigger.modifiers
                switch trigger.gesture {
                case .tap(let fingers), .swipe(let fingers, _):
                    if !(1...5).contains(fingers) { add(prefix + ".trigger", "Touch gestures support 1 to 5 fingers.") }
                case .pinch: break
                }
            case .screenCorner(let trigger): modifiers = trigger.modifiers
            }
            if !modifiers.subtracting(.supported).isEmpty { add(prefix + ".trigger.modifiers", "Unsupported modifier flags.") }
            for (actionIndex, action) in rule.actions.enumerated() {
                let path = prefix + ".actions[\(actionIndex)]"
                switch action {
                case .openURL(let value):
                    if URL(string: value)?.scheme == nil { add(path, "An open action needs an absolute URL with a scheme.") }
                case .openApplication(let value):
                    if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add(path, "Choose an application bundle identifier or path.") }
                case .openPath(let value):
                    if !value.hasPrefix("/") && !value.hasPrefix("~/") { add(path, "Choose an absolute file or folder path.") }
                case .appleScript(let value):
                    if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add(path, "AppleScript cannot be empty.") }
                case .menuItem(let pathComponents):
                    if pathComponents.isEmpty || pathComponents.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                        add(path, "Choose a nonempty menu path.")
                    }
                case .shortcut(let shortcut):
                    if !shortcut.modifiers.subtracting(.supported).isEmpty { add(path, "Unsupported shortcut modifier flags.") }
                case .windowFrame(let x, let y, let width, let height):
                    if ![x, y, width, height].allSatisfy(\.isFinite) || x < 0 || y < 0 || width <= 0 || height <= 0 || x + width > 1 || y + height > 1 {
                        add(path, "Custom window bounds must fit inside the normalized screen (0 to 1).")
                    }
                case .window, .system: break
                }
            }
        }
        return issues
    }
}
