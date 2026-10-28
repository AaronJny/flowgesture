#if os(macOS)
import AppKit
import CoreGraphics
import FlowGestureCore

struct OwnAppInputContext: Equatable {
    var isOwnAppActive: Bool
    var isEditingText: Bool
    var isPointerOverOwnWindowUI: Bool
    init(isOwnAppActive: Bool, isEditingText: Bool = false, isPointerOverOwnWindowUI: Bool = false) {
        self.isOwnAppActive = isOwnAppActive
        self.isEditingText = isEditingText
        self.isPointerOverOwnWindowUI = isPointerOverOwnWindowUI
    }
}

/// Protect editing and primary clicks inside the key settings/editor window,
/// without exempting the app from side-button, keyboard, touch or corner mappings.
/// Explicit shortcut/mouse recording is separately protected by stopping the engine.
struct OwnAppInputPolicy {
    private(set) var isPassingLeftClick = false

    /// Call on every raw event before starting a mapping. A down that belongs to a
    /// own key window owns the entire native pair even if the pointer/focus moves.
    mutating func shouldBypass(eventType: CGEventType, context: OwnAppInputContext) -> Bool {
        switch eventType {
        case .leftMouseDown:
            isPassingLeftClick = context.isOwnAppActive && context.isPointerOverOwnWindowUI
            return isPassingLeftClick
        case .leftMouseDragged: return isPassingLeftClick
        case .leftMouseUp:
            let result = isPassingLeftClick
            isPassingLeftClick = false
            return result
        case .keyDown, .keyUp: return context.isOwnAppActive && context.isEditingText
        default: return false
        }
    }

    mutating func reset() { isPassingLeftClick = false }

    /// For pointer triggers, supply the captured DOWN context, not a later stroke
    /// endpoint. Other trigger kinds do not depend on pointer location.
    static func shouldBypass(trigger: InputTrigger, context: OwnAppInputContext) -> Bool {
        guard context.isOwnAppActive else { return false }
        switch trigger {
        case .keyboard: return context.isEditingText
        case .mouseButton(let trigger): return trigger.button == .left && context.isPointerOverOwnWindowUI
        case .draw(let trigger): return trigger.button == .left && context.isPointerOverOwnWindowUI
        case .shape(let trigger): return trigger.button == .left && context.isPointerOverOwnWindowUI
        case .touch, .screenCorner: return false
        }
    }

    /// Read on the main thread. NSApp.isActive, rather than a cached/frontmost PID,
    /// decides whether local UI needs protection. No text contents are inspected.
    static func context(atQuartzPoint point: CGPoint? = nil) -> OwnAppInputContext {
        assert(Thread.isMainThread)
        let active = NSApp.isActive
        return OwnAppInputContext(isOwnAppActive: active,
                                  isEditingText: active && isEditingText(NSApp.keyWindow?.firstResponder),
                                  isPointerOverOwnWindowUI: active && point.map(isOverOwnWindowUI(atQuartzPoint:)) == true)
    }

    static func isEditingText(_ responder: NSResponder?) -> Bool {
        // A SwiftUI hosting view can conform to NSTextInputClient even when no
        // text entry is active. Only the actual editable field editor is protected.
        (responder as? NSTextView)?.isEditable == true
    }

    private static func isOverOwnWindowUI(atQuartzPoint point: CGPoint) -> Bool {
        guard let primary = NSScreen.screens.first,
              let window = NSApp.keyWindow,
              window.isVisible, !window.isMiniaturized, window.isOnActiveSpace,
              !window.ignoresMouseEvents else { return false }
        let screenPoint = NSPoint(x: point.x, y: primary.frame.maxY - point.y)
        // Whole-window protection deliberately avoids brittle SwiftUI control
        // hit-testing; non-primary buttons remain eligible everywhere in this UI.
        return window.frame.contains(screenPoint)
    }
}
#endif
