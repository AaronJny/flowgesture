/// A saved rule's touch-device restriction. `.any` is a wildcard only on the
/// rule side; an observed event with unknown device type cannot match a
/// trackpad-only or mouse-only rule. Raw mouse touches require a capable device
/// such as Magic Mouse; this is not a promise that every mouse exposes touches.
public enum TouchDeviceScope: String, Codable, Hashable, CaseIterable, Sendable {
    case any
    case trackpad
    case mouse
}
