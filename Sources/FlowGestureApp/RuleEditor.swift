import AppKit
import SwiftUI
import FlowGestureCore

struct RuleEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var rule: Rule
    let onSave: (Rule) -> Bool

    private var issues: [RuleValidationIssue] { RuleBook(rules: [rule]).validationIssues() }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.t("Edit rule")).font(.title2.bold())
                Spacer()
                Toggle(model.t("Enabled"), isOn: $rule.isEnabled).toggleStyle(.switch)
            }.padding(22)
            Divider()
            Form {
                Section {
                    TextField(model.t("Name"), text: $rule.name)
                    Stepper("\(model.t("Priority")): \(rule.priority)", value: $rule.priority, in: -1000...1000)
                    Text(model.t("Higher priorities run first; only the first matching rule runs.")).font(.caption).foregroundStyle(.secondary)
                }
                Section(model.t("Trigger")) {
                    Picker(model.t("Trigger"), selection: Binding(get: { TriggerKind(rule.trigger) }, set: { rule.trigger = $0.initial })) {
                        ForEach(TriggerKind.allCases) { Text(model.t($0.rawValue)).tag($0) }
                    }
                    triggerEditor
                }
                Section(model.t("Application scope")) { ApplicationScopeEditor(scope: $rule.scope) }
                Section(model.t("Actions")) {
                    ForEach(Array(rule.actions.indices), id: \.self) { index in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Spacer()
                                Button { rule.actions.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }
                                    .disabled(index == 0).help(model.t("Move up"))
                                Button { rule.actions.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }
                                    .disabled(index == rule.actions.count - 1).help(model.t("Move down"))
                                Button(role: .destructive) { rule.actions.remove(at: index) } label: { Image(systemName: "trash") }
                                    .help(model.t("Remove"))
                            }.buttonStyle(.borderless)
                            ActionEditor(action: Binding(get: {
                                rule.actions.indices.contains(index) ? rule.actions[index] : .system(.missionControl)
                            }, set: { updated in
                                if rule.actions.indices.contains(index) { rule.actions[index] = updated }
                            }))
                        }.padding(.vertical, 8)
                    }
                    Button { rule.actions.append(.shortcut(FlowGestureCore.KeyboardShortcut(keyCode: 8, modifiers: .command))) } label: {
                        Label(model.t("Add action"), systemImage: "plus")
                    }
                }
                if !issues.isEmpty {
                    Section(model.t("Rule validation")) {
                        ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                            Text(issue.message).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button(model.t("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(model.t("Save")) { if onSave(rule) { dismiss() } }
                    .keyboardShortcut(.defaultAction).disabled(!issues.isEmpty)
            }.padding(18)
        }.frame(minWidth: 650, idealWidth: 700, minHeight: 650, idealHeight: 780)
    }

    @ViewBuilder private var triggerEditor: some View {
        switch rule.trigger {
        case .mouseButton:
            MouseTriggerEditor(value: caseBinding($rule.trigger, fallback: MouseButtonTrigger(), extract: { if case .mouseButton(let value) = $0 { return value }; return nil }, embed: InputTrigger.mouseButton))
        case .draw:
            DrawTriggerEditor(value: caseBinding($rule.trigger, fallback: DrawGestureTrigger(), extract: { if case .draw(let value) = $0 { return value }; return nil }, embed: InputTrigger.draw))
        case .keyboard:
            ShortcutEditor(value: caseBinding($rule.trigger, fallback: FlowGestureCore.KeyboardShortcut(), extract: { if case .keyboard(let value) = $0 { return value }; return nil }, embed: InputTrigger.keyboard))
        case .touch:
            TouchTriggerEditor(value: caseBinding($rule.trigger, fallback: TouchGestureTrigger(), extract: { if case .touch(let value) = $0 { return value }; return nil }, embed: InputTrigger.touch))
        case .screenCorner:
            CornerTriggerEditor(value: caseBinding($rule.trigger, fallback: ScreenCornerTrigger(), extract: { if case .screenCorner(let value) = $0 { return value }; return nil }, embed: InputTrigger.screenCorner))
        }
    }
}

