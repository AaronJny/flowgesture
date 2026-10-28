import AppKit
import SwiftUI
import FlowGestureCore

struct RuleEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var rule: Rule
    let onSave: (Rule) -> Bool
    @State private var advanced = false

    private var issues: [RuleValidationIssue] {
        var candidate = rule
        if candidate.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { candidate.name = "Mapping" }
        return RuleBook(rules: [candidate]).validationIssues()
    }
    private var firstAction: Binding<Action> {
        Binding(get: { rule.actions.first ?? .shortcut(FlowGestureCore.KeyboardShortcut(keyCode: 8, modifiers: .command)) }, set: {
            if rule.actions.isEmpty { rule.actions = [$0] } else { rule.actions[0] = $0 }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.mappingText("Button mapping", "按键映射")).font(.title2.bold())
                    Text(model.mappingText("Press a button. Choose what it does.", "按下一个键，再选择它要做什么。")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(model.t("Enabled"), isOn: $rule.isEnabled).toggleStyle(.switch)
            }.padding(.horizontal, 26).padding(.vertical, 18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        Text(MappingLabels.trigger(rule.trigger, model: model)).lineLimit(1)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(MappingLabels.action(rule.actions.first, model: model)).foregroundStyle(Color.accentColor).lineLimit(1)
                        if rule.actions.count > 1 { Text("+\(rule.actions.count - 1)").font(.subheadline).foregroundStyle(.secondary) }
                        Spacer(minLength: 0)
                    }.font(.title2.weight(.semibold)).padding(.horizontal, 4)
                    HStack(alignment: .top, spacing: 18) {
                        mappingCard(number: "1", title: model.mappingText("Which button?", "按哪个键？")) {
                            Picker(model.mappingText("Input", "输入方式"), selection: Binding(get: { TriggerKind(rule.trigger) }, set: {
                                if let recorder = model.activeShortcutRecorder { model.endShortcutRecording(id: recorder) }
                                rule.trigger = $0.initial
                            })) {
                                ForEach(TriggerKind.allCases) { Text(model.t($0.rawValue)).tag($0) }
                            }.accessibilityIdentifier("flowgesture.rule.trigger.kind")
                            Divider().padding(.vertical, 4)
                            triggerEditor
                        }
                        mappingCard(number: "2", title: model.mappingText("What should it do?", "执行什么？")) {
                            QuickActionEditor(action: firstAction)
                        }
                    }
                    CompactApplicationScopeEditor(scope: $rule.scope)
                        .padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    DisclosureGroup(isExpanded: $advanced) {
                        advancedEditor.padding(.top, 12)
                    } label: {
                        HStack {
                            Text(model.mappingText("Advanced", "高级设置")).font(.subheadline.weight(.medium))
                            Text(model.mappingText("Multi-click · modifiers · priority · more actions", "连击 · 修饰键 · 优先级 · 更多动作")).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.horizontal, 4)
                    if !issues.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                                Label(issue.message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }.padding(24)
            }.background(Color(nsColor: .windowBackgroundColor))
            Divider()
            HStack {
                Text(model.mappingText("Changes apply when you save.", "保存后生效。")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.t("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(model.t("Save")) {
                    if rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || rule.name == "New rule" || rule.name == "新规则" {
                        rule.name = MappingLabels.trigger(rule.trigger, model: model) + " → " + MappingLabels.action(rule.actions.first, model: model)
                    }
                    if onSave(rule) { dismiss() }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!issues.isEmpty || model.activeShortcutRecorder != nil)
                    .accessibilityIdentifier("flowgesture.rule.save")
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }.frame(minWidth: 900, idealWidth: 980, minHeight: 690, idealHeight: 740)
    }

    private func mappingCard<Content: View>(number: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Text(number).font(.caption.bold()).foregroundStyle(.white).frame(width: 24, height: 24).background(Color.accentColor, in: Circle())
                Text(title).font(.headline)
            }
            content()
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading).padding(18)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.12)))
    }

    @ViewBuilder private var advancedEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField(model.t("Name"), text: $rule.name)
            if case .mouseButton = rule.trigger {
                Stepper("\(model.t("Clicks")): \(mouseBinding.wrappedValue.clickCount)", value: mouseBinding.clickCount, in: 1...3)
            }
            ModifiersEditor(value: triggerModifiers)
            Stepper("\(model.t("Priority")): \(rule.priority)", value: $rule.priority, in: -1000...1000)
            Text(model.t("Application-specific rules run first, then higher priority, then saved order. Only the first match runs.")).font(.caption).foregroundStyle(.secondary)
            Divider()
            DisclosureGroup(model.mappingText("Full action options", "完整动作选项")) { ActionEditor(action: firstAction).padding(.vertical, 8) }
            ForEach(Array(rule.actions.indices.dropFirst()), id: \.self) { index in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("\(model.t("Action")) \(index + 1)").font(.headline)
                        Spacer()
                        Button { rule.actions.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }
                        Button { rule.actions.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }.disabled(index == rule.actions.count - 1)
                        Button(role: .destructive) { rule.actions.remove(at: index) } label: { Image(systemName: "trash") }
                    }
                    ActionEditor(action: Binding(get: { rule.actions.indices.contains(index) ? rule.actions[index] : .system(.missionControl) }, set: { if rule.actions.indices.contains(index) { rule.actions[index] = $0 } }))
                }.padding(12).background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            Button { rule.actions.append(.shortcut(FlowGestureCore.KeyboardShortcut(keyCode: 8, modifiers: .command))) } label: { Label(model.t("Add action"), systemImage: "plus") }
            Divider()
            DisclosureGroup(model.mappingText("Application IDs and exclusions", "应用标识符与排除列表")) { ApplicationScopeEditor(scope: $rule.scope).padding(.vertical, 8) }
        }.textFieldStyle(.roundedBorder)
    }
    private var mouseBinding: Binding<MouseButtonTrigger> {
        caseBinding($rule.trigger, fallback: MouseButtonTrigger(), extract: { if case .mouseButton(let value) = $0 { return value }; return nil }, embed: InputTrigger.mouseButton)
    }
    private var triggerModifiers: Binding<ModifierKeys> {
        Binding(get: {
            switch rule.trigger {
            case .mouseButton(let v): return v.modifiers
            case .draw(let v): return v.modifiers
            case .shape(let v): return v.modifiers
            case .keyboard(let v): return v.modifiers
            case .touch(let v): return v.modifiers
            case .screenCorner(let v): return v.modifiers
            }
        }, set: { modifiers in
            switch rule.trigger {
            case .mouseButton(var v): v.modifiers = modifiers; rule.trigger = .mouseButton(v)
            case .draw(var v): v.modifiers = modifiers; rule.trigger = .draw(v)
            case .shape(var v): v.modifiers = modifiers; rule.trigger = .shape(v)
            case .keyboard(var v): v.modifiers = modifiers; rule.trigger = .keyboard(v)
            case .touch(var v): v.modifiers = modifiers; rule.trigger = .touch(v)
            case .screenCorner(var v): v.modifiers = modifiers; rule.trigger = .screenCorner(v)
            }
        })
    }

    @ViewBuilder private var triggerEditor: some View {
        switch rule.trigger {
        case .mouseButton: MouseTriggerEditor(value: mouseBinding)
        case .draw: DrawTriggerEditor(value: caseBinding($rule.trigger, fallback: DrawGestureTrigger(), extract: { if case .draw(let value) = $0 { return value }; return nil }, embed: InputTrigger.draw))
        case .shape: ShapeTriggerEditor(value: caseBinding($rule.trigger, fallback: ShapeGestureTrigger(), extract: { if case .shape(let value) = $0 { return value }; return nil }, embed: InputTrigger.shape))
        case .keyboard: ShortcutEditor(value: caseBinding($rule.trigger, fallback: FlowGestureCore.KeyboardShortcut(), extract: { if case .keyboard(let value) = $0 { return value }; return nil }, embed: InputTrigger.keyboard))
        case .touch: TouchTriggerEditor(value: caseBinding($rule.trigger, fallback: TouchGestureTrigger(), extract: { if case .touch(let value) = $0 { return value }; return nil }, embed: InputTrigger.touch))
        case .screenCorner: CornerTriggerEditor(value: caseBinding($rule.trigger, fallback: ScreenCornerTrigger(), extract: { if case .screenCorner(let value) = $0 { return value }; return nil }, embed: InputTrigger.screenCorner))
        }
    }
}

