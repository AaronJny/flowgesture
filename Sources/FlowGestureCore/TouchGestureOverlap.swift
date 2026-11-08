/// Possible overlaps, not a probe of the user's current macOS preferences.
/// Modifiers and application scopes do not reserve the underlying native gesture.
public enum TouchGestureOverlap: String, Hashable, Sendable {
    case trackpadClick, trackpadSecondaryClick, trackpadLookup
    case trackpadScroll, trackpadPages, trackpadSpaces, trackpadMissionControl, trackpadAppExpose, trackpadZoom
    case mouseScroll, mousePages, mouseSpaces

    public static func possible(for trigger: TouchGestureTrigger) -> [Self] {
        var result: [Self] = []
        if trigger.device != .mouse {
            switch trigger.gesture {
            case .tap(1): result.append(.trackpadClick)
            case .tap(2): result.append(.trackpadSecondaryClick)
            case .tap(3): result.append(.trackpadLookup)
            case .pinch: result.append(.trackpadZoom)
            case .swipe(let fingers, let direction):
                if fingers == 2 { result.append(.trackpadScroll) }
                if (2...3).contains(fingers), direction.hasHorizontalComponent { result.append(.trackpadPages) }
                if (3...4).contains(fingers) {
                    if direction.hasHorizontalComponent { result.append(.trackpadSpaces) }
                    if direction == .up || direction == .upLeft || direction == .upRight { result.append(.trackpadMissionControl) }
                    if direction == .down || direction == .downLeft || direction == .downRight { result.append(.trackpadAppExpose) }
                }
            default: break
            }
        }
        if trigger.device != .trackpad, case .swipe(let fingers, let direction) = trigger.gesture {
            if fingers == 1 {
                result.append(.mouseScroll)
                if direction.hasHorizontalComponent { result.append(.mousePages) }
            }
            if fingers == 2, direction.hasHorizontalComponent { result.append(.mouseSpaces) }
        }
        return result
    }
}

private extension GestureDirection {
    var hasHorizontalComponent: Bool { self != .up && self != .down }
}
