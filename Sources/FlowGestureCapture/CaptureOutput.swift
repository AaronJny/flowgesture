import Foundation
#if os(macOS)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// O_EXCL reserves the destination BEFORE any permission preflight or capture.
/// O_NOFOLLOW also rejects final-component symlinks. Before capture, the newly
/// created FD must pass owner/mode/filesystem/ACL checks. No permission is changed
/// to make it pass. There is no overwrite mode.
final class ExclusiveCaptureOutput {
    private var descriptor: Int32
    init(path: String) throws {
        descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            throw CaptureError("Cannot create a new owner-only output file (errno \(errno)). Nothing was captured.")
        }
        do {
            try Self.verifyPrivateEmptyFile(descriptor: descriptor)
        } catch {
            _ = close(descriptor)
            descriptor = -1
            // Deliberately leave only the empty newly created file. Never change
            // directory permissions or clear an inherited ACL to force success.
            throw error
        }
    }
    deinit { if descriptor >= 0 { _ = close(descriptor) } }

    /// This is a descriptor check, not a path lookup: replacements and symlinks
    /// cannot redirect validation away from the FD that will receive the report.
    static func verifyPrivateEmptyFile(descriptor: Int32) throws {
        let failure = CaptureError("Output privacy could not be verified (filesystem, owner, mode, or extended ACL); no report bytes were written.")
        var metadata = stat()
        #if os(macOS)
        var filesystem = statfs()
        guard fstatfs(descriptor, &filesystem) == 0,
              UInt64(filesystem.f_flags) & UInt64(MNT_LOCAL) != 0,
              UInt64(filesystem.f_flags) & UInt64(MNT_IGNORE_OWNERSHIP) == 0,
              fpathconf(descriptor, _PC_EXTENDED_SECURITY_NP) == 1,
              fpathconf(descriptor, _PC_AUTH_OPAQUE_NP) == 0,
              let security = filesec_init() else { throw failure }
        defer { filesec_free(security) }
        guard fstatx_np(descriptor, &metadata, security) == 0 else { throw failure }
        var aclPresent: Int32 = -1
        guard filesec_query_property(security, FILESEC_ACL, &aclPresent) == 0,
              aclPresent == 0 else { throw failure }
        // Source-backed Darwin contract, not Linux acl_get_entry conventions:
        // Libc 71bbe350ab79eef58113991d817ccc6165061a64 sys/statx_np.c +
        // gen/filesec.c: a fresh successful snapshot reports FILESEC_ACL presence.
        // XNU f6217f891ac0bb64f3d375211650a4c1ff8ca1ea bsd/vfs/kpi_vfs.c
        // vnode_getattr resolves a missing requested ACL through vnode_get_filesec
        // on an extended-security filesystem and propagates retrieval errors.
        // Require local, ownership-enforcing, nonopaque authorization above so
        // absent ACL plus owner/mode is meaningful. Any present ACL is rejected.
        // acl_get_fd_np nil/ENOENT and acl_get_entry -1/EINVAL are NOT used as a
        // stand-alone absence proof. No ACL-setting/deleting API is called.
        #else
        // Only synthetic self-test output exists on non-macOS. Linux POSIX ACL
        // access for named users/groups is constrained by these group mode bits.
        guard fstat(descriptor, &metadata) == 0 else { throw failure }
        #endif
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_uid == geteuid(), metadata.st_mode & mode_t(0o7777) == mode_t(0o600),
              metadata.st_nlink == 1, metadata.st_size == 0 else { throw failure }
    }

    func write(_ report: CaptureReport) throws {
        try Self.verifyPrivateEmptyFile(descriptor: descriptor)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < bytes.count {
                #if os(macOS)
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                #else
                let written = Glibc.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                #endif
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw CaptureError("Capture output write failed; the new file may be incomplete.") }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw CaptureError("Capture output could not be synchronized; the new file may be incomplete.") }
        let result = close(descriptor)
        descriptor = -1
        guard result == 0 else { throw CaptureError("Capture output close failed; the new file may be incomplete.") }
    }
}
