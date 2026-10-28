import Foundation
import FlowGestureCore

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english, simplifiedChinese
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "System / 系统"
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }
}

enum L10n {
    static func text(_ key: String, language: AppLanguage) -> String {
        let chinese = language == .simplifiedChinese || (language == .system && (Locale.preferredLanguages.first?.hasPrefix("zh") ?? false))
        return chinese ? (zh[key] ?? key) : key
    }

    private static let zh: [String: String] = [
        "Stopped": "已停止", "Accessibility permission required": "需要辅助功能权限",
        "Cannot start input monitor": "无法启动输入监听",

        "Status": "状态",
        "Permission needed — features are not running yet": "尚未获得权限，功能还没有运行",
        "Your settings are saved. Allow Accessibility and Input Monitoring so FlowGesture can apply them.": "设置已经保存。请允许辅助功能与输入监控，行云手势才能执行你的设置。",

        "Scroll engine is running": "滚动调整正在运行", "Scroll engine is not running": "滚动调整尚未运行",
        "FlowGesture is paused. Enable it to apply scrolling changes.": "行云手势已暂停，启用后滚动设置才会生效。",
        "Waiting for scrolling input": "等待滚动输入",
        "You can test scrolling in this window. Mouse settings also apply here.": "可以直接在这个窗口测试滚动，鼠标设置在这里同样生效。",
        "Skipped: application is excluded": "未调整：当前应用已被排除",
        "Scroll adjustments are off": "滚动调整已关闭",
        "Trackpad preserved: mouse-only mode": "触控板保持原样：当前仅调整鼠标",
        "Unidentified continuous/touch scroll preserved": "未识别的连续／触控滚动保持原样",
        "Adjusting standard mouse wheel (device name unavailable)": "正在调整普通鼠标滚轮（无法读取设备名称）",
        "Adjusting identified device scroll": "正在调整已识别设备的滚动",

        "Free-form shape": "自由形状", "Record shape": "录制形状", "Cancel recording": "取消录制", "Test drawing": "试画识别",
        "Record a shape, then draw one continuous stroke here.": "点击录制形状，然后在此处一笔绘制。",
        "Draw with the left mouse button inside this canvas.": "在此画布中按住鼠标左键绘制。",
        "Stroke too long. Record a shorter shape.": "笔画过长，请录制较短的形状。",
        "points": "点", "Minimum similarity": "最低相似度", "Matched": "匹配成功", "Not matched": "未匹配",
        "Size and position may vary. Keep the same orientation, starting point, and drawing direction. Green marks the start.": "大小和位置可变；请保持相同朝向、起点和绘制方向。绿点表示起点。",
        "Draw a larger shape; clicks and tiny strokes are ignored.": "请绘制更大的形状；点击和微小笔画会被忽略。",
        "Shape recorded. Hold the selected trigger button to draw it outside this editor.": "形状已录制。在编辑器外按住所选触发键绘制即可。",
        "This build does not suppress macOS gestures. Disable an overlapping system gesture before testing the same custom gesture, otherwise both may run.": "当前版本不会拦截 macOS 原生手势。测试相同自定义手势前，请先关闭对应系统手势，否则两者可能同时执行。",
        "Review imported rules before enabling": "启用前检查导入规则",
        "Imported or synchronized rules can run AppleScript, type shortcuts and open external targets. Inspect their actions before enabling them.": "导入或同步的规则可能运行 AppleScript、输入快捷键或打开外部目标。请先检查规则中的动作，再启用。",
        "Enable reviewed rules": "启用已检查的规则",
        "Gesture diagnostics": "手势诊断", "Not recording": "未录制", "Start recording": "开始录制", "Stop recording": "停止录制", "Export local trace…": "导出本地记录…",
        "Record event types and touch counts in memory for up to 60 seconds. No keys, text or pointer paths are recorded. Events are never blocked.": "仅在内存中记录事件类型与触点数量，最长 60 秒。不记录按键、文字或指针轨迹，不拦截事件。",
        "Unknown device": "未知设备", "Running": "运行中",
        "Touch device": "触控设备", "Any touch device": "任意触控设备", "Trackpad": "触控板", "Mouse touch surface": "鼠标触控表面",
        "Start with an empty configuration?": "使用空配置重新开始？",
        "The original file will be archived, not deleted. All rules and scroll settings will be reset, and FlowGesture will stay paused.": "原文件将被归档，不会删除。所有规则和滚动设置将重置，FlowGesture 仍保持暂停。",
        "Create empty configuration": "创建空配置",
        "An empty configuration was created. The original file is preserved in the configuration folder.": "已创建空配置。原文件保存在配置文件夹中。",
        "Add examples": "添加示例", "Back — draw left": "后退 — 向左绘制", "Forward — draw right": "前进 — 向右绘制",
        "Back — side button": "后退 — 侧键", "Forward — side button": "前进 — 侧键", "Mission Control — three-finger tap": "调度中心 — 三指轻点",
        "Rules": "规则", "Scrolling": "滚动", "Settings": "设置", "Diagnostics": "诊断",
        "FlowGesture Settings…": "FlowGesture 设置…", "Quit FlowGesture": "退出 FlowGesture",
        "Enabled": "已启用", "Enable FlowGesture": "启用 FlowGesture", "Paused": "已暂停",
        "New rule": "新规则", "Add rule": "添加规则", "Edit rule": "编辑规则", "Duplicate": "复制",
        "Delete": "删除", "Cancel": "取消", "Save": "保存", "Done": "完成", "Close": "关闭",
        "Name": "名称", "Trigger": "触发器", "Actions": "动作", "Add action": "添加动作",
        "Mouse button": "鼠标按键", "Draw gesture": "鼠标绘制手势", "Keyboard shortcut": "键盘快捷键",
        "Touch gesture": "触控手势", "Screen corner": "屏幕角落", "Button": "按键", "Clicks": "点击次数",
        "Left": "左", "Right": "右", "Middle": "中键", "Back": "后退", "Forward": "前进",
        "Modifiers": "修饰键", "Key code": "键码", "Record shortcut": "录制快捷键", "Recording… press a key": "录制中…请按键",
        "Direction sequence": "方向序列", "Add direction": "添加方向", "Clear": "清空",
        "Up": "上", "Down": "下", "Up-left": "左上", "Up-right": "右上", "Down-left": "左下", "Down-right": "右下",
        "Gesture": "手势", "Tap": "轻点", "Swipe": "轻扫", "Pinch": "捏合", "Fingers": "手指数",
        "Direction": "方向", "Inward": "向内", "Outward": "向外", "Corner": "角落",
        "Top-left": "左上角", "Top-right": "右上角", "Bottom-left": "左下角", "Bottom-right": "右下角",
        "Application scope": "应用范围", "All applications": "所有应用", "Only these applications": "仅这些应用",
        "Excluded applications": "排除的应用", "Bundle identifiers, one per line": "应用包标识符，每行一个",
        "Choose application…": "选择应用…", "Priority": "优先级", "Application-specific rules run first, then higher priority, then saved order. Only the first match runs.": "应用专属规则优先，然后按优先级和保存顺序匹配。仅执行首个匹配规则。",
        "Open URL": "打开网址", "Open application": "打开应用", "AppleScript": "AppleScript", "Menu item": "菜单项",
        "Window": "窗口", "System": "系统", "URL": "网址", "Application path or bundle ID": "应用路径或包标识符",
        "Menu path, separated by >": "菜单路径，以 > 分隔", "Action": "动作",
        "Scripts execute with your user permissions. Review imported scripts before enabling rules.": "脚本以你的用户权限执行。启用导入的规则前，请先审核脚本。",
        "Maximize": "最大化", "Center": "居中", "Left half": "左半屏", "Right half": "右半屏", "Top half": "上半屏", "Bottom half": "下半屏", "Minimize": "最小化",
        "Mission Control": "调度中心", "Show desktop": "显示桌面", "Application windows": "应用窗口", "Launchpad": "启动台",
        "Volume up": "增大音量", "Volume down": "减小音量", "Mute": "静音", "Brightness up": "提高亮度", "Brightness down": "降低亮度",
        "Play / pause": "播放 / 暂停", "Next track": "下一首", "Previous track": "上一首", "Lock screen": "锁定屏幕",
        "No rules yet": "尚无规则", "Create a trigger and choose what it does. Rules stay local unless you choose a sync folder.": "创建触发器并选择动作。除非你选择同步文件夹，否则规则仅保存在本机。",
        "Search rules": "搜索规则", "Global": "全局", "No action": "无动作", "More": "更多",
        "Enable scroll adjustments": "启用滚动调整", "Reverse vertical": "反转垂直滚动", "Reverse horizontal": "反转水平滚动",
        "Vertical speed": "垂直速度", "Horizontal speed": "水平速度", "Also adjust trackpad / continuous scrolling": "同时调整触控板 / 连续滚动",
        "Discrete mouse wheels are adjusted by default. Trackpad scrolling is left unchanged unless enabled above.": "默认仅调整非连续鼠标滚轮；除非启用上面的选项，否则不改变触控板滚动。",
        "Smooth mouse wheel": "平滑鼠标滚轮", "Smoothing duration": "平滑时长",
        "General": "通用", "Language": "语言", "Configuration": "配置", "Import JSON…": "导入 JSON…", "Export JSON…": "导出 JSON…",
        "Show configuration folder": "显示配置文件夹", "Restore previous backup…": "恢复上一份备份…",
        "Sync folder": "同步文件夹", "Choose sync folder…": "选择同步文件夹…", "Disconnect": "断开", "Sync now": "立即同步",
        "Not connected": "未连接", "Choose any folder, including a folder in iCloud Drive. Changes are synchronized while FlowGesture is running. Conflicts require your choice.": "可选择任意文件夹，包括 iCloud 云盘文件夹。FlowGesture 运行时同步更改；出现冲突时由你选择保留哪个版本。",
        "Keep local version": "保留本地版本", "Use shared version": "使用共享版本", "Sync conflict": "同步冲突",
        "Global exclusions": "全局排除", "FlowGesture ignores these applications for every rule and scroll adjustment.": "所有规则和滚动调整均忽略这些应用。",
        "Permissions": "权限", "Accessibility": "辅助功能", "Input Monitoring": "输入监控", "Granted": "已授权", "Not granted": "未授权",
        "Request permissions": "请求权限", "Open Accessibility settings": "打开辅助功能设置", "Open Input Monitoring settings": "打开输入监控设置",
        "Refresh status": "刷新状态", "Engine": "引擎", "Last event": "最近事件", "Touch backend": "触控后端",
        "Not running": "未运行", "Not available": "不可用", "No event yet": "尚无事件", "Configuration file": "配置文件",
        "The configuration could not be loaded. The original file has been preserved; rules are paused until you restore a backup or import a valid file.": "无法加载配置。原文件已保留；恢复备份或导入有效文件前，规则保持暂停。",
        "Error": "错误", "Dismiss": "关闭", "Backup restored": "备份已恢复", "Configuration imported": "配置已导入", "Configuration exported": "配置已导出",
        "Delete rule?": "删除此规则？", "This cannot be undone.": "此操作无法撤销。", "Restore previous backup?": "恢复上一份备份？",
        "Your current configuration will be archived before restoring the backup.": "恢复备份前会归档当前配置。",
        "Replace configuration?": "替换配置？", "Importing replaces all rules and scroll settings. Review scripts and URLs before enabling imported rules.": "导入会替换所有规则和滚动设置。启用导入规则前，请审核脚本和网址。",
        "Import paused": "导入后暂停", "Restore": "恢复", "Sync file already exists": "同步文件已存在",
        "Use the shared file, or replace it with this Mac’s configuration?": "使用共享配置，还是用此 Mac 的配置替换共享文件？",
        "Publish local version": "发布本地版本", "Synchronized": "已同步", "Waiting for changes": "等待更改",
        "Local and shared files both changed. Choose which version to keep.": "本地和共享文件均已更改，请选择保留哪个版本。",
        "Imported rules are paused. Review them, then enable FlowGesture.": "导入的规则已暂停。审核后请启用 FlowGesture。",
        "A rule needs a name and at least one action.": "规则需要名称及至少一个动作。",
        "Touch support depends on the connected device and macOS. Check Diagnostics for the actual backend status.": "触控支持取决于设备和 macOS。请在诊断页查看实际后端状态。",
        "Hold the selected mouse button and draw the directions in order.": "按住所选鼠标按键，依次绘制指定方向。",
        "Key codes are macOS virtual key codes. Use Record shortcut to capture the key and modifiers.": "键码为 macOS 虚拟键码。使用录制快捷键可捕获按键和修饰键。",
        "Move the pointer into the selected screen corner. Add modifiers to avoid accidental triggers.": "将指针移入所选屏幕角落。建议添加修饰键，以避免意外触发。",
        "Leave the inclusion list empty to apply to all applications.": "包含列表留空时，规则适用于所有应用。",
        "Open file or folder": "打开文件或文件夹", "Custom window frame": "自定义窗口位置大小",
        "File or folder path": "文件或文件夹路径", "Choose…": "选择…", "Width": "宽度", "Height": "高度",
        "Normalized screen coordinates (0–1); Y starts at the bottom.": "屏幕归一化坐标（0–1）；Y 从底部开始。",
        "Move up": "上移", "Move down": "下移", "Remove": "移除", "Rule validation": "规则验证"
    ]