private enum TriggerKind: String, CaseIterable, Identifiable {
    case mouse = "Mouse button", draw = "Draw gesture", shape = "Free-form shape", keyboard = "Keyboard shortcut", touch = "Touch gesture", corner = "Screen corner"
    var id: String { rawValue }
    init(_ trigger: InputTrigger) {
        switch trigger {
        case .mouseButton: self = .mouse
        case .draw: self = .draw
        case .shape: self = .shape
        case .keyboard: self = .keyboard
        case .touch: self = .touch
        case .screenCorner: self = .corner
        }
    }
    var initial: InputTrigger {
        switch self {
        case .mouse: return .mouseButton(MouseButtonTrigger())
        case .draw: return .draw(DrawGestureTrigger())
        case .shape: return .shape(ShapeGestureTrigger())
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
    @Binding var value: MouseButtonTrigger
    var body: some View { MouseButtonPicker(button: $value.button) }
}

/// One button selector for click, directional drawing, and free-form shapes.
/// This binding changes only the button, never the surrounding trigger payload.
private struct MouseButtonPicker: View {
    @EnvironmentObject private var model: AppModel
    @Binding var button: MouseButton
    var compact = false
    @State private var recording = false
    @State private var recorderID = UUID()
    @State private var feedback: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                if !compact { MouseButtonVisual(button: button) }
                VStack(alignment: .leading, spacing: compact ? 4 : 7) {
                    Text(MappingLabels.mouse(button, model: model)).font(compact ? .headline : .title3.bold())
                        .accessibilityIdentifier("flowgesture.mouse.button.selection")
                    if button.rawValue <= 2 {
                        Text(model.mappingText("Mouse button \(button.rawValue + 1)", "鼠标按钮 \(button.rawValue + 1)")).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(button == .middle ? model.mappingText("Press the wheel — not scrolling.", "按下滚轮，不是滚动滚轮。") : model.mappingText("Side-button positions vary. Record the actual button below.", "侧键位置因设备而异，请录制你实际按下的键。")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if recording {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(0.08))
                    Text(model.mappingText("Press your mouse button HERE", "在此区域按下要映射的鼠标键")).font(.callout.weight(.medium)).foregroundStyle(Color.accentColor).multilineTextAlignment(.center).padding(12)
                    MouseButtonCaptureSurface { number, _ in
                        // A late release from a replaced recorder must not edit the new mode.
                        guard recording, model.activeShortcutRecorder == recorderID else { stopRecording(); return }
                        if let captured = MouseButton(rawValue: number) {
                            button = captured
                            feedback = model.mappingText("Recorded actual button \(number + 1)", "已录制实际按钮 \(number + 1)")
                        } else { feedback = model.mappingText("Button \(number + 1) is not supported yet (1–8 supported).", "暂不支持按钮 \(number + 1)（目前支持 1–8）。") }
                        stopRecording()
                    }.accessibilityIdentifier("flowgesture.mouse.capture.surface")
                }.frame(height: 64).overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4])))
            }
            HStack {
                Button(recording ? model.mappingText("Cancel recording", "取消录制") : model.mappingText("Record mouse button", "录制鼠标按键")) {
                    if recording { stopRecording() }
                    else { recording = true; feedback = nil; model.beginShortcutRecording(id: recorderID) }
                }.buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("flowgesture.mouse.capture.start")
                Menu(model.mappingText("Choose manually", "手动选择")) {
                    ForEach(MouseButton.allCases, id: \.self) { candidate in
                        Button(MappingLabels.mouse(candidate, model: model)) { button = candidate; stopRecording() }
                    }
                }.fixedSize().accessibilityIdentifier("flowgesture.mouse.capture.manual")
            }
            if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("flowgesture.mouse.capture.feedback") }
        }
        .onDisappear { stopRecording() }
        .onChange(of: model.activeShortcutRecorder) { if $0 != recorderID && recording { stopRecording() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stopRecording() }
    }
    private func stopRecording() {
        if recording { model.endShortcutRecording(id: recorderID) }
        recording = false
    }
}

