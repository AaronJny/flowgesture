import Foundation

struct CaptureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum CaptureScenario: String, CaseIterable, Codable {
    case unspecified, baseline
    case spacesLeftThree = "spaces-left-3"
    case spacesRightThree = "spaces-right-3"
    case spacesLeftFour = "spaces-left-4"
    case spacesRightFour = "spaces-right-4"
    case missionControl = "mission-control"
    case appExpose = "app-expose"
    case pinch, scroll, taps
    case multipleDevices = "multiple-devices"
    case interruption
}

struct CaptureOptions {
    static let maximumDuration: Double = 60
    static let recordHardLimit = 10_000
    enum Mode: String, Codable { case capture, selfTest = "self-test" }
    let mode: Mode
    let duration: Double
    let output: String
    let maximumRecords: Int
    let scenario: CaptureScenario
    // A caller assertion, never represented as a verified binary-to-source mapping.
    let reportedRevision: String?

    static let usage = """
    FlowGestureCapture --capture --duration SECONDS --output NEW_FILE.json
      [--max-records 1...10000] [--scenario LABEL] [--revision 40_HEX_DIGITS]
    FlowGestureCapture --self-test --duration SECONDS --output NEW_FILE.json

    Duration must be 0.1...60 seconds. A new owner-only file is required; existing
    files and symlinks are never overwritten. The destination must be local,
    ownership-enforcing, and free of an extended ACL; unverifiable privacy fails
    before capture and may leave an empty file. Live capture requires pre-existing
    Input Monitoring access and an explicitly verified unlocked console session. No permission prompt,
    setting change, event posting, event consumption, action, or network upload.
    The all-events mask excludes known keyboard, mouse, and tablet input. Unknown
    classes (including 61/62) retain metadata only, never guessed phases. No keyboard text,
    mouse positions, screenshots, app/window names, hardware names, or serials.
    Touch normalized coordinates, numeric device identities, PID/tag and narrowly
    allowlisted gesture fields are recorded. Review the local file before sharing.
    PID zero and numeric identity matches do not prove physical provenance.
    Self-test uses in-memory fixtures only and does not open any capture device/tap.
    Revision is operator-reported and unverified; live reports also hash the binary.
    Labels: unspecified, baseline, spaces-left-3, spaces-right-3, spaces-left-4,
      spaces-right-4, mission-control, app-expose, pinch, scroll, taps,
      multiple-devices, interruption.
    """

    static func parse(_ arguments: [String]) throws -> CaptureOptions {
        var mode: Mode?
        var values: [String: String] = [:]
        let valued = Set(["--duration", "--output", "--max-records", "--scenario", "--revision"])
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--capture" || argument == "--self-test" {
                guard mode == nil else { throw CaptureError("Choose exactly one mode, once.") }
                mode = argument == "--capture" ? .capture : .selfTest
            } else if valued.contains(argument) {
                guard values[argument] == nil, index + 1 < arguments.count,
                      !arguments[index + 1].hasPrefix("--") else {
                    throw CaptureError("Missing or repeated option value.")
                }
                index += 1
                values[argument] = arguments[index]
            } else {
                // Do not echo arbitrary values into diagnostics or the capture file.
                throw CaptureError("Unknown option. Use --help.")
            }
            index += 1
        }
        guard let mode,
              let durationText = values["--duration"], let duration = Double(durationText),
              duration.isFinite, (0.1...maximumDuration).contains(duration),
              let output = values["--output"], !output.isEmpty, !output.utf8.contains(0) else {
            throw CaptureError("Explicit mode, duration (0.1...60), and new output path are required.")
        }
        let maximumRecords = values["--max-records"].flatMap(Int.init) ?? (values["--max-records"] == nil ? 8192 : 0)
        guard (1...Self.recordHardLimit).contains(maximumRecords) else {
            throw CaptureError("Record limit must be 1...10000.")
        }
        guard let scenario = CaptureScenario(rawValue: values["--scenario"] ?? "unspecified") else {
            throw CaptureError("Scenario must be an allowlisted label from --help.")
        }
        if let revision = values["--revision"] {
            guard revision.count == 40, revision.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }) else { throw CaptureError("Revision must be a full 40-character hexadecimal commit ID.") }
        }
        return CaptureOptions(mode: mode, duration: duration, output: output,
                              maximumRecords: maximumRecords, scenario: scenario,
                              reportedRevision: values["--revision"]?.lowercased())
    }
}
