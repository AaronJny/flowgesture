import Foundation
#if os(macOS)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
enum CaptureMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] || arguments == ["-h"] {
            print(CaptureOptions.usage)
            return
        }
        do {
            let options = try CaptureOptions.parse(arguments)
            let output = try ExclusiveCaptureOutput(path: options.output)
            let report: CaptureReport
            if options.mode == .selfTest {
                report = CaptureSelfTest.run(options: options)
            } else {
                #if os(macOS)
                FileHandle.standardError.write(Data("Passive capture only; no permission requests or event posting. Stop with Ctrl-C.\n".utf8))
                report = LiveCapture(options: options).run()
                #else
                let store = CaptureStore(options: options)
                store.finish(.unsupportedPlatform)
                report = store.report(environment: CaptureEnvironment(osVersion: "unsupported_platform", exactOSBuild: nil,
                                                                      architecture: "unknown", executableSHA256: nil,
                                                                      executableHashStatus: "unavailable", operatorReportedSourceRevision: options.reportedRevision,
                                                                      sourceRevisionVerification: "operator_reported_unverified"))
                #endif
            }
            try output.write(report)
            let message = "Local report written: \(report.stopReason); \(report.records.count) records. Physical provenance and native suppression remain unproven.\n"
            FileHandle.standardError.write(Data(message.utf8))
            if !report.failureReasons.isEmpty { exit(1) }
        } catch {
            // System/encoder errors are not persisted and no file paths or payloads
            // are emitted. Only our fixed, bounded error messages are surfaced.
            let message = (error as? CaptureError)?.description ?? "Capture export failed; the new file may be incomplete."
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(2)
        }
    }
}
