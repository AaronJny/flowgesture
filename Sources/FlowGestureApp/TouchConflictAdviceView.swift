import SwiftUI
import FlowGestureCore

struct TouchConflictAdviceView: View {
    @EnvironmentObject private var model: AppModel
    let trigger: TouchGestureTrigger

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(model.mappingText("Potential native gesture overlap", "可能与原生手势重叠"), systemImage: "exclamationmark.triangle")
                .font(.caption.bold()).foregroundStyle(.orange)
            Text(model.mappingText("FlowGesture does not suppress native gestures. Both actions may run; the current system assignments have not been checked.", "FlowGesture 不会拦截原生手势，两种动作可能同时执行；此处尚未检查你的系统手势设置。"))
            ForEach(TouchGestureOverlap.possible(for: trigger), id: \.self) { overlap in
                Text("• " + description(overlap))
            }
            if trigger.device != .mouse {
                Text(model.mappingText("Review System Settings → Trackpad → Point & Click, Scroll & Zoom, or More Gestures.", "请检查 系统设置 → 触控板 → 光标与点按、滚动缩放或更多手势。"))
            }
            if trigger.device != .trackpad {
                Text(model.mappingText("For Magic Mouse, review System Settings → Mouse → More Gestures. Ordinary mice do not provide multi-finger touch input.", "Magic Mouse 请检查 系统设置 → 鼠标 → 更多手势。普通鼠标不提供多指触控输入。"))
            }
            Text(model.mappingText("Choose another gesture, manually change an overlapping system assignment, or keep both actions. App scopes and modifiers limit FlowGesture only; they do not disable macOS gestures.", "你可以改选手势、手动调整重叠的系统手势，或保留两种动作。应用范围和修饰键只限制 FlowGesture，不会停用 macOS 手势。"))
        }
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("flowgesture.touch.conflict.advice")
    }

    private func description(_ overlap: TouchGestureOverlap) -> String {
        switch overlap {
        case .trackpadClick: return model.mappingText("Trackpad: tap to click.", "触控板：轻点来点按。")
        case .trackpadSecondaryClick: return model.mappingText("Trackpad: secondary click.", "触控板：辅助点按。")
        case .trackpadLookup: return model.mappingText("Trackpad: Look up & data detectors.", "触控板：查询与数据检测器。")
        case .trackpadScroll: return model.mappingText("Trackpad: two-finger scrolling.", "触控板：双指滚动。")
        case .trackpadPages: return model.mappingText("Trackpad: swipe between pages, including browser history.", "触控板：在页面之间轻扫，包括浏览器前进／后退。")
        case .trackpadSpaces: return model.mappingText("Trackpad: swipe between full-screen applications / Spaces.", "触控板：在全屏幕显示的应用／空间之间轻扫。")
        case .trackpadMissionControl: return model.mappingText("Trackpad: Mission Control.", "触控板：调度中心。")
        case .trackpadAppExpose: return model.mappingText("Trackpad: App Exposé.", "触控板：应用 Exposé。")
        case .trackpadZoom: return model.mappingText("Trackpad: native pinch zoom in apps such as Safari and Preview.", "触控板：Safari、预览等应用中的原生捏合缩放。")
        case .mouseScroll: return model.mappingText("Magic Mouse: surface scrolling.", "Magic Mouse：触控表面滚动。")
        case .mousePages: return model.mappingText("Magic Mouse: swipe between pages.", "Magic Mouse：在页面之间轻扫。")
        case .mouseSpaces: return model.mappingText("Magic Mouse: swipe between full-screen applications / Spaces.", "Magic Mouse：在全屏幕显示的应用／空间之间轻扫。")
        }
    }
}
