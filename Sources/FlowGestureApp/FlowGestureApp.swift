import AppKit
import ApplicationServices
import Combine
import SwiftUI

@main
@MainActor
struct FlowGestureApp: App {
    @NSApplicationDelegateAdaptor(FlowGestureAppDelegate.self) private var appDelegate
    @StateObject private var runtime = FlowGestureRuntime()

    var body: some Scene {
        MenuBarExtra {
            FlowGestureMenu().environmentObject(runtime.model)
        } label: {
            Image(systemName: runtime.model.isEnabled ? "cursorarrow.motionlines" : "pause.circle")
        }
        Window("FlowGesture", id: "settings") {
            SettingsView().environmentObject(runtime.model)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 980, height: 740)
        .windowResizability(.contentMinSize)
    }
}

private struct FlowGestureMenu: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("FlowGesture")
        Text(model.t(model.engineStatus))
        Divider()
        Toggle(model.t("Enable FlowGesture"), isOn: $model.isEnabled).disabled(model.configurationLoadError != nil)
        Button(model.t("FlowGesture Settings…")) {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }.keyboardShortcut(",")
        Divider()
        Button(model.t("Quit FlowGesture")) { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

@MainActor
private final class FlowGestureRuntime: ObservableObject {
    let model = AppModel()
    private let engine = EventEngine()
    private var recording = false
    private var observers: [NSObjectProtocol] = []
    private var modelSubscription: Any?

    init() {
        // Relay nested model changes so the menu-bar icon updates as well as its content.
        modelSubscription = model.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        engine.onStatus = { [weak model] in model?.engineStatus = $0 }
        engine.onEvent = { [weak model] in model?.lastEvent = $0 }
        engine.onError = { [weak model] in model?.errorMessage = $0 }
        engine.onTouchStatus = { [weak model] in model?.touchBackendStatus = $0 }
        engine.onTouchDevices = { [weak model] in model?.touchDevices = $0 }
        model.onConfigurationChanged = { [weak self] in self?.engine.configure($0) }
        model.onEnabledChanged = { [weak self] enabled in
            guard let self else { return }
            if enabled && !self.recording { self.engine.start() } else { self.engine.stop() }
            self.refreshDiagnostics()
        }
        model.onInputCaptureChanged = { [weak self] capturing in
            guard let self else { return }
            self.recording = capturing
            if capturing { self.engine.stop() }
            else if self.model.isEnabled && self.model.configurationLoadError == nil { self.engine.start() }
        }
        model.onRequestPermissions = { [weak self] in
            self?.engine.requestAccessibility()
            _ = CGRequestListenEventAccess()
            self?.refreshDiagnostics()
        }
        model.onRefreshDiagnostics = { [weak self] in
            guard let self else { return }
            if self.model.isEnabled && self.model.configurationLoadError == nil && !self.recording { self.engine.start() }
            self.refreshDiagnostics()
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.model.onRefreshDiagnostics?() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.engine.stop() }
        })
        model.publishConfiguration()
    }

    private func refreshDiagnostics() {
        model.accessibilityGranted = AXIsProcessTrusted()
        model.inputMonitoringGranted = CGPreflightListenEventAccess()
        engine.refreshDiagnostics()
    }
}

private final class FlowGestureAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