    static func mouse(_ value: MouseButton) -> String {
        switch value {
        case .left: return "Left"
        case .right: return "Right"
        case .middle: return "Middle"
        case .back: return "Back"
        case .forward: return "Forward"
        default: return "Button \(value.rawValue + 1)"
        }
    }
    static func direction(_ value: GestureDirection) -> String {
        switch value {
        case .right: return "Right"
        case .upRight: return "Up-right"
        case .up: return "Up"
        case .upLeft: return "Up-left"
        case .left: return "Left"
        case .downLeft: return "Down-left"
        case .down: return "Down"
        case .downRight: return "Down-right"
        }
    }
    static func arrow(_ value: GestureDirection) -> String {
        switch value {
        case .right: return "→"
        case .upRight: return "↗"
        case .up: return "↑"
        case .upLeft: return "↖"
        case .left: return "←"
        case .downLeft: return "↙"
        case .down: return "↓"
        case .downRight: return "↘"
        }
    }
    static func corner(_ value: ScreenCorner) -> String {
        switch value {
        case .topLeft: return "Top-left"
        case .topRight: return "Top-right"
        case .bottomLeft: return "Bottom-left"
        case .bottomRight: return "Bottom-right"
        }
    }
    static func window(_ value: WindowAction) -> String {
        switch value {
        case .maximize: return "Maximize"
        case .center: return "Center"
        case .leftHalf: return "Left half"
        case .rightHalf: return "Right half"
        case .topHalf: return "Top half"
        case .bottomHalf: return "Bottom half"
        case .minimize: return "Minimize"
        case .close: return "Close"
        }
    }
    static func system(_ value: SystemAction) -> String {
        switch value {
        case .missionControl: return "Mission Control"
        case .showDesktop: return "Show desktop"
        case .applicationWindows: return "Application windows"
        case .launchpad: return "Launchpad"
        case .volumeUp: return "Volume up"
        case .volumeDown: return "Volume down"
        case .mute: return "Mute"
        case .brightnessUp: return "Brightness up"
        case .brightnessDown: return "Brightness down"
        case .playPause: return "Play / pause"
        case .nextTrack: return "Next track"
        case .previousTrack: return "Previous track"
        case .lockScreen: return "Lock screen"
        }
    }
    static func modifiers(_ value: ModifierKeys) -> String {
        [(ModifierKeys.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"), (.function, "fn ")]
            .filter { value.contains($0.0) }.map(\.1).joined()
    }
}