private enum TriggerKind: String, CaseIterable, Identifiable {
    case mouse = "Mouse button", draw = "Draw gesture", keyboard = "Keyboard shortcut", touch = "Touch gesture", corner = "Screen corner"
    var id: String { rawValue }
    init(_ trigger: InputTrigger) {
        switch trigger {
        case .mouseButton: self = .mouse
        case .draw: self = .draw
        case .keyboard: self = .keyboard
        case .touch: self = .touch
        case .screenCorner: self = .corner
        }
    }
    var initial: InputTrigger {
        switch self {
        case .mouse: return .mouseButton(MouseButtonTrigger())
        case .draw: return .draw(DrawGestureTrigger())
        case .keyboard: return .keyboard(FlowGestureCore.KeyboardShortcut(keyCode: 0, modifiers: [.command, .shift]))
        case .touch: return .touch(TouchGestureTrigger())
        case .corner: return .screenCorner(ScreenCornerTrigger())
        }
    }
}

private func caseBinding<Root, Value>(_ root: Binding<Root>, fallback: Value, extract: @escaping (Root) -> Value?, embed: @escaping (Value) -> Root) -> Binding<Value> {
    Binding(get: { extract(root.wrappedValue) ?? fallback }, set: { root.wrappedValue = embed($0) })
}

private struct ModifiersEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var value: ModifierKeys
    private let keys: [(ModifierKeys, String)] = [(.command, "⌘"), (.option, "⌥"), (.control, "⌃"), (.shift, "⇧"), (.function, "fn")]
    var body: some View {
        HStack {
            Text(model.t("Modifiers"))
            Spacer()
            ForEach(keys.indices, id: \.self) { index in
                let key = keys[index]
                Toggle(key.1, isOn: Binding(get: { value.contains(key.0) }, set: { if $0 { value.insert(key.0) } else { value.remove(key.0) } }))
                    .toggleStyle(.button).frame(minWidth: 38)
            }
        }
    }
}

private struct MouseTriggerEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var value: MouseButtonTrigger
    var body: some View {
        Picker(model.t("Button"), selection: $value.button) {
            ForEach(MouseButton.allCases, id: \.self) { Text(model.t(L10n.mouse($0))).tag($0) }
        }
        Stepper("\(model.t("Clicks")): \(value.clickCount)", value: $value.clickCount, in: 1...3)
        ModifiersEditor(value: $value.modifiers)
    }
}

private struct DrawTriggerEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var value: DrawGestureTrigger
    var body: some View {
        Picker(model.t("Button"), selection: $value.button) {
            ForEach(MouseButton.allCases, id: \.self) { Text(model.t(L10n.mouse($0))).tag($0) }
        }
        ModifiersEditor(value: $value.modifiers)
        VStack(alignment: .leading, spacing: 10) {
            Text(model.t("Direction sequence"))
            Text(value.directions.map(L10n.arrow).joined(separator: "  "))
                .font(.system(size: 30, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                .padding(.horizontal, 12).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            HStack {
                ForEach(GestureDirection.allCases, id: \.self) { direction in
                    Button(L10n.arrow(direction)) { value.directions.append(direction) }
                        .help(model.t(L10n.direction(direction))).disabled(value.directions.count >= 12)
                }
                Spacer()
                Button(model.t("Clear")) { value.directions.removeAll() }
            }
            Text(model.t("Hold the selected mouse button and draw the directions in order.")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ShortcutEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var value: FlowGestureCore.KeyboardShortcut
    @State private var monitor: Any?
    @State private var recording = false
    @State private var recorderID = UUID()
    var body: some View {
        HStack {
            TextField(model.t("Key code"), value: Binding(get: { Int(value.keyCode) }, set: { value.keyCode = UInt16(clamping: $0) }), format: .number)
                .frame(maxWidth: 200)
            Spacer()
            Button(model.t(recording ? "Recording… press a key" : "Record shortcut")) { recording ? stopRecording() : startRecording() }
        }
        ModifiersEditor(value: $value.modifiers)
        Text(model.t("Key codes are macOS virtual key codes. Use Record shortcut to capture the key and modifiers.")).font(.caption).foregroundStyle(.secondary)
            .onDisappear { stopRecording() }
            .onChange(of: model.activeShortcutRecorder) { if $0 != recorderID && recording { stopRecording() } }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stopRecording() }
    }
    private func startRecording() {
        stopRecording()
        recording = true
        model.beginShortcutRecording(id: recorderID)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode != 53 || !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                var modifiers: ModifierKeys = []
                if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
                if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
                if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
                if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
                if event.modifierFlags.contains(.function) { modifiers.insert(.function) }
                value = FlowGestureCore.KeyboardShortcut(keyCode: event.keyCode, modifiers: modifiers)
            }
            stopRecording()
            return nil
        }
    }
    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { model.endShortcutRecording(id: recorderID) }
        recording = false
    }
}

