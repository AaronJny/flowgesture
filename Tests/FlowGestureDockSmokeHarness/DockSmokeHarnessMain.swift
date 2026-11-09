import AppKit
import Darwin
import Foundation

/// Test-support executable only. Not included in FlowGesture.app, capture tool,
/// DMG, or any production routing. NSApplication owns its real event loop.
@main
struct DockSmokeHarnessMain {
    @MainActor static func main() {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["FLOWGESTURE_DOCK_SMOKE_REPORT"] ?? "build/dock-smoke/report.json"
        let smoke = SyntheticDockConsumerSmoke()
        if let reason = DockSmokeFixture.admissionReason(environment: environment,
            majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion) {
            smoke.recordAdmissionFailure(reason)
            do { try smoke.writeReport(to: path) }
            catch { fputs("FAIL: unable to write blocked Dock smoke report: \(error)\n", stderr) }
            fputs("REFUSED: \(reason)\n", stderr)
            exit(2)
        }
        let app = NSApplication.shared
        let delegate = DockSmokeHarnessDelegate(smoke: smoke, reportPath: path)
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
        // The harness exits from its asynchronous completion, never by a user
        // window closing while another synthetic sequence might be scheduled.
        fputs("FAIL: application event loop stopped without a completed report\n", stderr)
        exit(1)
    }
}

@MainActor
private final class DockSmokeHarnessDelegate: NSObject, NSApplicationDelegate {
    private let smoke: SyntheticDockConsumerSmoke
    private let reportPath: String
    init(smoke: SyntheticDockConsumerSmoke, reportPath: String) {
        self.smoke = smoke
        self.reportPath = reportPath
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        smoke.applicationDidFinishLaunching()
        Task { @MainActor in
            var result: Int32 = 0
            do {
                try await smoke.run()
                print("PASS: synthetic Dock consumer fixture; no physical suppression or raw/native correlation claim")
            } catch {
                fputs("FAIL: synthetic Dock smoke: \(error)\n", stderr)
                result = 1
            }
            do { try smoke.writeReport(to: reportPath) }
            catch {
                fputs("FAIL: unable to write Dock smoke report: \(error)\n", stderr)
                result = 1
            }
            // A failed unsettled transition is never force-closed/repaired. The
            // dedicated process ends and its disposable hosted session is retired.
            exit(result)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
