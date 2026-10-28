import AppKit
import ApplicationServices
import Combine
import SwiftUI
import Darwin

@main
@MainActor
struct FlowGestureApp: App {
    @NSApplicationDelegateAdaptor(FlowGestureAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            FlowGestureMenu(showSettings: appDelegate.showSettings).environmentObject(appDelegate.runtime.model)
        } label: {
            FlowGestureMenuIcon().environmentObject(appDelegate.runtime.model)
        }

    }
}

private struct FlowGestureMenuIcon: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Image(nsImage: Self.icon).opacity(model.isEnabled ? 1 : 0.55)
    }
    private static let icon: NSImage = {
        let image = Bundle.main.url(forResource: "MenuBarTemplate", withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) } ?? NSImage(systemSymbolName: "cursorarrow.motionlines", accessibilityDescription: "FlowGesture")!
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}

private struct FlowGestureMenu: View {
    @EnvironmentObject private var model: AppModel
    let showSettings: () -> Void
    var body: some View {
        Text("FlowGesture")
        Text(model.t(model.engineStatus))
        Divider()
        Toggle(model.t("Enable FlowGesture"), isOn: $model.isEnabled).disabled(model.configurationLoadError != nil)
        Button(model.t("FlowGesture Settings…")) {
            showSettings()
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
        engine.onDiagnosticStatus = { [weak model] in model?.gestureDiagnosticStatus = $0 }
        model.onStartGestureDiagnostics = { [weak self] in self?.engine.startGestureDiagnostics() }
        model.onStopGestureDiagnostics = { [weak self] in self?.engine.stopGestureDiagnostics() }
        model.gestureDiagnosticData = { [weak self] in try self?.engine.gestureDiagnosticData() ?? Data() }
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

@MainActor
private final class FlowGestureAppDelegate: NSObject, NSApplicationDelegate {
    let runtime = FlowGestureRuntime()
    private var settingsController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        showSettings()
        if ProcessInfo.processInfo.arguments.contains("--ui-smoke-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.checkVisibleWindowThenReopen() }
        }
    }

    func showSettings() {
        if settingsController == nil {
            let content = NSHostingController(rootView: SettingsView().environmentObject(runtime.model))
            let window = NSWindow(contentViewController: content)
            window.title = "FlowGesture"
            window.identifier = NSUserInterfaceItemIdentifier("FlowGesture.settings")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 980, height: 740))
            window.minSize = NSSize(width: 880, height: 640)
            window.isReleasedWhenClosed = false
            window.center()
            settingsController = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsController?.showWindow(nil)
        settingsController?.window?.deminiaturize(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
        settingsController?.window?.orderFrontRegardless()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Opt-in CI entrypoint exercises the production launch/reopen path. It never
    // grants input permissions or executes an input rule. WindowServer evidence
    // tests a real rendered window, not just a living background process.
    private func windowIsOnScreen() -> Bool {
        guard let window = settingsController?.window, window.isVisible,
              !window.isMiniaturized, window.contentView != nil else { return false }
        let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return entries.contains {
            ($0[kCGWindowOwnerPID as String] as? Int) == Int(getpid()) &&
            ($0[kCGWindowNumber as String] as? Int) == window.windowNumber
        }
    }
    private func checkVisibleWindowThenReopen() {
        guard windowIsOnScreen(), let window = settingsController?.window else {
            fputs("FAIL: launch did not present a settings window on screen\n", stderr); exit(1)
        }
        window.close()
        guard !window.isVisible else {
            fputs("FAIL: settings window did not close\n", stderr); exit(1)
        }
        _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard self.windowIsOnScreen(), self.settingsController?.window === window else {
                fputs("FAIL: reopen did not restore the same settings window\n", stderr); exit(1)
            }
            print("PASS: settings window visible in WindowServer at launch and after close/reopen")
            exit(0)
        }
    }
}