private struct TouchTriggerEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var value: TouchGestureTrigger
    private var kind: String {
        switch value.gesture { case .tap: return "Tap"; case .swipe: return "Swipe"; case .pinch: return "Pinch" }
    }
    private var fingers: Binding<Int> {
        Binding(get: { switch value.gesture { case .tap(let count), .swipe(let count, _): return count; case .pinch: return 2 } }, set: { count in
            if case .swipe(_, let direction) = value.gesture { value.gesture = .swipe(fingers: count, direction: direction) }
            else { value.gesture = .tap(fingers: count) }
        })
    }
    var body: some View {
        Picker(model.t("Gesture"), selection: Binding(get: { kind }, set: {
            switch $0 { case "Swipe": value.gesture = .swipe(fingers: 3, direction: .left); case "Pinch": value.gesture = .pinch(.inward); default: value.gesture = .tap(fingers: 3) }
        })) { ForEach(["Tap", "Swipe", "Pinch"], id: \.self) { Text(model.t($0)).tag($0) } }
        if kind != "Pinch" { Stepper("\(model.t("Fingers")): \(fingers.wrappedValue)", value: fingers, in: 1...5) }
        if case .swipe = value.gesture {
            Picker(model.t("Direction"), selection: Binding(get: { if case .swipe(_, let direction) = value.gesture { return direction }; return .left }, set: { value.gesture = .swipe(fingers: fingers.wrappedValue, direction: $0) })) {
                ForEach(GestureDirection.allCases, id: \.self) { Text(model.t(L10n.direction($0))).tag($0) }
            }
        }
        if case .pinch = value.gesture {
            Picker(model.t("Direction"), selection: Binding(get: { if case .pinch(let direction) = value.gesture { return direction }; return .inward }, set: { value.gesture = .pinch($0) })) {
                Text(model.t("Inward")).tag(PinchDirection.inward)
                Text(model.t("Outward")).tag(PinchDirection.outward)
            }
        }
        ModifiersEditor(value: $value.modifiers)
        Text(model.t("Touch support depends on the connected device and macOS. Check Diagnostics for the actual backend status.")).font(.caption).foregroundStyle(.secondary)
    }
}

private struct CornerTriggerEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var value: ScreenCornerTrigger
    var body: some View {
        Picker(model.t("Corner"), selection: $value.corner) {
            ForEach(ScreenCorner.allCases, id: \.self) { Text(model.t(L10n.corner($0))).tag($0) }
        }
        ModifiersEditor(value: $value.modifiers)
        Text(model.t("Move the pointer into the selected screen corner. Add modifiers to avoid accidental triggers.")).font(.caption).foregroundStyle(.secondary)
    }
}

struct BundleIdentifiersEditor: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    @Binding var identifiers: Set<String>
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.t(title))
            TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(height: 76)
                .padding(6).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            HStack {
                Text(model.t("Bundle identifiers, one per line")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.t("Choose application…")) {
                    if let app = model.chooseApplication() {
                        identifiers.insert(app)
                        text = identifiers.sorted().joined(separator: "\n")
                    }
                }
            }
        }
        .onAppear { text = identifiers.sorted().joined(separator: "\n") }
        .onChange(of: text) { updated in
            let parsed = Set(updated.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            if identifiers != parsed { identifiers = parsed }
        }
        .onChange(of: identifiers) { updated in
            let parsed = Set(text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            if parsed != updated { text = updated.sorted().joined(separator: "\n") }
        }
    }
}

private struct ApplicationScopeEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var scope: AppScope
    var body: some View {
        BundleIdentifiersEditor(title: "Only these applications", identifiers: $scope.bundleIdentifiers)
        Text(model.t("Leave the inclusion list empty to apply to all applications.")).font(.caption).foregroundStyle(.secondary)
        BundleIdentifiersEditor(title: "Excluded applications", identifiers: $scope.excludedBundleIdentifiers)
    }
}

