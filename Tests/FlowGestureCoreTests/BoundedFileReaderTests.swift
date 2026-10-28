import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import FlowGestureCore

final class BoundedFileReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FlowGestureReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testRegularFileAndExactSizeLimitRoundTrip() throws {
        let content = Data((0..<150_000).map { UInt8($0 % 251) })
        let file = directory.appendingPathComponent("rules.json")
        try content.write(to: file)
        XCTAssertEqual(try BoundedFileReader.read(at: file, maximumBytes: content.count), content)
    }

    func testEmptyFileAllowedWithZeroLimit() throws {
        let file = directory.appendingPathComponent("empty")
        try Data().write(to: file)
        XCTAssertEqual(try BoundedFileReader.read(at: file, maximumBytes: 0), Data())
    }

    func testOversizedFileRejected() throws {
        let file = directory.appendingPathComponent("large")
        try Data(repeating: 1, count: 1_025).write(to: file)
        XCTAssertThrowsError(try BoundedFileReader.read(at: file, maximumBytes: 1_024)) {
            XCTAssertEqual($0 as? BoundedFileReadError, .tooLarge(maximumBytes: 1_024))
        }
        XCTAssertThrowsError(try BoundedFileReader.read(at: file, maximumBytes: 0))
    }

    func testDirectoryRejectedUsingOpenedDescriptor() {
        XCTAssertThrowsError(try BoundedFileReader.read(at: directory)) {
            XCTAssertEqual($0 as? BoundedFileReadError, .notRegularFile)
        }
    }

    func testSymbolicLinkIsNotFollowed() throws {
        let file = directory.appendingPathComponent("regular")
        let link = directory.appendingPathComponent("link")
        try Data("safe".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try BoundedFileReader.read(at: link)) {
            XCTAssertEqual($0 as? BoundedFileReadError, .symbolicLinkNotAllowed)
        }
    }

    func testFIFOWithoutWriterRejectsWithoutBlocking() throws {
        let fifo = directory.appendingPathComponent("fifo")
        let result = fifo.path.withCString { mkfifo($0, mode_t(0o600)) }
        XCTAssertEqual(result, 0)
        guard result == 0 else { return }
        // No writer is ever opened: a blocking O_RDONLY open would hang here.
        XCTAssertThrowsError(try BoundedFileReader.read(at: fifo)) {
            XCTAssertEqual($0 as? BoundedFileReadError, .notRegularFile)
        }
    }

    func testRemoteURLsAndInvalidLimitsRejectBeforeOpening() {
        for url in [URL(string: "https://example.com/rules.json")!, URL(string: "file://remote.example/rules.json")!] {
            XCTAssertThrowsError(try BoundedFileReader.read(at: url)) {
                XCTAssertEqual($0 as? BoundedFileReadError, .nonLocalFileURL)
            }
        }
        for limit in [-1, Int.max] {
            XCTAssertThrowsError(try BoundedFileReader.read(at: directory, maximumBytes: limit)) {
                XCTAssertEqual($0 as? BoundedFileReadError, .invalidMaximumBytes)
            }
        }
    }

    func testMissingFileThrowsOpenError() {
        XCTAssertThrowsError(try BoundedFileReader.read(at: directory.appendingPathComponent("missing"))) {
            XCTAssertEqual($0 as? BoundedFileReadError, .systemError(operation: "open", code: ENOENT))
        }
    }
}
