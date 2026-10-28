import Foundation

/// Platform-independent modifiers. Adapters must discard unrelated event flags.
public struct ModifierKeys: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let command = ModifierKeys(rawValue: 1 << 0)
    public static let option = ModifierKeys(rawValue: 1 << 1)
    public static let control = ModifierKeys(rawValue: 1 << 2)
    public static let shift = ModifierKeys(rawValue: 1 << 3)
    public static let function = ModifierKeys(rawValue: 1 << 4)
    public static let supported: ModifierKeys = [.command, .option, .control, .shift, .function]
}

public enum MouseButton: Int, Codable, Hashable, CaseIterable, Sendable {
    case left = 0, right = 1, middle = 2, back = 3, forward = 4
    case button6 = 5, button7 = 6, button8 = 7
}

public struct MouseButtonTrigger: Codable, Hashable, Sendable {
    public var button: MouseButton
    public var clickCount: Int
    public var modifiers: ModifierKeys
    public init(button: MouseButton = .middle, clickCount: Int = 1, modifiers: ModifierKeys = []) {
        self.button = button
        self.clickCount = clickCount
        self.modifiers = modifiers
    }
}

/// Coordinates in this module use positive Y = up (including normalized touch coordinates).
public enum GestureDirection: String, Codable, Hashable, CaseIterable, Sendable {
    case right, upRight, up, upLeft, left, downLeft, down, downRight
}

public struct DrawGestureTrigger: Codable, Hashable, Sendable {
    public var button: MouseButton
    public var directions: [GestureDirection]
    public var modifiers: ModifierKeys
    public init(button: MouseButton = .right, directions: [GestureDirection] = [.left], modifiers: ModifierKeys = []) {
        self.button = button
        self.directions = directions
        self.modifiers = modifiers
    }
}

/// Recorded single-stroke template. Points use positive Y up, like other core gestures.
/// `tolerance` is a normalized mean-distance tolerance; 0.15 means 85% similarity.
public struct ShapeGestureTrigger: Codable, Hashable, Sendable {
    public var button: MouseButton
    public var points: [GesturePoint]
    public var modifiers: ModifierKeys
    public var tolerance: Double
    public init(button: MouseButton = .right, points: [GesturePoint] = [],
                modifiers: ModifierKeys = [], tolerance: Double = 0.15) {
        self.button = button
        self.points = points
        self.modifiers = modifiers
        self.tolerance = tolerance
    }
}

/// Uses macOS virtual key codes; a UI can retain a display label separately.
public struct KeyboardShortcut: Codable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: ModifierKeys
    public init(keyCode: UInt16 = 0, modifiers: ModifierKeys = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public enum PinchDirection: String, Codable, Hashable, CaseIterable, Sendable { case inward, outward }

public enum TouchGesture: Codable, Hashable, Sendable {
    case tap(fingers: Int)
    case swipe(fingers: Int, direction: GestureDirection)
    case pinch(PinchDirection)
}

public struct TouchGestureTrigger: Codable, Hashable, Sendable {
    public var gesture: TouchGesture
    public var modifiers: ModifierKeys
    public var device: TouchDeviceScope
    public init(gesture: TouchGesture = .tap(fingers: 3), modifiers: ModifierKeys = [],
                device: TouchDeviceScope = .any) {
        self.gesture = gesture
        self.modifiers = modifiers
        self.device = device
    }

    private enum CodingKeys: String, CodingKey { case gesture, modifiers, device }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        gesture = try values.decode(TouchGesture.self, forKey: .gesture)
        modifiers = try values.decode(ModifierKeys.self, forKey: .modifiers)
        // Settings created before device-scoped touch rules apply to any device.
        // Invalid explicit values still fail decoding instead of widening scope.
        device = try values.decodeIfPresent(TouchDeviceScope.self, forKey: .device) ?? .any
    }
}

public enum ScreenCorner: String, Codable, Hashable, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight
}

public struct ScreenCornerTrigger: Codable, Hashable, Sendable {
    public var corner: ScreenCorner
    public var modifiers: ModifierKeys
    public init(corner: ScreenCorner = .topLeft, modifiers: ModifierKeys = []) {
        self.corner = corner
        self.modifiers = modifiers
    }
}

public enum InputTrigger: Codable, Hashable, Sendable {
    case mouseButton(MouseButtonTrigger)
    case draw(DrawGestureTrigger)
    case shape(ShapeGestureTrigger)
    case keyboard(KeyboardShortcut)
    case touch(TouchGestureTrigger)
    case screenCorner(ScreenCornerTrigger)
}

/// Empty inclusion set means all apps. Exclusions always win over inclusions.
public struct AppScope: Codable, Hashable, Sendable {
    public var bundleIdentifiers: Set<String>
    public var excludedBundleIdentifiers: Set<String>
    public init(bundleIdentifiers: Set<String> = [], excludedBundleIdentifiers: Set<String> = []) {
        self.bundleIdentifiers = bundleIdentifiers
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
    }
    public static let allApplications = AppScope()
    public var isGlobal: Bool { bundleIdentifiers.isEmpty }
    public func includes(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return isGlobal && excludedBundleIdentifiers.isEmpty }
        return !excludedBundleIdentifiers.contains(bundleIdentifier)
            && (isGlobal || bundleIdentifiers.contains(bundleIdentifier))
    }
}

