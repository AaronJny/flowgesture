import AppKit
import ApplicationServices
import FlowGestureCore

final class ActionExecutor {
    var onError: ((String) -> Void)?
    private let scriptQueue = DispatchQueue(label: "FlowGesture.actions")
    func execute(_ actions: [Action]) {
        let app = NSWorkspace.shared.frontmostApplication
        // Ordered serial execution preserves action-list semantics, including scripts.
        scriptQueue.async { [weak self] in
            guard let self else { return }
            var targetApp = app
            for action in actions {
                switch action {
                case .appleScript(let text): self.script(text)
                case .openApplication(let identifier):
                    let result = ApplicationLaunchResult()
                    let completed = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async {
                        self.openApplication(identifier) { application in
                            result.store(application); completed.signal()
                        }
                    }
                    guard completed.wait(timeout: .now() + 15) == .success else {
                        self.fail("Application launch timed out / 应用启动超时"); return
                    }
                    guard let launched = result.read() else { return }
                    targetApp = launched
                    DispatchQueue.main.sync { _ = launched.activate(options: .activateIgnoringOtherApps) }
                default: DispatchQueue.main.sync { self.perform(action, app: targetApp) }
                }
            }
        }
    }
    private func perform(_ action: Action, app: NSRunningApplication?) {
        switch action {
        case .shortcut(let shortcut): shortcutEvent(shortcut)
        case .openURL(let value):
            guard let url = URL(string: value), let scheme = url.scheme, !scheme.isEmpty else { fail("Invalid URL / 无效网址"); return }
            if !NSWorkspace.shared.open(url) { fail("Could not open URL / 无法打开网址") }
        case .openPath(let path):
            if !NSWorkspace.shared.open(URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)) { fail("Could not open path / 无法打开路径") }
        case .openApplication: break // Serialized by execute, including launch completion.
        case .appleScript: break
        case .menuItem(let path): menu(path, app: app)
        case .window(let operation): window(operation, custom: nil, app: app)
        case .windowFrame(let x, let y, let width, let height): window(.maximize, custom: CGRect(x: x, y: y, width: width, height: height), app: app)
        case .system(let system): systemAction(system)
        }
    }
    private func openApplication(_ identifier: String, completion: @escaping (NSRunningApplication?) -> Void) {
        let url = identifier.hasPrefix("/") ? URL(fileURLWithPath: identifier) : NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        guard let url else { fail("Application not found / 找不到应用：\(identifier)"); completion(nil); return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] application, error in
            if let error { self?.fail(error.localizedDescription) }
            completion(application)
        }
    }
    private func fail(_ message: String) { DispatchQueue.main.async { [weak self] in self?.onError?(message) } }
    private func script(_ source: String) {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { fail("Invalid AppleScript / 脚本无效"); return }
        script.executeAndReturnError(&error)
        if let error { fail(error.description) }
    }
    private func shortcutEvent(_ shortcut: KeyboardShortcut) {
        var flags: CGEventFlags = []
        if shortcut.modifiers.contains(.command) { flags.insert(.maskCommand) }; if shortcut.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if shortcut.modifiers.contains(.control) { flags.insert(.maskControl) }; if shortcut.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if shortcut.modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        for down in [true,false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: down)
            event?.flags = flags; event?.setIntegerValueField(.eventSourceUserData, value: EventEngine.syntheticTag); event?.post(tap: .cghidEventTap)
        }
    }
    private func attribute(_ element: AXUIElement, _ key: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key, &value) == .success ? value : nil
    }
    private func menu(_ path: [String], app: NSRunningApplication?) {
        guard let app, !path.isEmpty else { fail("No target application / 没有目标应用"); return }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBar = attribute(root, kAXMenuBarAttribute as CFString) else { fail("No accessible menu / 无可访问菜单"); return }
        var element = menuBar as! AXUIElement
        for (index, title) in path.enumerated() {
            var children = (attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement]) ?? []
            if children.count == 1, let role = attribute(children[0], kAXRoleAttribute as CFString) as? String, role == kAXMenuRole {
                children = (attribute(children[0], kAXChildrenAttribute as CFString) as? [AXUIElement]) ?? []
            }
            guard let match = children.first(where: { (attribute($0, kAXTitleAttribute as CFString) as? String) == title }) else { fail("Menu item missing / 菜单项不存在：\(title)"); return }
            element = match
            if index < path.count - 1 { _ = AXUIElementPerformAction(element, kAXPressAction as CFString) }
        }
        if AXUIElementPerformAction(element, kAXPressAction as CFString) != .success { fail("Menu action failed / 菜单动作失败") }
    }
    private func window(_ operation: WindowAction, custom: CGRect?, app: NSRunningApplication?) {
        guard let app else { return }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard let value = attribute(application, kAXFocusedWindowAttribute as CFString) else { fail("No focused window / 没有当前窗口"); return }
        let win = value as! AXUIElement
        if operation == .minimize { _ = AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanTrue); return }
        if operation == .close {
            guard let button = attribute(win, kAXCloseButtonAttribute as CFString) else { fail("Window has no close button / 窗口无关闭按钮"); return }
            _ = AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString); return
        }
        var position = CGPoint.zero, size = CGSize(width: 800, height: 600)
        if let p = attribute(win, kAXPositionAttribute as CFString) { _ = AXValueGetValue(p as! AXValue, .cgPoint, &position) }
        if let s = attribute(win, kAXSizeAttribute as CFString) { _ = AXValueGetValue(s as! AXValue, .cgSize, &size) }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaCenter = CGPoint(x: position.x + size.width/2, y: primaryHeight-position.y-size.height/2)
        let screen = NSScreen.screens.first { $0.frame.contains(cocoaCenter) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let frame = CGRect(x: visible.minX, y: primaryHeight-visible.maxY, width: visible.width, height: visible.height)
        var target = frame
        if let custom {
            guard custom.minX.isFinite, custom.minY.isFinite, custom.width.isFinite, custom.height.isFinite,
                  custom.minX >= 0, custom.minY >= 0, custom.width > 0, custom.height > 0,
                  custom.maxX <= 1, custom.maxY <= 1 else { fail("Window fractions must fit 0…1 / 窗口比例必须位于0…1"); return }
            target = CGRect(x: frame.minX+custom.minX*frame.width, y: frame.minY+(1-custom.minY-custom.height)*frame.height, width: custom.width*frame.width, height: custom.height*frame.height)
        } else {
            switch operation {
            case .center: target = CGRect(x: frame.midX-size.width/2, y: frame.midY-size.height/2, width: size.width, height: size.height)
            case .leftHalf: target.size.width /= 2
            case .rightHalf: target.origin.x += frame.width/2; target.size.width /= 2
            case .topHalf: target.size.height /= 2
            case .bottomHalf: target.origin.y += frame.height/2; target.size.height /= 2
            default: break
            }
        }
        var newPosition = target.origin, newSize = target.size
        guard let p = AXValueCreate(.cgPoint, &newPosition), let s = AXValueCreate(.cgSize, &newSize) else { return }
        let first = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, s)
        let second = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, p)
        if first != .success || second != .success { fail("Application refused window change / 应用拒绝窗口调整") }
    }
    private func systemAction(_ action: SystemAction) {
        switch action {
        case .missionControl: shortcutEvent(KeyboardShortcut(keyCode: 126, modifiers: .control))
        case .showDesktop: shortcutEvent(KeyboardShortcut(keyCode: 103))
        case .applicationWindows: shortcutEvent(KeyboardShortcut(keyCode: 125, modifiers: .control))
        case .launchpad: shortcutEvent(KeyboardShortcut(keyCode: 118))
        case .lockScreen: shortcutEvent(KeyboardShortcut(keyCode: 12, modifiers: [.command,.control]))
        default:
            let codes: [SystemAction:Int] = [.volumeUp:0,.volumeDown:1,.brightnessUp:2,.brightnessDown:3,.mute:7,.playPause:16,.nextTrack:17,.previousTrack:18]
            guard let code = codes[action] else { return }
            for down in [true,false] {
                let data = (code << 16) | ((down ? 0xA : 0xB) << 8)
                if let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data, data2: -1)?.cgEvent {
                    event.setIntegerValueField(.eventSourceUserData, value: EventEngine.syntheticTag); event.post(tap: .cghidEventTap)
                }
            }
        }
    }
}

private final class ApplicationLaunchResult {
    private let lock = NSLock()
    private var application: NSRunningApplication?
    func store(_ value: NSRunningApplication?) { lock.lock(); application = value; lock.unlock() }
    func read() -> NSRunningApplication? { lock.lock(); defer { lock.unlock() }; return application }
}