private enum ActionKind: String, CaseIterable, Identifiable {
    case shortcut = "Keyboard shortcut", url = "Open URL", application = "Open application", path = "Open file or folder"
    case script = "AppleScript", menu = "Menu item", window = "Window", frame = "Custom window frame", system = "System"
    var id: String { rawValue }
    init(_ value: Action) {
        switch value {
        case .shortcut: self = .shortcut
        case .openURL: self = .url
        case .openApplication: self = .application
        case .openPath: self = .path
        case .appleScript: self = .script
        case .menuItem: self = .menu
        case .window: self = .window
        case .windowFrame: self = .frame
        case .system: self = .system
        }
    }
    var initial: Action {
        switch self {
        case .shortcut: return .shortcut(FlowGestureCore.KeyboardShortcut(keyCode: 8, modifiers: .command))
        case .url: return .openURL("https://")
        case .application: return .openApplication("com.apple.finder")
        case .path: return .openPath(NSHomeDirectory())
        case .script: return .appleScript("")
        case .menu: return .menuItem(["File", "New Window"])
        case .window: return .window(.maximize)
        case .frame: return .windowFrame(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        case .system: return .system(.missionControl)
        }
    }
}

private struct ActionEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var action: Action
    var body: some View {
        Picker(model.t("Action"), selection: Binding(get: { ActionKind(action) }, set: { action = $0.initial })) {
            ForEach(ActionKind.allCases) { Text(model.t($0.rawValue)).tag($0) }
        }
        switch action {
        case .shortcut:
            ShortcutEditor(value: caseBinding($action, fallback: FlowGestureCore.KeyboardShortcut(), extract: { if case .shortcut(let value) = $0 { return value }; return nil }, embed: Action.shortcut))
        case .openURL:
            TextField(model.t("URL"), text: stringBinding)
        case .openApplication:
            HStack {
                TextField(model.t("Application path or bundle ID"), text: stringBinding)
                Button(model.t("Choose application…")) { if let app = model.chooseApplication() { action = .openApplication(app) } }
            }
        case .openPath:
            HStack {
                TextField(model.t("File or folder path"), text: stringBinding)
                Button(model.t("Choose…")) {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true
                    if panel.runModal() == .OK, let url = panel.url { action = .openPath(url.path) }
                }
            }
        case .appleScript:
            TextEditor(text: stringBinding).font(.system(.body, design: .monospaced)).frame(minHeight: 110)
            Text(model.t("Scripts execute with your user permissions. Review imported scripts before enabling rules.")).font(.caption).foregroundStyle(.orange)
        case .menuItem:
            TextField(model.t("Menu path, separated by >"), text: stringBinding)
        case .window:
            Picker(model.t("Window"), selection: caseBinding($action, fallback: WindowAction.maximize, extract: { if case .window(let value) = $0 { return value }; return nil }, embed: Action.window)) {
                ForEach(WindowAction.allCases, id: \.self) { Text(model.t(L10n.window($0))).tag($0) }
            }
        case .windowFrame:
            HStack {
                ForEach(["X", "Y", "Width", "Height"], id: \.self) { key in
                    TextField(model.t(key), value: frameBinding(key), format: .number.precision(.fractionLength(2)))
                }
            }
            Text(model.t("Normalized screen coordinates (0–1); Y starts at the bottom.")).font(.caption).foregroundStyle(.secondary)
        case .system:
            Picker(model.t("System"), selection: caseBinding($action, fallback: SystemAction.missionControl, extract: { if case .system(let value) = $0 { return value }; return nil }, embed: Action.system)) {
                ForEach(SystemAction.allCases, id: \.self) { Text(model.t(L10n.system($0))).tag($0) }
            }
        }
    }
    private var stringBinding: Binding<String> {
        Binding(get: {
            switch action {
            case .openURL(let value), .openApplication(let value), .openPath(let value), .appleScript(let value): return value
            case .menuItem(let path): return path.joined(separator: " > ")
            default: return ""
            }
        }, set: { text in
            switch action {
            case .openURL: action = .openURL(text)
            case .openApplication: action = .openApplication(text)
            case .openPath: action = .openPath(text)
            case .appleScript: action = .appleScript(text)
            case .menuItem: action = .menuItem(text.components(separatedBy: ">").map { $0.trimmingCharacters(in: .whitespaces) })
            default: break
            }
        })
    }
    private func frameBinding(_ key: String) -> Binding<Double> {
        Binding(get: {
            guard case let .windowFrame(x, y, width, height) = action else { return 0 }
            return ["X": x, "Y": y, "Width": width, "Height": height][key] ?? 0
        }, set: { value in
            guard case let .windowFrame(x, y, width, height) = action else { return }
            action = .windowFrame(x: key == "X" ? value : x, y: key == "Y" ? value : y, width: key == "Width" ? value : width, height: key == "Height" ? value : height)
        })
    }
}