private struct DrawTriggerEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var value: DrawGestureTrigger
    var body: some View {
        MouseButtonPicker(button: $value.button, compact: true)
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

private struct ShapeTriggerEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var value: ShapeGestureTrigger
    @State private var recorderID = UUID()
    @State private var recording = false
    @State private var testing = false
    @State private var stroke: [GesturePoint] = []
    @State private var feedback: String?

    var body: some View {
        MouseButtonPicker(button: $value.button, compact: true)
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor))
                    Canvas { context, size in
                        let points = recording && !stroke.isEmpty ? stroke : previewPoints(in: size)
                        guard let first = points.first else { return }
                        var path = Path()
                        path.move(to: CGPoint(x: first.x, y: Double(size.height) - first.y))
                        for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: Double(size.height) - point.y)) }
                        context.stroke(path, with: .color(recording ? .orange : .accentColor), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        let start = CGRect(x: first.x - 5, y: Double(size.height) - first.y - 5, width: 10, height: 10)
                        context.fill(Path(ellipseIn: start), with: .color(.green))
                    }
                    if !recording && value.points.isEmpty {
                        Text(model.t("Record a shape, then draw one continuous stroke here.")).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                    }
                    if recording && stroke.isEmpty {
                        Text(model.t("Draw with the left mouse button inside this canvas.")).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center).padding()
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(recording ? Color.orange : Color.secondary.opacity(0.3), lineWidth: recording ? 2 : 1))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    guard recording else { return }
                    let point = GesturePoint(x: min(max(0, Double(event.location.x)), Double(geometry.size.width)),
                                             y: Double(geometry.size.height) - min(max(0, Double(event.location.y)), Double(geometry.size.height)))
                    if stroke.count < ShapeGestureRecognizer.maximumInputPoints { stroke.append(point) }
                    else { feedback = model.t("Stroke too long. Record a shorter shape."); stopRecording() }
                }.onEnded { _ in if recording { finishStroke() } })
            }.frame(height: 190)
            HStack {
                Button(model.t(recording ? "Cancel recording" : "Record shape")) {
                    if recording { stopRecording() } else { startRecording(test: false) }
                }
                Button(model.t("Test drawing")) { startRecording(test: true) }.disabled(value.points.isEmpty || recording)
                Button(model.t("Clear")) { stopRecording(); value.points = []; feedback = nil }.disabled(value.points.isEmpty && !recording)
                Spacer()
                Text("\(value.points.count) \(model.t("points"))").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(model.t("Minimum similarity"))
                Slider(value: Binding(get: { 1 - value.tolerance }, set: { value.tolerance = 1 - $0 }), in: 0.6...0.97, step: 0.01)
                Text("\(Int(((1 - value.tolerance) * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary) }
            Text(model.t("Size and position may vary. Keep the same orientation, starting point, and drawing direction. Green marks the start.")).font(.caption).foregroundStyle(.secondary)
        }
        .onDisappear { stopRecording() }
        .onChange(of: model.activeShortcutRecorder) { if $0 != recorderID && recording { stopRecording() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stopRecording() }
    }

    private func previewPoints(in size: CGSize) -> [GesturePoint] {
        let scale = max(1, min(Double(size.width), Double(size.height)) - 38)
        return ShapeGestureRecognizer.normalizedPath(value.points).map {
            GesturePoint(x: Double(size.width) / 2 + $0.x * scale, y: Double(size.height) / 2 + $0.y * scale)
        }
    }
    private func startRecording(test: Bool) {
        stopRecording()
        testing = test
        stroke = []
        feedback = nil
        recording = true
        model.beginShortcutRecording(id: recorderID)
    }
    private func stopRecording() {
        if recording { model.endShortcutRecording(id: recorderID) }
        recording = false
        stroke = []
    }
    private func finishStroke() {
        let candidate = stroke
        let wasTesting = testing
        stopRecording()
        guard let extent = ShapeGestureRecognizer.strokeExtent(candidate), extent >= 16,
              !ShapeGestureRecognizer.normalizedPath(candidate).isEmpty else {
            feedback = model.t("Draw a larger shape; clicks and tiny strokes are ignored.")
            return
        }
        if wasTesting {
            let score = ShapeGestureRecognizer().similarity(candidate, to: value.points) ?? 0
            let matched = ShapeGestureRecognizer().matches(candidate, template: value.points, tolerance: value.tolerance)
            feedback = "\(Int((score * 100).rounded()))% · \(model.t(matched ? "Matched" : "Not matched"))"
        } else {
            value.points = ShapeGestureRecognizer.normalizedPath(candidate)
            feedback = model.t("Shape recorded. Hold the selected trigger button to draw it outside this editor.")
        }
    }
}

