import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum BoundedFileReadError: Error, Equatable, Sendable {
    case nonLocalFileURL
    case invalidMaximumBytes
    case symbolicLinkNotAllowed
    case notRegularFile
    case tooLarge(maximumBytes: Int)
    case systemError(operation: String, code: Int32)
}

/// Reads untrusted local import files without blocking on a FIFO or allocating
/// from a racy path-based size check. All metadata and bytes use the same open FD.
public enum BoundedFileReader {
    public static func read(at url: URL, maximumBytes: Int = 8 * 1024 * 1024) throws -> Data {
        guard maximumBytes >= 0, maximumBytes < Int.max else { throw BoundedFileReadError.invalidMaximumBytes }
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.path.hasPrefix("/"), !url.path.utf8.contains(0) else {
            throw BoundedFileReadError.nonLocalFileURL
        }
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            let code = errno
            if code == ELOOP { throw BoundedFileReadError.symbolicLinkNotAllowed }
            throw BoundedFileReadError.systemError(operation: "open", code: code)
        }
        defer { _ = close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw BoundedFileReadError.systemError(operation: "fstat", code: errno)
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_size >= 0 else {
            throw BoundedFileReadError.notRegularFile
        }
        guard metadata.st_size <= off_t(maximumBytes) else {
            throw BoundedFileReadError.tooLarge(maximumBytes: maximumBytes)
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            // The extra byte detects growth beyond the limit after fstat. Neither
            // file metadata nor an untrusted writer can make this read unbounded.
            let requested = min(buffer.count, maximumBytes + 1 - data.count)
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                #if canImport(Darwin)
                return Darwin.read(descriptor, bytes.baseAddress!, requested)
                #else
                return Glibc.read(descriptor, bytes.baseAddress!, requested)
                #endif
            }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                throw BoundedFileReadError.systemError(operation: "read", code: code)
            }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumBytes else { throw BoundedFileReadError.tooLarge(maximumBytes: maximumBytes) }
        }
    }
}
