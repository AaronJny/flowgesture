import AppKit
import SwiftUI
import FlowGestureCore

private enum SettingsTab: String, CaseIterable, Identifiable {
    case rules = "Rules", scrolling = "Scrolling", settings = "Settings", diagnostics = "Diagnostics"
    var id: String { rawValue }
    var icon: String {
        switch self { case .rules: return "cursorarrow.motionlines"; case .scrolling: return "computermouse"; case .settings: return "gearshape"; case .diagnostics: return "waveform.path.ecg" }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab: SettingsTab? = .rules
    init(initialTab: String? = nil) { _tab = State(initialValue: initialTab.flatMap(SettingsTab.init(rawValue:)) ?? .rules) }
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: "cursorarrow.motionlines").font(.title).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("FlowGesture").font(.headline)
                        Text("macOS").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 18).padding(.top, 22)
                List(SettingsTab.allCases, selection: $tab) { item in
                    Label(model.t(item.rawValue), systemImage: item.icon).tag(item)
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(model.t("Enable FlowGesture"), isOn: $model.isEnabled).toggleStyle(.switch)
                        .disabled(model.configurationLoadError != nil)
                    Text(model.t(model.engineStatus)).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }.padding(16)
            }.navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if model.isEnabled && !model.engineRunning && (!model.accessibilityGranted || !model.inputMonitoringGranted) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(model.t("Permission needed — features are not running yet"), systemImage: "exclamationmark.triangle.fill").font(.headline)
                        Text(model.t("Your settings are saved. Allow Accessibility and Input Monitoring so FlowGesture can apply them.")).font(.callout)
                        HStack {
                            Button(model.t("Request permissions")) { model.onRequestPermissions?() }.buttonStyle(.borderedProminent)
                            Button(model.t("Open Accessibility settings")) { model.openPrivacySettings(accessibility: true) }
                            Button(model.t("Refresh status")) { model.onRefreshDiagnostics?() }
                        }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.16))
                }
                if let loadError = model.configurationLoadError {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(model.t("The configuration could not be loaded. The original file has been preserved; rules are paused until you restore a backup or import a valid file."), systemImage: "exclamationmark.triangle.fill")
                        Text(loadError).font(.caption).textSelection(.enabled)
                        HStack {
                            Button(model.t("Restore previous backup…")) { model.restoreBackup() }
                            Button(model.t("Import JSON…")) { model.importConfiguration() }
                            Button(model.t("Create empty configuration")) { model.startWithEmptyConfiguration() }
                        }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.14))
                }
                if let notice = model.notice {
                    HStack {
                        Text(notice).font(.callout)
                        Spacer()
                        Button { model.notice = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help(model.t("Dismiss"))
                    }.padding(12).background(.blue.opacity(0.1))
                }
                switch tab ?? .rules {
                case .rules: RulesPane().disabled(model.configurationLoadError != nil)
                case .scrolling: ScrollingPane().disabled(model.configurationLoadError != nil)
                case .settings: GeneralPane()
                case .diagnostics: DiagnosticsPane()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 880, minHeight: 640)
        .alert(model.t("Error"), isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button(model.t("Done")) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}

private struct RulesPane: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var editingRule: Rule?
    @State private var deletingRule: Rule?
    private var rules: [Rule] {
        model.book.rules.enumerated()
            .filter { search.isEmpty || $0.element.name.localizedCaseInsensitiveContains(search) || model.triggerTitle($0.element.trigger).localizedCaseInsensitiveContains(search) }
            .sorted {
                if $0.element.scope.isGlobal != $1.element.scope.isGlobal { return !$0.element.scope.isGlobal }
                if $0.element.priority != $1.element.priority { return $0.element.priority > $1.element.priority }
                return $0.offset < $1.offset
            }.map(\.element)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.t("Rules")).font(.largeTitle.bold())
                    Text("\(model.book.rules.filter(\.isEnabled).count) / \(model.book.rules.count) \(model.t("Enabled"))").foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.t("Add examples")) { model.addExampleRules() }
                Button { editingRule = Rule(name: model.t("New rule"), actions: [.shortcut(FlowGestureCore.KeyboardShortcut(keyCode: 8, modifiers: .command))]) } label: {
                    Label(model.t("Add rule"), systemImage: "plus")
                }.buttonStyle(.borderedProminent)
            }
            TextField(model.t("Search rules"), text: $search).textFieldStyle(.roundedBorder)
            if model.book.rules.isEmpty {
                Spacer()
                VStack(spacing: 14) {
                    Image(systemName: "cursorarrow.motionlines").font(.system(size: 54)).foregroundStyle(.blue)
                    Text(model.t("No rules yet")).font(.title2.bold())
                    Text(model.t("Create a trigger and choose what it does. Rules stay local unless you choose a sync folder."))
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                }.frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(rules) { rule in
                            HStack(spacing: 14) {
                                Toggle("", isOn: Binding(get: { model.book.rules.first(where: { $0.id == rule.id })?.isEnabled ?? false }, set: { model.setRuleEnabled(id: rule.id, enabled: $0) }))
                                    .toggleStyle(.switch).labelsHidden().help(model.t("Enabled"))
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(rule.name).font(.headline)
                                    Text(model.triggerTitle(rule.trigger) + "  →  " + rule.actions.map(model.actionTitle).joined(separator: ", "))
                                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                    Text(rule.scope.isGlobal ? model.t("Global") : rule.scope.bundleIdentifiers.sorted().joined(separator: ", "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Button(model.t("Edit rule")) { editingRule = rule }.buttonStyle(.borderless)
                                Menu {
                                    Button(model.t("Duplicate")) { model.duplicateRule(rule) }
                                    Button(model.t("Delete"), role: .destructive) { deletingRule = rule }
                                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22)
                            }.padding(16)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.12)))
                        }
                    }
                }
            }
        }.padding(26)
        .sheet(item: $editingRule) { rule in RuleEditor(rule: rule, onSave: model.saveRule).environmentObject(model) }
        .alert(model.t("Delete rule?"), isPresented: Binding(get: { deletingRule != nil }, set: { if !$0 { deletingRule = nil } })) {
            Button(model.t("Cancel"), role: .cancel) { deletingRule = nil }
            Button(model.t("Delete"), role: .destructive) {
                if let rule = deletingRule { model.deleteRule(id: rule.id) }
                deletingRule = nil
            }
        } message: { Text((deletingRule?.name ?? "") + "\n" + model.t("This cannot be undone.")) }
    }
}