private struct ShortcutEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var value: FlowGestureCore.KeyboardShortcut
    var showManualOptions = true
    @State private var captureSession: ShortcutCaptureSession?
    @State private var captureMessage: String?
    @State private var manualExpanded = ProcessInfo.processInfo.arguments.contains("--ui-review-manual-shortcut")
    @State private var recording = false
    @State private var recorderID = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(recording ? model.mappingText("Press your shortcut…", "请按下完整快捷键…") : MappingLabels.shortcut(value))
                .font(.system(size: recording ? 22 : 42, weight: .semibold, design: .rounded))
                .foregroundStyle(recording ? Color.accentColor : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 84)
                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            Button(recording ? model.mappingText("Cancel recording", "取消录制") : model.mappingText("Record keyboard shortcut", "录制完整快捷键")) {
                recording ? stopRecording() : startRecording()
            }.buttonStyle(.borderedProminent)
            Text(model.mappingText("Press all keys together, such as ⌘C. Esc cancels.", "一起按下完整组合，例如 ⌘C。Esc 取消。")).font(.caption).foregroundStyle(.secondary)
            if let captureMessage { Text(captureMessage).font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup(model.mappingText("Build shortcut manually", "手动组合快捷键"), isExpanded: $manualExpanded) {
                FriendlyShortcutBuilder(value: $value, showTechnicalCode: showManualOptions)
                    .padding(.top, 10)
            }.font(.callout)
            .onChange(of: value) { _ in
                // A manual edit supersedes a pending recorder instead of competing with it.
                if recording { stopRecording() }
            }
        }
        .onDisappear { stopRecording() }
        .onChange(of: model.activeShortcutRecorder) { if $0 != recorderID && recording { stopRecording() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stopRecording() }
    }
    private func startRecording() {
        stopRecording()
        let session = ShortcutCaptureSession()
        captureSession = session
        captureMessage = nil
        recording = true
        model.beginShortcutRecording(id: recorderID)
        let started = session.start(onCaptured: { shortcut in
            guard captureSession === session, model.activeShortcutRecorder == recorderID else { return }
            value = shortcut
            captureMessage = model.mappingText("Shortcut recorded", "快捷键已录制")
        }, onStatus: { status in
            guard captureSession === session else { return }
            let parts = status.components(separatedBy: " / ")
            captureMessage = model.mappingText(parts.first ?? status, parts.last ?? status)
        }, onFinished: {
            guard captureSession === session else { return }
            captureSession = nil
            recording = false
            model.endShortcutRecording(id: recorderID)
        })
        if !started { stopRecording() }
    }
    private func stopRecording() {
        let session = captureSession
        captureSession = nil
        session?.cancel()
        if recording { model.endShortcutRecording(id: recorderID) }
        recording = false
    }

}

