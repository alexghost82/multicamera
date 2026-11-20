import Foundation
import Darwin

/// All cooperating writers must use this store and compare against their own
/// last snapshot. It does not coordinate old versions or external writers.
public enum CoordinatedCameraConfigurationStore {
    public struct Snapshot {
        public let configuration: WallConfiguration
        public let revision: UUID?
        fileprivate let bytes: Data?
        fileprivate let path: String

        public var isMissing: Bool { bytes == nil }

        public func isSafelyRoundTrippable() throws -> Bool {
            guard let bytes else { return true }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return bytes == (try encoder.encode(configuration))
        }

        public func isSemanticallyRoundTrippable() throws -> Bool {
            guard let bytes else { return true }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return CameraConfigurationRoundTrip.preservesFields(original: bytes, encoded: try encoder.encode(configuration))
        }

        public func matches(_ other: Snapshot) -> Bool {
            path == other.path && revision == other.revision && bytes == other.bytes
        }
    }

    /// Only one cooperating runtime may use a configuration at a time. It
    /// holds this lease from before reading until all dependent activity stops.
    public final class RuntimeLease {
        private let fd: Int32
        fileprivate let path: String

        fileprivate init(fd: Int32, path: String) { self.fd = fd; self.path = path }
        deinit { close(fd) }

        /// The child must keep this open until its configuration-dependent
        /// subprocesses have exited. Closing the last duplicate releases flock.
        public func duplicateForChild() throws -> FileHandle {
            let copy = dup(fd)
            guard copy >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return FileHandle(fileDescriptor: copy, closeOnDealloc: true)
        }

        fileprivate func validate(for url: URL) throws {
            guard url.isFileURL, path == url.standardizedFileURL.path else {
                throw ConfigurationError.invalid("Camera runtime lease belongs to another configuration.")
            }
            try validateHeldLock(fd, url: url, suffix: "runtime-lock")
        }
    }

    /// Valid only during the synchronous withWriterLease closure.
    public final class WriterLease {
        private let mutex = NSRecursiveLock()
        private let fd: Int32
        private let path: String
        private var active = true

        fileprivate init(fd: Int32, path: String) { self.fd = fd; self.path = path }

        fileprivate func withPermit<T>(url: URL, _ body: () throws -> T) throws -> T {
            mutex.lock()
            defer { mutex.unlock() }
            guard active, url.isFileURL, path == url.standardizedFileURL.path else {
                throw ConfigurationError.invalid("Camera writer lease is inactive or belongs to another configuration.")
            }
            try validateHeldLock(fd, url: url, suffix: "runtime-lock")
            return try body()
        }

        fileprivate func invalidate() {
            mutex.lock()
            defer { mutex.unlock() }
            guard active else { return }
            active = false
            flock(fd, LOCK_UN)
            close(fd)
        }
    }

    public static func acquireRuntimeLease(for url: URL) throws -> RuntimeLease {
        try RuntimeLease(fd: openRuntimeLock(url, operation: LOCK_EX), path: url.standardizedFileURL.path)
    }

    /// Writers must hold this while changing configuration and in-memory state.
    public static func withStoppedRuntimes<T>(for url: URL, _ body: () throws -> T) throws -> T {
        try withWriterLease(for: url) { _ in try body() }
    }

    public static func withWriterLease<T>(for url: URL, _ body: (WriterLease) throws -> T) throws -> T {
        let fd = try openRuntimeLock(url, operation: LOCK_EX)
        let lease = WriterLease(fd: fd, path: url.standardizedFileURL.path)
        defer { lease.invalidate() }
        return try body(lease)
    }

    private static func openRuntimeLock(_ url: URL, operation: Int32) throws -> Int32 {
        try openValidatedLock(url, suffix: "runtime-lock", operation: operation)
    }