private struct ScrollingPane: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Form {
            Section {
                Label(model.t(model.engineRunning ? "Scroll engine is running" : "Scroll engine is not running"),
                      systemImage: model.engineRunning ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.engineRunning ? Color.green : Color.orange)
                if !model.isEnabled {
                    Text(model.t("FlowGesture is paused. Enable it to apply scrolling changes."))
                    Button(model.t("Enable FlowGesture")) { model.isEnabled = true }
                } else if !model.engineRunning {
                    Text(model.t(model.engineStatus))
                    HStack {
                        Button(model.t("Request permissions")) { model.onRequestPermissions?() }
                        Button(model.t("Refresh status")) { model.onRefreshDiagnostics?() }
                    }
                }
                LabeledContent(model.t("Accessibility"), value: model.t(model.accessibilityGranted ? "Granted" : "Not granted"))
                LabeledContent(model.t("Input Monitoring"), value: model.t(model.inputMonitoringGranted ? "Granted" : "Not granted"))
                Text(model.t(model.scrollStatus)).font(.callout).foregroundStyle(.secondary)
                Text(model.t("You can test scrolling in this window. Mouse settings also apply here.")).font(.caption)
            } header: { Text(model.t("Status")) }

            Section {
                Toggle(model.t("Enable scroll adjustments"), isOn: $model.book.scroll.isEnabled)
            } header: { Text(model.t("Scrolling")).font(.title2.bold()) }
            Section {
                Toggle(model.t("Reverse vertical"), isOn: $model.book.scroll.reverseVertical)
                Toggle(model.t("Reverse horizontal"), isOn: $model.book.scroll.reverseHorizontal)
                speedSlider("Vertical speed", value: $model.book.scroll.verticalMultiplier)
                speedSlider("Horizontal speed", value: $model.book.scroll.horizontalMultiplier)
            }.disabled(!model.book.scroll.isEnabled)
            Section {
                Toggle(model.t("Smooth mouse wheel"), isOn: $model.book.scroll.smooth)
                HStack {
                    Text(model.t("Smoothing duration"))
                    Slider(value: $model.book.scroll.smoothingDuration, in: 0.03...0.5, step: 0.01)
                    Text("\(Int(model.book.scroll.smoothingDuration * 1000)) ms").monospacedDigit().frame(width: 64, alignment: .trailing)
                }.disabled(!model.book.scroll.smooth)
                Toggle(model.t("Also adjust trackpad / continuous scrolling"), isOn: $model.book.scroll.affectsContinuousScrolling)
                Text(model.t("Discrete mouse wheels are adjusted by default. Trackpad scrolling is left unchanged unless enabled above.")).font(.caption).foregroundStyle(.secondary)
            }.disabled(!model.book.scroll.isEnabled)
        }.formStyle(.grouped).padding(12)
    }
    private func speedSlider(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(model.t(label)).frame(width: 132, alignment: .leading)
            Slider(value: value, in: 0.1...10, step: 0.1)
            Text(String(format: "%.1f×", value.wrappedValue)).monospacedDigit().frame(width: 46, alignment: .trailing)
        }
    }
}