/// A user-facing alternative when macOS reserves a shortcut before a local
/// event monitor can receive it. The selected modifier combination is preserved.
private struct FriendlyShortcutBuilder: View {
    @EnvironmentObject private var model: AppModel
    @Binding var value: FlowGestureCore.KeyboardShortcut
    let showTechnicalCode: Bool
    private let arrows: [(UInt16, String, String)] = [(123, "← Left", "← 左"), (124, "→ Right", "→ 右"), (126, "↑ Up", "↑ 上"), (125, "↓ Down", "↓ 下")]
    private let modifiers: [(ModifierKeys, String)] = [(.command, "Command ⌘"), (.control, "Control ⌃"), (.option, "Option ⌥"), (.shift, "Shift ⇧"), (.function, "Fn")]
    private var commonKeys: [UInt16] { [123, 124, 126, 125, 49, 48, 36, 53, 51, 117, 115, 119, 116, 121, 0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6, 29, 18, 19, 20, 21, 23, 22, 26, 28, 25, 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111] }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(arrows, id: \.0) { item in
                    Button(model.mappingText(item.1, item.2)) { cancelRecording(); value.keyCode = item.0 }
                        .buttonStyle(.bordered).tint(value.keyCode == item.0 ? Color.accentColor : Color.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 7) {
                ForEach(modifiers.indices, id: \.self) { index in
                    let item = modifiers[index]
                    Toggle(item.1, isOn: Binding(get: { value.modifiers.contains(item.0) }, set: { enabled in
                        cancelRecording()
                        if enabled { value.modifiers.insert(item.0) } else { value.modifiers.remove(item.0) }
                    })).toggleStyle(.button)
                }
            }
            Picker(model.mappingText("Key", "按键"), selection: Binding(get: { value.keyCode }, set: { cancelRecording(); value.keyCode = $0 })) {
                ForEach(commonKeys, id: \.self) { code in Text(MappingLabels.key(code)).tag(code) }
                if !commonKeys.contains(value.keyCode) {
                    Text(MappingLabels.key(value.keyCode)).tag(value.keyCode)
                }
            }
            Text(model.mappingText("Use your actual system shortcut. Command ⌘ and Control ⌃ are different; combine any modifiers you need.", "请选择你实际使用的系统组合。Command ⌘ 与 Control ⌃ 不同，可任意组合修饰键。")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if showTechnicalCode {
                DisclosureGroup(model.mappingText("Technical key code", "技术选项：键码")) {
                    TextField(model.t("Key code"), value: Binding(get: { Int(value.keyCode) }, set: { cancelRecording(); value.keyCode = UInt16(clamping: $0) }), format: .number).textFieldStyle(.roundedBorder)
                }.font(.caption)
            }
        }
    }
    private func cancelRecording() {
        if let recorder = model.activeShortcutRecorder { model.endShortcutRecording(id: recorder) }
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
        Picker(model.t("Touch device"), selection: $value.device) {
            Text(model.t("Any touch device")).tag(TouchDeviceScope.any)
            Text(model.t("Trackpad")).tag(TouchDeviceScope.trackpad)
            Text(model.t("Mouse touch surface")).tag(TouchDeviceScope.mouse)
        }
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
        Text(model.t("Touch support depends on the connected device and macOS. Check Diagnostics for the actual backend status.")).font(.caption).foregroundStyle(.secondary)
        Text(model.t("This build does not suppress macOS gestures. Disable an overlapping system gesture before testing the same custom gesture, otherwise both may run.")).font(.caption).foregroundStyle(.orange)
    }
}