    private static func openValidatedLock(_ url: URL, suffix: String, operation: Int32) throws -> Int32 {
        guard url.isFileURL else { throw ConfigurationError.invalid("Camera configuration requires a file URL.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lockURL = sidecar(url, suffix: suffix)
        let fd = open(lockURL.path,
                      O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode_t(0o600))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var acquired = false
        defer { if !acquired { close(fd) } }
        var opened = stat()
        guard fstat(fd, &opened) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard opened.st_mode & S_IFMT == S_IFREG, opened.st_nlink == 1,
              opened.st_uid == geteuid(), opened.st_mode & 0o077 == 0 else {
            throw ConfigurationError.invalid("Camera configuration lock file is unsafe.")
        }
        guard flock(fd, operation | LOCK_NB) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var current = stat()
        guard lstat(lockURL.path, &current) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard current.st_mode & S_IFMT == S_IFREG, current.st_nlink == 1,
              current.st_uid == geteuid(), current.st_mode & 0o077 == 0,
              current.st_dev == opened.st_dev, current.st_ino == opened.st_ino else {
            throw ConfigurationError.invalid("Camera configuration lock file changed or is unsafe.")
        }
        acquired = true
        return fd
    }

    private static func validateHeldLock(_ fd: Int32, url: URL, suffix: String) throws {
        var opened = stat()
        var current = stat()
        guard fstat(fd, &opened) == 0, lstat(sidecar(url, suffix: suffix).path, &current) == 0,
              opened.st_mode & S_IFMT == S_IFREG, current.st_mode & S_IFMT == S_IFREG,
              opened.st_nlink == 1, current.st_nlink == 1,
              opened.st_uid == geteuid(), current.st_uid == geteuid(),
              opened.st_mode & 0o077 == 0, current.st_mode & 0o077 == 0,
              opened.st_dev == current.st_dev, opened.st_ino == current.st_ino else {
            throw ConfigurationError.invalid("Camera configuration lock file changed or is unsafe.")
        }
    }

    public static func snapshot(from url: URL) throws -> Snapshot {
        try withLock(url) { try snapshotLocked(from: url) }
    }

    /// The callback must not re-enter this store. Cooperating configuration
    /// writers cannot publish a new snapshot until the callback returns.
    public static func withLockedSnapshot<T>(from url: URL, _ body: (Snapshot) throws -> T) throws -> T {
        try withLock(url) { try body(snapshotLocked(from: url)) }
    }

    public static func checkedConfiguration(matching memory: WallConfiguration, from url: URL) throws -> WallConfiguration {
        let current = try snapshot(from: url).configuration
        guard current == memory else {
            throw ConfigurationError.invalid("Camera configuration changed on disk; reload it before making changes.")
        }
        return current
    }

    /// Returns nil for stale state. Errors during a write have an unknown
    /// outcome; a caller must reload and reconcile before attempting another.
    public static func compareAndSave(_ configuration: WallConfiguration, expected: Snapshot,
                                      to url: URL) throws -> Snapshot? {
        try configuration.validate()
        guard url.isFileURL, expected.path == url.standardizedFileURL.path else { return nil }
        return try withWriterLease(for: url) { lease in
            try compareAndSave(configuration, expected: expected, to: url, using: lease)
        }
    }

    public static func compareAndSave(_ configuration: WallConfiguration, expected: Snapshot,
                                      to url: URL, using lease: WriterLease) throws -> Snapshot? {
        try configuration.validate()
        guard url.isFileURL, expected.path == url.standardizedFileURL.path else { return nil }
        return try lease.withPermit(url: url) {
            try saveLocked(configuration, expected: expected, to: url, restriction: .none)
        }
    }

    /// Only the runtime owner may change these flags without stopping sources.
    /// The host must serialize same-process writers and memory publication.
    /// Lease descriptors are shared only with the trusted relay guardian.
    public static func compareAndSaveRuntimePreferences(_ configuration: WallConfiguration, expected: Snapshot,
                                                       to url: URL, using lease: RuntimeLease) throws -> Snapshot? {
        try configuration.validate()
        guard url.isFileURL, expected.path == url.standardizedFileURL.path else { return nil }
        return try withExtendedLifetime(lease) {
            try lease.validate(for: url)
            return try saveLocked(configuration, expected: expected, to: url, restriction: .preferences)
        }
    }

    /// Discovery may initialize a missing default configuration under its own lease.
    public static func initializeMissingForDiscovery(_ configuration: WallConfiguration, expected: Snapshot,
                                                      to url: URL, using lease: RuntimeLease) throws -> Snapshot? {
        try configuration.validate()
        guard url.isFileURL, expected.path == url.standardizedFileURL.path else { return nil }
        return try withExtendedLifetime(lease) {
            try lease.validate(for: url)
            return try saveLocked(configuration, expected: expected, to: url, restriction: .discoveryInitialization)
        }
    }

    private enum Restriction { case none, preferences, discoveryInitialization }

    private static func saveLocked(_ configuration: WallConfiguration, expected: Snapshot, to url: URL,
                                   restriction: Restriction) throws -> Snapshot? {
        return try withLock(url) {
            let current = try snapshotLocked(from: url)
            guard current.revision == expected.revision, current.bytes == expected.bytes else { return nil }
            switch restriction {
            case .none:
                break
            case .preferences:
                var allowed = current.configuration
                guard !current.isMissing, allowed.cameras.count == configuration.cameras.count else {
                    throw ConfigurationError.invalid("Runtime writes may only change camera processing preferences.")
                }
                for index in allowed.cameras.indices {
                    allowed.cameras[index].yoloEnabled = configuration.cameras[index].yoloEnabled
                    allowed.cameras[index].aiChatEnabled = configuration.cameras[index].aiChatEnabled
                }
                guard allowed == configuration else {
                    throw ConfigurationError.invalid("Runtime writes may only change camera processing preferences.")
                }
            case .discoveryInitialization:
                var initial = WallConfiguration()
                initial.go2rtcPath = configuration.go2rtcPath
                guard current.isMissing, current.revision == nil, configuration == initial else {
                    throw ConfigurationError.invalid("Discovery can initialize only a missing default configuration.")
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if try !current.isSemanticallyRoundTrippable() {
                throw ConfigurationError.invalid("Camera configuration is not safely round-trippable.")
            }
            let data = try encoder.encode(configuration)
            let revisionURL = sidecar(url, suffix: "revision")
            try Data(UUID().uuidString.utf8).write(to: revisionURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: revisionURL.path)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return try snapshotLocked(from: url)
        }
    }

    private static func sidecar(_ url: URL, suffix: String) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(suffix)")
    }

    private static func withLock<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        let fd = try openValidatedLock(url, suffix: "lock", operation: LOCK_EX)
        defer { flock(fd, LOCK_UN); close(fd) }
        return try body()
    }

    private static func snapshotLocked(from url: URL) throws -> Snapshot {
        let revisionURL = sidecar(url, suffix: "revision")
        let revision: UUID?
        if let revisionData = try readRegularFileIfPresent(revisionURL) {
            guard let value = String(data: revisionData, encoding: .utf8) else {
                throw ConfigurationError.invalid("Invalid camera configuration revision.")
            }
            guard let parsed = UUID(uuidString: value) else {
                throw ConfigurationError.invalid("Invalid camera configuration revision.")
            }
            revision = parsed
        } else {
            revision = nil
        }
        let bytes: Data?
        let configuration: WallConfiguration
        if let loaded = try readRegularFileIfPresent(url) {
            let decoded = try JSONDecoder().decode(WallConfiguration.self, from: loaded)
            try decoded.validate()
            bytes = loaded
            configuration = decoded
        } else {
            guard revision == nil else {
                throw ConfigurationError.invalid("Camera configuration is missing after an earlier write; reconcile it before continuing.")
            }
            bytes = nil
            configuration = WallConfiguration()
        }
        return Snapshot(configuration: configuration, revision: revision, bytes: bytes,
                        path: url.standardizedFileURL.path)
    }

    private static func readRegularFileIfPresent(_ url: URL) throws -> Data? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw ConfigurationError.invalid("Camera configuration is not a regular file.")
        }
        return try Data(contentsOf: url)
    }
}
