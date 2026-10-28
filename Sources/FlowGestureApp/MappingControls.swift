import AppKit
import SwiftUI
import FlowGestureCore

extension AppModel {
    func mappingText(_ english: String, _ chinese: String) -> String {
        let isChinese = language == .simplifiedChinese || (language == .system && (Locale.preferredLanguages.first?.hasPrefix("zh") ?? false))
        return isChinese ? chinese : english
    }
}

@MainActor
enum MappingLabels {
    static func mouse(_ button: MouseButton, model: AppModel) -> String {
        switch button {
        case .left: return model.mappingText("Left click", "左键")
        case .right: return model.mappingText("Right click", "右键")
        case .middle: return model.mappingText("Wheel press", "滚轮按下")
        default: return model.mappingText("Mouse button \(button.rawValue + 1)", "鼠标按钮 \(button.rawValue + 1)")
        }
    }
    static func key(_ code: UInt16) -> String {
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc", 76: "⌤", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "PgUp", 121: "PgDn", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        if let name = special[code] { return name }
        // Constructing an event does not post it; AppKit resolves the current keyboard layout.
        if let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
           let name = NSEvent(cgEvent: event)?.charactersIgnoringModifiers,
           !name.isEmpty, name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            return name.uppercased()
        }
        let fallback: [UInt16: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"−",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",50:"`"]
        return fallback[code] ?? "#\(code)"
    }
    static func shortcut(_ value: FlowGestureCore.KeyboardShortcut) -> String {
        L10n.modifiers(value.modifiers) + key(value.keyCode)
    }
    static func action(_ value: Action?, model: AppModel) -> String {
        guard let value else { return model.mappingText("Choose action", "选择动作") }
        if case .shortcut(let shortcut) = value { return Self.shortcut(shortcut) }
        return model.actionTitle(value)
    }
    static func trigger(_ value: InputTrigger, model: AppModel) -> String {
        switch value {
        case .mouseButton(let trigger):
            return L10n.modifiers(trigger.modifiers) + mouse(trigger.button, model: model) + (trigger.clickCount > 1 ? " ×\(trigger.clickCount)" : "")
        case .keyboard(let shortcut): return Self.shortcut(shortcut)
        default: return model.triggerTitle(value)
        }
    }
}

/// Only this small local view receives capture clicks. There is no global mouse
/// monitor or event tap, so clicking another app is never swallowed by this UI.
struct MouseButtonCaptureSurface: NSViewRepresentable {
    let onCapture: (Int, NSEvent.ModifierFlags) -> Void
    func makeNSView(context: Context) -> CaptureView { let view = CaptureView(); view.onCapture = onCapture; return view }
    func updateNSView(_ view: CaptureView, context: Context) { view.onCapture = onCapture }
    final class CaptureView: NSView {
        var onCapture: ((Int, NSEvent.ModifierFlags) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        private var pendingButton: Int?
        private var pendingFlags: NSEvent.ModifierFlags = []
        private func begin(_ event: NSEvent) { guard pendingButton == nil else { return }; pendingButton = event.buttonNumber; pendingFlags = event.modifierFlags }
        private func finish(_ event: NSEvent) {
            guard let number = pendingButton, number == event.buttonNumber else { return }
            pendingButton = nil
            onCapture?(number, pendingFlags)
        }
        override func mouseDown(with event: NSEvent) { begin(event) }
        override func rightMouseDown(with event: NSEvent) { begin(event) }
        override func otherMouseDown(with event: NSEvent) { begin(event) }
        override func mouseDragged(with event: NSEvent) {}
        override func rightMouseDragged(with event: NSEvent) {}
        override func otherMouseDragged(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) { finish(event) }
        override func rightMouseUp(with event: NSEvent) { finish(event) }
        override func otherMouseUp(with event: NSEvent) { finish(event) }

    }
}

struct MouseButtonVisual: View {
    let button: MouseButton
    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 26).fill(Color.secondary.opacity(0.06)).frame(width: 70, height: 102)
            RoundedRectangle(cornerRadius: 26).stroke(Color.secondary.opacity(0.3), lineWidth: 1.5).frame(width: 70, height: 102)
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 10).fill(button == .left ? Color.accentColor.opacity(0.45) : Color.clear)
                RoundedRectangle(cornerRadius: 10).fill(button == .right ? Color.accentColor.opacity(0.45) : Color.clear)
            }.frame(width: 58, height: 40).padding(.top, 8)
            RoundedRectangle(cornerRadius: 5).fill(button == .middle ? Color.accentColor : Color.secondary.opacity(0.35)).frame(width: 12, height: 24).padding(.top, 16)
            if button.rawValue > 2 {
                Text("\(button.rawValue + 1)").font(.title3.bold()).foregroundStyle(Color.accentColor).padding(.top, 60)
            }
        }.frame(width: 76, height: 106).accessibilityHidden(true)
    }
}

struct CompactApplicationScopeEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var scope: AppScope
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.mappingText("Use in", "应用范围")).font(.subheadline.weight(.medium))
                Spacer()
                Picker("", selection: Binding(get: { !scope.isGlobal }, set: { limited in
                    if !limited { scope.bundleIdentifiers.removeAll() }
                    else { chooseApplication() }
                })) {
                    Text(model.mappingText("All apps", "所有应用")).tag(false)
                    Text(model.mappingText("Selected apps", "指定应用")).tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 260)
            }
            if !scope.isGlobal {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(scope.bundleIdentifiers.sorted(), id: \.self) { identifier in
                        HStack(spacing: 6) {
                            Image(systemName: "app")
                            Text(appName(identifier)).lineLimit(1)
                            Spacer(minLength: 0)
                            Button { scope.bundleIdentifiers.remove(identifier) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).disabled(scope.bundleIdentifiers.count == 1)
                                .help(model.mappingText("Choose All apps to remove the final restriction.", "如需全局应用，请明确切换到所有应用。"))
                        }.padding(7).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    }
                    Button { chooseApplication() } label: { Label(model.mappingText("Add app", "添加应用"), systemImage: "plus") }
                }
            }
            if !scope.excludedBundleIdentifiers.isEmpty {
                Text(model.mappingText("\(scope.excludedBundleIdentifiers.count) app exclusions in Advanced", "高级设置中已排除 \(scope.excludedBundleIdentifiers.count) 个应用")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func chooseApplication() {
        if let identifier = model.chooseApplication() { scope.bundleIdentifiers.insert(identifier) }
    }
    private func appName(_ identifier: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return identifier }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
