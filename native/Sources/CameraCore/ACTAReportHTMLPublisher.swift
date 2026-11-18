import CryptoKit
import Darwin
import Foundation

/// Isolated publisher, not an authorization boundary or a production GUI integration.
/// The trusted caller must ensure the descriptor is the operator-selected private
/// directory and prevent concurrent namespace/content writers for the entire use.
/// Mode/ACL checks do not exclude another process running as the same user.
final class ACTAReportHTMLPublisher {
    struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    struct Preview: Equatable {
        let directory: Identity
        let fileName: String
        let byteCount: Int
        let sha256: String
    }

    struct Receipt {
        let preview: Preview
        let file: Identity
    }

    enum Failure: Error, Equatable {
        case invalidContent
        case untrustedDestination
        case destinationExists
        case confirmationMismatch
        case declined
        case alreadyConsumed
        case publicationFailed
        case verificationFailed
    }

    private let directoryFD: Int32
    private let bytes: Data
    private let preview: Preview
    private let lock = NSLock()
    private var consumed = false
    private let beforeVerification: (Int32, Int32) -> Void

    /// `operatorSelected` must be supplied by trusted local UI code, never by
    /// model parameters. The descriptor, not a path, identifies the directory.
    static func prepare(
        html: Data, directoryFD: Int32, fileName: String, operatorSelected: Bool
    ) throws -> ACTAReportHTMLPublisher {
        try prepare(html: html, directoryFD: directoryFD, fileName: fileName,
                    operatorSelected: operatorSelected, beforeVerification: { _, _ in })
    }

    static func prepare(
        html: Data, directoryFD: Int32, fileName: String, operatorSelected: Bool,
        beforeVerification: @escaping (Int32, Int32) -> Void
    ) throws -> ACTAReportHTMLPublisher {
        guard !html.isEmpty, html.count <= 8 * 1024 * 1024,
              String(data: html, encoding: .utf8) != nil else { throw Failure.invalidContent }
        guard operatorSelected, validFileName(fileName) else { throw Failure.untrustedDestination }
        let fd = fcntl(directoryFD, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else { throw Failure.untrustedDestination }
        do {
            let identity = try trustedDirectory(fd)
            let bytes = Data([UInt8](html))
            let preview = Preview(
                directory: identity, fileName: fileName, byteCount: bytes.count,
                sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            )
            return ACTAReportHTMLPublisher(directoryFD: fd, bytes: bytes, preview: preview,
                                           beforeVerification: beforeVerification)
        } catch {
            close(fd)
            throw error
        }
    }

    private init(directoryFD: Int32, bytes: Data, preview: Preview,
                 beforeVerification: @escaping (Int32, Int32) -> Void) {
        self.directoryFD = directoryFD
        self.bytes = bytes
        self.preview = preview
        self.beforeVerification = beforeVerification
    }

    deinit { close(directoryFD) }

    var review: Preview { preview }

    /// An attempt consumes the snapshot. No failure unlinks or replaces a name;
    /// an incomplete file can remain. Verification is point-in-time, not a
    /// guarantee against later writes, renames, or loss after a crash.
    func publish(reviewed: Preview, approved: Bool) throws -> Receipt {
        lock.lock()
        defer { lock.unlock() }
        guard !consumed else { throw Failure.alreadyConsumed }
        consumed = true
        guard reviewed == preview else { throw Failure.confirmationMismatch }
        guard approved else { throw Failure.declined }
        guard try Self.trustedDirectory(directoryFD) == preview.directory else {
            throw Failure.untrustedDestination
        }
        let fd = preview.fileName.withCString {
            openat(directoryFD, $0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard fd >= 0 else {
            if errno == EEXIST { throw Failure.destinationExists }
            throw Failure.publicationFailed
        }
        defer { close(fd) }
        guard fchmod(fd, mode_t(0o600)) == 0 else { throw Failure.publicationFailed }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.publicationFailed }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw Failure.publicationFailed }
        beforeVerification(fd, directoryFD)
        let identity = try verify(fd)
        guard try Self.trustedDirectory(directoryFD) == preview.directory else {
            throw Failure.untrustedDestination
        }
        return Receipt(preview: preview, file: identity)
    }

    private func verify(_ fd: Int32) throws -> Identity {
        var before = stat()
        var named = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_uid == geteuid(), before.st_mode & 0o7777 == 0o600,
              before.st_nlink == 1, before.st_size == bytes.count,
              Self.noExtendedACL(fd),
              preview.fileName.withCString({ fstatat(directoryFD, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0,
              (named.st_mode & S_IFMT) == S_IFREG, Self.identity(before) == Self.identity(named) else {
            throw Failure.verificationFailed
        }
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, bytes.count))
        var offset = 0
        while offset < bytes.count {
            let count = min(buffer.count, bytes.count - offset)
            let readCount = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
            if readCount < 0 && errno == EINTR { continue }
            guard readCount > 0,
                  bytes[offset..<(offset + readCount)].elementsEqual(buffer.prefix(readCount)) else {
                throw Failure.verificationFailed
            }
            offset += readCount
        }
        var after = stat()
        var namedAfter = stat()
        guard fstat(fd, &after) == 0, after.st_nlink == 1, after.st_size == before.st_size,
              after.st_mode == before.st_mode, after.st_uid == before.st_uid,
              Self.identity(after) == Self.identity(before),
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec,
              preview.fileName.withCString({ fstatat(directoryFD, $0, &namedAfter, AT_SYMLINK_NOFOLLOW) }) == 0,
              (namedAfter.st_mode & S_IFMT) == S_IFREG, Self.identity(namedAfter) == Self.identity(after) else {
            throw Failure.verificationFailed
        }
        return Self.identity(after)
    }

    private static func validFileName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        return bytes.count <= 255 && !bytes.isEmpty && name.lowercased().hasSuffix(".html")
            && bytes.allSatisfy { (32...126).contains($0) && $0 != 47 && $0 != 92 }
    }

    private static func identity(_ info: stat) -> Identity {
        Identity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino))
    }

    private static func trustedDirectory(_ fd: Int32) throws -> Identity {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700,
              noExtendedACL(fd) else { throw Failure.untrustedDestination }
        return identity(info)
    }

    private static func noExtendedACL(_ fd: Int32) -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        return false
    }
}