private struct CornerTriggerEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var value: ScreenCornerTrigger
    var body: some View {
        Picker(model.t("Corner"), selection: $value.corner) {
            ForEach(ScreenCorner.allCases, id: \.self) { Text(model.t(L10n.corner($0))).tag($0) }
        }
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

private struct QuickActionEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var action: Action
    @State private var forceCustomShortcut = false
    private var preset: String {
        switch action {
        case .shortcut(let shortcut):
            if forceCustomShortcut { return "shortcut" }
            if shortcut.modifiers == .control {
                if shortcut.keyCode == 123 { return "previousDesktop" }
                if shortcut.keyCode == 124 { return "nextDesktop" }
            }
            if shortcut.modifiers == .command {
                switch shortcut.keyCode { case 8: return "copy"; case 9: return "paste"; case 33: return "back"; case 30: return "forward"; default: break }
            }
            return "shortcut"
        case .window(.toggleFullScreen): return "fullScreen"
        case .window: return "window"
        case .openApplication: return "app"
        default: return "more"
        }
    }
    var body: some View {
        Picker(model.mappingText("Behavior", "动作"), selection: Binding(get: { preset }, set: setPreset)) {
            Text(model.mappingText("Copy", "复制")).tag("copy")
            Text(model.mappingText("Paste", "粘贴")).tag("paste")
            Text(model.mappingText("Back", "后退")).tag("back")
            Text(model.mappingText("Forward", "前进")).tag("forward")
            Text(model.mappingText("Previous desktop (default ⌃←)", "上一桌面（默认 ⌃←）")).tag("previousDesktop")
            Text(model.mappingText("Next desktop (default ⌃→)", "下一桌面（默认 ⌃→）")).tag("nextDesktop")
            Text(model.mappingText("Keyboard shortcut", "自定义快捷键")).tag("shortcut")
            Text(model.mappingText("Toggle full screen", "切换全屏（进入/退出）")).tag("fullScreen")
            Text(model.mappingText("Move / resize window", "移动 / 调整窗口")).tag("window")
            Text(model.mappingText("Open an app", "打开应用")).tag("app")
            Text(model.mappingText("More actions…", "更多动作…")).tag("more")
        }
        Divider().padding(.vertical, 4)
        switch action {
        case .shortcut:
            ShortcutEditor(value: caseBinding($action, fallback: FlowGestureCore.KeyboardShortcut(keyCode: 8, modifiers: .command), extract: { if case .shortcut(let value) = $0 { return value }; return nil }, embed: Action.shortcut), showManualOptions: false)
            if preset == "previousDesktop" || preset == "nextDesktop" {
                Text(model.mappingText("If you customized desktop shortcuts in macOS, record or build that exact combination instead.", "如果你修改过 macOS 的桌面快捷键，请录制或手动组合你实际使用的按键。")).font(.caption).foregroundStyle(.secondary)
            }
        case .window(.toggleFullScreen):
            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 46)).foregroundStyle(Color.accentColor).frame(maxWidth: .infinity).padding(.vertical, 10)
            Text(model.mappingText("Toggle full screen", "切换全屏（进入/退出）")).font(.headline).frame(maxWidth: .infinity)
            Text(model.mappingText("Enter native macOS full screen; trigger again to exit. Maximize only resizes the window on the current desktop.", "进入 macOS 原生全屏，再触发一次即可退出。最大化仅在当前桌面调整窗口大小。")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .window:
            Image(systemName: "macwindow").font(.system(size: 46)).foregroundStyle(Color.accentColor).frame(maxWidth: .infinity).padding(.vertical, 10)
            Picker(model.t("Window"), selection: caseBinding($action, fallback: WindowAction.maximize, extract: { if case .window(let value) = $0 { return value }; return nil }, embed: Action.window)) {
                ForEach(WindowAction.allCases, id: \.self) { Text(model.t(L10n.window($0))).tag($0) }
            }
        case .openApplication(let identifier):
            Image(systemName: "app.badge").font(.system(size: 42)).foregroundStyle(Color.accentColor).frame(maxWidth: .infinity).padding(.vertical, 10)
            Text(appName(identifier)).font(.headline).frame(maxWidth: .infinity)
            Button(model.t("Choose application…")) { if let app = model.chooseApplication() { action = .openApplication(app) } }.buttonStyle(.borderedProminent)
        default: ActionEditor(action: $action)
        }
    }
    private func setPreset(_ value: String) {
        if let recorder = model.activeShortcutRecorder { model.endShortcutRecording(id: recorder) }
        forceCustomShortcut = value == "shortcut"
        switch value {
        case "shortcut":
            if case .shortcut = action {} else { action = .shortcut(FlowGestureCore.KeyboardShortcut(keyCode: 8, modifiers: .command)) }
        case "copy": action = .shortcut(FlowGestureCore.KeyboardShortcut(keyCode: 8, modifiers: .command))
        case "paste": action = .shortcut(FlowGestureCore.KeyboardShortcut(keyCode: 9, modifiers: .command))
        case "back": action = .shortcut(FlowGestureCore.KeyboardShortcut(keyCode: 33, modifiers: .command))
        case "forward": action = .shortcut(FlowGestureCore.KeyboardShortcut(keyCode: 30, modifiers: .command))
        case "previousDesktop": action = .shortcut(FlowGestureCore.KeyboardShortcut(keyCode: 123, modifiers: .control))
        case "nextDesktop": action = .shortcut(FlowGestureCore.KeyboardShortcut(keyCode: 124, modifiers: .control))
        case "fullScreen": action = .window(.toggleFullScreen)
        case "window": action = .window(.maximize)
        case "app": action = .openApplication("com.apple.finder")
        default: action = .system(.missionControl)
        }
    }
    private func appName(_ identifier: String) -> String {
        let url = identifier.hasPrefix("/") ? URL(fileURLWithPath: identifier) : NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        return url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? identifier
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
                    if let recorder = model.activeShortcutRecorder { model.endShortcutRecording(id: recorder) }
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