public enum WindowAction: String, Codable, Hashable, CaseIterable, Sendable {
    case maximize, center, leftHalf, rightHalf, topHalf, bottomHalf, minimize, close
}

public enum SystemAction: String, Codable, Hashable, CaseIterable, Sendable {
    case missionControl, showDesktop, applicationWindows, launchpad
    case volumeUp, volumeDown, mute, brightnessUp, brightnessDown, playPause, nextTrack, previousTrack, lockScreen
}

/// Executing scripts/opening resources belongs to the permission-aware platform adapter.
public enum Action: Codable, Hashable, Sendable {
    case shortcut(KeyboardShortcut)
    case openURL(String)
    case openApplication(String)
    case openPath(String)
    case appleScript(String)
    case menuItem([String])
    case window(WindowAction)
    /// Normalized visible-screen coordinates, with positive Y up.
    case windowFrame(x: Double, y: Double, width: Double, height: Double)
    case system(SystemAction)
}

public struct Rule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var trigger: InputTrigger
    public var scope: AppScope
    public var actions: [Action]
    public var priority: Int
    public init(id: UUID = UUID(), name: String = "New rule", isEnabled: Bool = true,
                trigger: InputTrigger = .mouseButton(MouseButtonTrigger()), scope: AppScope = .allApplications,
                actions: [Action] = [], priority: Int = 0) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.trigger = trigger
        self.scope = scope
        self.actions = actions
        self.priority = priority
    }
}

public struct ScrollConfiguration: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var reverseVertical: Bool
    public var reverseHorizontal: Bool
    public var verticalMultiplier: Double
    public var horizontalMultiplier: Double
    /// Leave trackpads alone by default; only transform discrete mouse wheels.
    public var affectsContinuousScrolling: Bool
    public var smooth: Bool
    public var smoothingDuration: Double
    public init(isEnabled: Bool = false, reverseVertical: Bool = false, reverseHorizontal: Bool = false,
                verticalMultiplier: Double = 1, horizontalMultiplier: Double = 1,
                affectsContinuousScrolling: Bool = false, smooth: Bool = true, smoothingDuration: Double = 0.12) {
        self.isEnabled = isEnabled
        self.reverseVertical = reverseVertical
        self.reverseHorizontal = reverseHorizontal
        self.verticalMultiplier = verticalMultiplier
        self.horizontalMultiplier = horizontalMultiplier
        self.affectsContinuousScrolling = affectsContinuousScrolling
        self.smooth = smooth
        self.smoothingDuration = smoothingDuration
    }
    public func transform(vertical: Double, horizontal: Double, isContinuous: Bool = false) -> (vertical: Double, horizontal: Double) {
        guard isEnabled, !isContinuous || affectsContinuousScrolling else { return (vertical, horizontal) }
        // Clamp at this boundary as a defense against unvalidated imported configuration.
        let v = verticalMultiplier.isFinite ? min(max(verticalMultiplier, 0.1), 10) : 1
        let h = horizontalMultiplier.isFinite ? min(max(horizontalMultiplier, 0.1), 10) : 1
        return (vertical * v * (reverseVertical ? -1 : 1), horizontal * h * (reverseHorizontal ? -1 : 1))
    }
    public var effectiveSmoothingDuration: Double {
        smoothingDuration.isFinite ? min(max(smoothingDuration, 0.03), 0.5) : 0.12
    }
}

public struct RuleBook: Codable, Hashable, Sendable {
    // Version 2 marks device-scoped touch rules and recorded shapes. Version-1
    // clients must reject these exports rather than ignore execution constraints.
    public static let currentSchemaVersion = 2
    public var schemaVersion: Int
    public var rules: [Rule]
    public var scroll: ScrollConfiguration
    public var excludedBundleIdentifiers: Set<String>
    public init(schemaVersion: Int = RuleBook.currentSchemaVersion, rules: [Rule] = [],
                scroll: ScrollConfiguration = ScrollConfiguration(), excludedBundleIdentifiers: Set<String> = []) {
        self.schemaVersion = schemaVersion
        self.rules = rules
        self.scroll = scroll
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, rules, scroll, excludedBundleIdentifiers
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try values.decode(Int.self, forKey: .schemaVersion)
        rules = try values.decode([Rule].self, forKey: .rules)
        scroll = try values.decode(ScrollConfiguration.self, forKey: .scroll)
        excludedBundleIdentifiers = try values.decode(Set<String>.self, forKey: .excludedBundleIdentifiers)
        // TouchGestureTrigger supplies the legacy device=.any default. Retain
        // unknown versions so validation rejects them instead of silently downgrading.
        schemaVersion = storedVersion == 1 ? Self.currentSchemaVersion : storedVersion
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        // Consumers must validate before export/execution. Every supported export
        // advertises the current format even when an in-memory legacy value is used.
        try values.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try values.encode(rules, forKey: .rules)
        try values.encode(scroll, forKey: .scroll)
        try values.encode(excludedBundleIdentifiers, forKey: .excludedBundleIdentifiers)
    }
}
