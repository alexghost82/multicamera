import Darwin
import Foundation

/// One lease must cover the entire lifetime of every mission scheduler, queue,
/// store writer and in-flight run in an application instance. This is only an
/// advisory lock: older versions and non-participating writers must be stopped.
/// Never unlink or replace the lock file.
final class ACTAMissionServiceLease {
    private let descriptor: Int32
    private let lockURL: URL

    private init(descriptor: Int32, lockURL: URL) {
        self.descriptor = descriptor
        self.lockURL = lockURL
    }

    deinit {
        close(descriptor)
    }

    /// Returns nil when another cooperating instance owns the mission service.
    /// The caller must keep the returned object alive until all mission work
    /// has stopped, including asynchronous work and completion callbacks.
    static func acquire(storeURL: URL) throws -> ACTAMissionServiceLease? {
        guard storeURL.isFileURL, !storeURL.lastPathComponent.isEmpty else {
            throw LeaseError.invalidPath
        }
        let parent = storeURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let lockURL = parent.appendingPathComponent(".\(storeURL.lastPathComponent).service.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw posixError() }
        var acquired = false
        defer { if !acquired { close(fd) } }

        var opened = stat()
        guard fstat(fd, &opened) == 0 else { throw posixError() }
        guard opened.st_mode & S_IFMT == S_IFREG, opened.st_nlink == 1,
              opened.st_uid == geteuid(), opened.st_mode & 0o077 == 0 else {
            throw LeaseError.unsafeLockFile
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN { return nil }
            throw posixError()
        }
        var current = stat()
        guard lstat(lockURL.path, &current) == 0 else { throw posixError() }
        guard current.st_mode & S_IFMT == S_IFREG,
              current.st_dev == opened.st_dev, current.st_ino == opened.st_ino else {
            throw LeaseError.unsafeLockFile
        }
        acquired = true
        return ACTAMissionServiceLease(descriptor: fd, lockURL: lockURL)
    }

    /// Detect a removed, replaced, or newly unsafe lock before using the
    /// service. This does not prevent replacement after the check.
    func validate() throws {
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else { throw Self.posixError() }
        var current = stat()
        guard lstat(lockURL.path, &current) == 0 else { throw Self.posixError() }
        guard opened.st_mode & S_IFMT == S_IFREG, opened.st_nlink == 1,
              opened.st_uid == geteuid(), opened.st_mode & 0o077 == 0,
              current.st_mode & S_IFMT == S_IFREG,
              current.st_dev == opened.st_dev, current.st_ino == opened.st_ino else {
            throw LeaseError.unsafeLockFile
        }
    }

    static func storeExistsAndIsRegular(_ url: URL) throws -> Bool {
        guard url.isFileURL else { throw LeaseError.invalidPath }
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT { return false }
            throw posixError()
        }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1 else {
            throw LeaseError.unsafeStoreFile
        }
        return true
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    enum LeaseError: Error {
        case invalidPath
        case unsafeLockFile, unsafeStoreFile
    }
}

/// Serializes synchronous mission transitions as well as excluding other
/// cooperating processes. A failed initialization or uncertain write is
/// sticky: recovery requires a fresh service instance and a disk reload.
@MainActor
final class ACTAMissionServiceAccess {
    private let lease: ACTAMissionServiceLease
    private var ready = false
    private var mutating = false
    private var failed = false

    init(lease: ACTAMissionServiceLease) {
        self.lease = lease
    }

    func loaded() { if !failed { ready = true } }
    func invalidate() { failed = true; ready = false }

    func requireRead() throws {
        guard ready, !failed, !mutating else { throw AccessError.unavailable }
        try validateLease()
    }

    func requireActiveMutation() throws {
        guard ready, !failed, mutating else { throw AccessError.unavailable }
        try validateLease()
    }

    func withMutation<T>(_ body: () throws -> T) throws -> T {
        guard ready, !failed, !mutating else { throw AccessError.unavailable }
        try validateLease()
        mutating = true
        defer { mutating = false }
        do {
            let result = try body()
            guard ready, !failed else { throw AccessError.unavailable }
            try validateLease()
            return result
        } catch {
            // A failed operation may have lost its lock even when it throws
            // for another reason; make that loss sticky.
            if (try? lease.validate()) == nil { invalidate() }
            throw error
        }
    }

    private func validateLease() throws {
        do { try lease.validate() }
        catch {
            invalidate()
            throw AccessError.unavailable
        }
    }

    enum AccessError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Mission service is unavailable or busy." }
    }
}