private struct GeneralPane: View {
    @EnvironmentObject private var model: AppModel
    @State private var exclusionDraft: Set<String> = []
    var body: some View {
        Form {
            Section(model.t("General")) {
                Picker(model.t("Language"), selection: $model.language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
            }
            Section(model.t("Configuration")) {
                HStack {
                    Button(model.t("Import JSON…")) { model.importConfiguration() }
                    Button(model.t("Export JSON…")) { model.exportConfiguration() }.disabled(model.configurationLoadError != nil)
                }
                HStack {
                    Button(model.t("Show configuration folder")) { model.showConfigurationFolder() }
                    Button(model.t("Restore previous backup…")) { model.restoreBackup() }
                }
            }
            Section(model.t("Sync folder")) {
                Text(model.syncFolder?.path ?? model.t("Not connected")).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Text(model.t(model.syncStatus)).font(.caption).foregroundStyle(model.hasSyncConflict ? Color.orange : Color.secondary)
                Text(model.t("Choose any folder, including a folder in iCloud Drive. Changes are synchronized while FlowGesture is running. Conflicts require your choice.")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(model.t("Choose sync folder…")) { model.chooseSyncFolder() }.disabled(model.configurationLoadError != nil)
                    if model.syncFolder != nil {
                        Button(model.t("Sync now")) { model.synchronize() }.disabled(model.hasSyncConflict)
                        Button(model.t("Disconnect")) { model.disconnectSync() }
                    }
                }
                if model.hasSyncConflict {
                    HStack {
                        Button(model.t("Keep local version")) { model.resolveSyncConflict(useShared: false) }
                        Button(model.t("Use shared version")) { model.resolveSyncConflict(useShared: true) }
                    }.disabled(model.configurationLoadError != nil)
                }
            }
            Section(model.t("Global exclusions")) {
                BundleIdentifiersEditor(title: "Excluded applications", identifiers: $exclusionDraft)
                Text(model.t("FlowGesture ignores these applications for every rule and scroll adjustment.")).font(.caption).foregroundStyle(.secondary)
                Button(model.t("Save")) { model.book.excludedBundleIdentifiers = exclusionDraft }
                    .disabled(exclusionDraft == model.book.excludedBundleIdentifiers || model.configurationLoadError != nil)
            }
        }.formStyle(.grouped).padding(12)
            .onAppear { exclusionDraft = model.book.excludedBundleIdentifiers }
            .onChange(of: model.book.excludedBundleIdentifiers) { exclusionDraft = $0 }
    }
}

private struct DiagnosticsPane: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Form {
            Section(model.t("Permissions")) {
                permissionRow("Accessibility", granted: model.accessibilityGranted)
                permissionRow("Input Monitoring", granted: model.inputMonitoringGranted)
                HStack {
                    Button(model.t("Request permissions")) { model.onRequestPermissions?() }.disabled(model.onRequestPermissions == nil)
                    Button(model.t("Refresh status")) { model.onRefreshDiagnostics?() }.disabled(model.onRefreshDiagnostics == nil)
                }
                Button(model.t("Open Accessibility settings")) { model.openPrivacySettings(accessibility: true) }
                Button(model.t("Open Input Monitoring settings")) { model.openPrivacySettings(accessibility: false) }
            }
            Section(model.t("Engine")) {
                LabeledContent(model.t("Engine"), value: model.t(model.engineStatus))
                LabeledContent(model.t("Last event"), value: model.t(model.lastEvent))
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.t("Touch backend")).font(.headline)
                    Text(model.t(model.touchBackendStatus)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    ForEach(model.touchDevices) { device in
                        let kind = device.kind == .trackpad ? "Trackpad" : device.kind == .mouse ? "Mouse touch surface" : "Unknown device"
                        Text("\(device.productName.isEmpty ? model.t("Unknown device") : device.productName) · \(model.t(kind)) · \(device.isStarted ? model.t("Running") : model.t("Not running"))")
                            .font(.caption).textSelection(.enabled)
                    }
                }
            }
            Section(model.t("Gesture diagnostics")) {
                Text(model.t("Record event types and touch counts in memory for up to 60 seconds. No keys, text or pointer paths are recorded. Events are never blocked."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.t(model.gestureDiagnosticStatus)).font(.callout).textSelection(.enabled)
                HStack {
                    Button(model.t("Start recording")) { model.onStartGestureDiagnostics?() }.disabled(!model.isEnabled)
                    Button(model.t("Stop recording")) { model.onStopGestureDiagnostics?() }
                    Button(model.t("Export local trace…")) { model.exportGestureDiagnostics() }
                }
            }
            Section(model.t("Configuration file")) {
                Text(model.configurationURL.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button(model.t("Show configuration folder")) { model.showConfigurationFolder() }
            }
        }.formStyle(.grouped).padding(12).onAppear { model.onRefreshDiagnostics?() }
    }
    private func permissionRow(_ title: String, granted: Bool) -> some View {
        HStack {
            Text(model.t(title))
            Spacer()
            Label(model.t(granted ? "Granted" : "Not granted"), systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? .green : .orange)
        }
    }
}
