import CryptoKit
import Darwin
import Foundation

/// Holds the exact frame and destination reviewed by an operator.
public actor ACTASnapshotExportFoundation {
    public struct FileIdentity: Equatable, Sendable {
        public let device: UInt64
        public let inode: UInt64
    }

    public struct Preview: Equatable, Sendable {
        public let cameraID: UUID
        public let destinationPath: String
        public let byteCount: Int
        public let sha256: String
        /// Non-nil only when the parent directory has been securely opened.
        public let directoryIdentity: FileIdentity?
    }

    public struct Request: Sendable {
        public let token: UUID
        public let preview: Preview
    }

    public struct ApprovedSnapshot: Sendable {
        public let preview: Preview
        public let jpeg: Data
    }

    public struct Receipt: Sendable {
        public let preview: Preview
        public let fileIdentity: FileIdentity
    }

    public enum Failure: Error, Equatable {
        case invalidSnapshot
        case invalidDestination
        case capacityExceeded
        case invalidOrExpiredConfirmation
        case confirmationMismatch
        case declined
        case destinationUnavailable
        case destinationExists
        case destinationChanged
        case publicationFailed
        case verificationFailed
    }

    private final class DirectoryHandle {
        let fd: Int32
        let identity: FileIdentity
        init(fd: Int32, identity: FileIdentity) {
            self.fd = fd
            self.identity = identity
        }
        deinit { close(fd) }
    }

    private struct Pending {
        let preview: Preview
        let jpeg: Data
        let expiresAt: TimeInterval
        let directory: DirectoryHandle?
    }

    private let now: @Sendable () -> TimeInterval
    private let beforeReadback: @Sendable (Int32) -> Void
    private let beforeIdentityCheck: @Sendable () -> Void
    private var pending: [UUID: Pending] = [:]
    private static let maximumBytes = 8 * 1024 * 1024
    private static let maximumPending = 4
    private static let lifetime: TimeInterval = 300

    public init() {
        now = { ProcessInfo.processInfo.systemUptime }
        beforeReadback = { _ in }
        beforeIdentityCheck = {}
    }

    init(now: @escaping @Sendable () -> TimeInterval,
         beforeReadback: @escaping @Sendable (Int32) -> Void = { _ in },
         beforeIdentityCheck: @escaping @Sendable () -> Void = {}) {
        self.now = now
        self.beforeReadback = beforeReadback
        self.beforeIdentityCheck = beforeIdentityCheck
    }

    /// Captures the bytes now, not a camera reference that could yield a different frame later.
    public func prepare(cameraID: UUID, jpeg: Data, destinationPath: String) throws -> Request {
        let instant = now()
        expire(at: instant)
        guard jpeg.count >= 4, jpeg.count <= Self.maximumBytes else {
            throw Failure.invalidSnapshot
        }
        let captured = Data([UInt8](jpeg))
        guard captured.starts(with: [0xff, 0xd8]), captured.suffix(2).elementsEqual([0xff, 0xd9]) else {
            throw Failure.invalidSnapshot
        }
        guard Self.validDestination(destinationPath) else { throw Failure.invalidDestination }
        guard instant.isFinite, instant >= 0, pending.count < Self.maximumPending else {
            throw Failure.capacityExceeded
        }
        let digest = SHA256.hash(data: captured).map { String(format: "%02x", $0) }.joined()
        let preview = Preview(cameraID: cameraID, destinationPath: destinationPath,
                              byteCount: captured.count, sha256: digest, directoryIdentity: nil)
        var token = UUID()
        while pending[token] != nil { token = UUID() }
        pending[token] = Pending(preview: preview, jpeg: captured, expiresAt: instant + Self.lifetime, directory: nil)
        return Request(token: token, preview: preview)
    }

    /// Pins the reviewed directory before confirmation. No file is created here.
    /// The caller must restrict publication to a trusted namespace: a process
    /// able to rename ancestors can move the pinned directory between checks.
    public func prepareForPublication(cameraID: UUID, jpeg: Data, destinationPath: String) throws -> Request {
        guard Self.validDestination(destinationPath) else { throw Failure.invalidDestination }
        let directory = try Self.openParent(of: destinationPath)
        try Self.requireMissingLeaf(destinationPath, directory: directory)
        let request = try prepare(cameraID: cameraID, jpeg: jpeg, destinationPath: destinationPath)
        guard let entry = pending[request.token] else { throw Failure.invalidOrExpiredConfirmation }
        let preview = Preview(cameraID: entry.preview.cameraID, destinationPath: destinationPath,
                              byteCount: entry.preview.byteCount, sha256: entry.preview.sha256,
                              directoryIdentity: directory.identity)
        pending[request.token] = Pending(preview: preview, jpeg: entry.jpeg,
                                         expiresAt: entry.expiresAt, directory: directory)
        return Request(token: request.token, preview: preview)
    }

    /// The caller must pass the complete preview shown to the operator. Every
    /// attempt consumes the token, including rejection or a mismatched review.
    public func resolve(token: UUID, reviewed: Preview, approved: Bool) throws -> ApprovedSnapshot {
        let entry = try consume(token: token, reviewed: reviewed, approved: approved)
        return ApprovedSnapshot(preview: entry.preview, jpeg: entry.jpeg)
    }

    /// Publishes only into the directory inode pinned in the reviewed preview.
    /// Checks detect observed namespace changes but cannot make path lookup and
    /// creation atomic against concurrent renames. On failure after creation a
    /// file may remain; it is never unlinked by name because that name could
    /// have been replaced. The receipt does not promise crash durability.
    public func publish(token: UUID, reviewed: Preview, approved: Bool) throws -> Receipt {
        let entry = try consume(token: token, reviewed: reviewed, approved: approved)
        guard let directory = entry.directory else { throw Failure.destinationUnavailable }
        try Task.checkCancellation()
        try Self.requireSameParent(entry.preview.destinationPath, directory: directory)
        let leaf = Self.leaf(of: entry.preview.destinationPath)
        let fd = leaf.withCString {
            openat(directory.fd, $0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard fd >= 0 else {
            if errno == EEXIST { throw Failure.destinationExists }
            throw Failure.publicationFailed
        }
        defer { close(fd) }
        try Self.writeAndVerify(entry.jpeg, fd: fd, beforeReadback: beforeReadback)
        beforeIdentityCheck()
        let fileIdentity = try Self.requireSameFile(fd: fd, leaf: leaf, directory: directory)
        try Self.requireSameParent(entry.preview.destinationPath, directory: directory)
        return Receipt(preview: entry.preview, fileIdentity: fileIdentity)
    }

    private func consume(token: UUID, reviewed: Preview, approved: Bool) throws -> Pending {
        let instant = now()
        expire(at: instant)
        guard let entry = pending.removeValue(forKey: token) else {
            throw Failure.invalidOrExpiredConfirmation
        }
        guard reviewed == entry.preview else { throw Failure.confirmationMismatch }
        guard approved else { throw Failure.declined }
        return entry
    }

    public func cancel(token: UUID) {
        pending.removeValue(forKey: token)
    }

    private func expire(at instant: TimeInterval) {
        guard instant.isFinite, instant >= 0 else {
            pending.removeAll()
            return
        }
        pending = pending.filter { instant < $0.value.expiresAt }
    }

    private static func validDestination(_ path: String) -> Bool {
        guard path.utf8.count <= 1024, path.hasPrefix("/"),
              path.utf8.allSatisfy({ (32...126).contains($0) && $0 != 92 }),
              path.lowercased().hasSuffix(".jpg") || path.lowercased().hasSuffix(".jpeg") else {
            return false
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func leaf(of path: String) -> String {
        String(path.split(separator: "/").last!)
    }

    private static func identity(_ info: stat) -> FileIdentity {
        FileIdentity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino))
    }

    /// Each component is opened relative to its already-open parent without following links.
    private static func openParent(of path: String) throws -> DirectoryHandle {
        let components = path.split(separator: "/").dropLast()
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.destinationUnavailable }
        for component in components {
            let next = String(component).withCString {
                openat(fd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            close(fd)
            guard next >= 0 else { throw Failure.destinationUnavailable }
            fd = next
        }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            close(fd)
            throw Failure.destinationUnavailable
        }
        return DirectoryHandle(fd: fd, identity: identity(info))
    }

    private static func requireSameParent(_ path: String, directory: DirectoryHandle) throws {
        guard let current = try? openParent(of: path), current.identity == directory.identity else {
            throw Failure.destinationChanged
        }
    }

    private static func requireMissingLeaf(_ path: String, directory: DirectoryHandle) throws {
        var info = stat()
        let result = leaf(of: path).withCString { fstatat(directory.fd, $0, &info, AT_SYMLINK_NOFOLLOW) }
        if result == 0 { throw Failure.destinationExists }
        guard errno == ENOENT else { throw Failure.destinationUnavailable }
    }

    private static func writeAndVerify(_ data: Data, fd: Int32,
                                       beforeReadback: @Sendable (Int32) -> Void) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw Failure.publicationFailed }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw Failure.publicationFailed }
        beforeReadback(fd)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size == data.count else { throw Failure.verificationFailed }
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, data.count))
        var offset = 0
        while offset < data.count {
            let count = min(buffer.count, data.count - offset)
            let readCount = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
            if readCount < 0 && errno == EINTR { continue }
            guard readCount > 0,
                  data[offset..<(offset + readCount)].elementsEqual(buffer.prefix(readCount)) else {
                throw Failure.verificationFailed
            }
            offset += readCount
        }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_size == info.st_size,
              identity(after) == identity(info),
              after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else {
            throw Failure.verificationFailed
        }
    }

    private static func requireSameFile(fd: Int32, leaf: String, directory: DirectoryHandle) throws -> FileIdentity {
        var opened = stat()
        var named = stat()
        guard fstat(fd, &opened) == 0,
              leaf.withCString({ fstatat(directory.fd, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG, (named.st_mode & S_IFMT) == S_IFREG,
              opened.st_nlink == 1, named.st_nlink == 1, identity(opened) == identity(named) else {
            throw Failure.verificationFailed
        }
        return identity(opened)
    }
}
