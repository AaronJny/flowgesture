import AppKit
import SwiftUI
import FlowGestureCore

struct TouchConflictAdviceView: View {
    @EnvironmentObject private var model: AppModel
    let trigger: TouchGestureTrigger
    @Binding var isRuleEnabled: Bool
    @State private var settingsOpenFailed = false

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
            Text(model.mappingText("To use FlowGesture, manually turn off only the conflicting macOS gesture in System Settings. To keep the system gesture, disable this rule. App scopes and modifiers do not disable macOS gestures.", "想使用 FlowGesture：请自行在系统设置中关闭上面对应的冲突手势。想保留系统手势：停用这条规则即可。应用范围和修饰键不会停用 macOS 手势。"))
            HStack {
                Button(model.mappingText("Open System Settings", "打开系统设置")) {
                    // Open the app only. Never change or infer the user's settings.
                    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") else {
                        settingsOpenFailed = true
                        return
                    }
                    settingsOpenFailed = !NSWorkspace.shared.open(url)
                }.accessibilityIdentifier("flowgesture.touch.open.settings")
                Button(model.mappingText("Disable this rule", "停用这条规则")) {
                    isRuleEnabled = false
                }.disabled(!isRuleEnabled)
                    .accessibilityIdentifier("flowgesture.touch.keep.system")
            }
            if !isRuleEnabled {
                Text(model.mappingText("This rule will be disabled when saved. Cancel leaves it unchanged. Disable any other rules for the same gesture too.", "这条规则将在保存后停用，取消则不改变原规则。如果还有相同手势的其他规则，也需分别停用。"))
            }
            if settingsOpenFailed {
                Text(model.mappingText("Open System Settings from the Apple menu, then follow the path above.", "请从苹果菜单打开“系统设置”，再按上面的路径调整。"))
            }
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
