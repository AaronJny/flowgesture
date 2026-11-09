#if os(macOS)
import Darwin
import Foundation
import XCTest
@testable import FlowGestureCapture

final class CaptureOutputPrivacyTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }

    func testInheritedExtendedACLIsRejectedBeforeAnyReportBytesAreWritten() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Only this freshly created, disposable directory is modified. No user
        // directory, existing user file, permission prompt, or security setting.
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone allow read,file_inherit", directory.path]
        try chmod.run()
        chmod.waitUntilExit()
        XCTAssertEqual(chmod.terminationStatus, 0, "Fixture requires macOS extended ACL inheritance")
        guard chmod.terminationStatus == 0 else { return }
        let path = directory.appendingPathComponent("capture.json").path
        XCTAssertThrowsError(try ExclusiveCaptureOutput(path: path)) { error in
            XCTAssertTrue((error as? CaptureError)?.description.contains("privacy") == true)
        }
        // The failed new destination may remain, but contains no report or input.
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let acl = try XCTUnwrap(acl_get_file(path, ACL_TYPE_EXTENDED))
        defer { acl_free(acl) }
        var first: acl_entry_t?
        // Darwin (unlike Linux) returns zero when an ACL entry is obtained.
        XCTAssertEqual(acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &first), 0)
        XCTAssertNotNil(first)
        XCTAssertThrowsError(try ExclusiveCaptureOutput(path: path)) // Still no overwrite.
    }

    func testUnverifiableDescriptorFailsClosed() {
        XCTAssertThrowsError(try ExclusiveCaptureOutput.verifyPrivateEmptyFile(descriptor: -1))
    }

    func testOutputPrivacyIsRecheckedImmediatelyBeforeWriting() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("capture.json").path
        let writer = try ExclusiveCaptureOutput(path: path)
        // Modify only our new empty fixture file, simulating a change while capture
        // runs. The writer must not trust its earlier mode/owner/ACL snapshot.
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path)
        let options = try CaptureOptions.parse(["--self-test", "--duration", "1", "--output", path])
        XCTAssertThrowsError(try writer.write(CaptureSelfTest.run(options: options)))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue, 0)
    }
}
#endif
