import CryptoKit
import Darwin
import Foundation

/// A checked regular-file selection for a future descriptor-based loader.
/// This does not make a mutable file immutable, and is not suitable for path-based
/// loaders or model directories. A caller must discard results if verification fails.
struct SelectedModelFileIdentity {
    enum Failure: Error {
        case invalidPath
        case unavailable
        case notRegularFile
        case tooLarge
        case changed
        case readFailed
    }

    private struct Metadata: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ value: stat) {
            device = value.st_dev
            inode = value.st_ino
            size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec
            modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec
            changedNanoseconds = value.st_ctimespec.tv_nsec
        }
    }

    private struct Fingerprint: Equatable {
        let metadata: Metadata
        let digest: SHA256.Digest
    }

    private let path: String
    private let maximumBytes: Int64
    private let fingerprint: Fingerprint

    static func capture(url: URL, maximumBytes: Int64) throws -> Self {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.isEmpty, maximumBytes >= 0 else {
            throw Failure.invalidPath
        }
        let path = url.path
        let descriptor = try openRegularFile(path)
        defer { close(descriptor) }
        let fingerprint = try inspect(descriptor, path: path, maximumBytes: maximumBytes)
        return Self(path: path, maximumBytes: maximumBytes, fingerprint: fingerprint)
    }

    /// The descriptor is borrowed for the synchronous callback and must not escape.
    /// Verification afterwards can detect changes but cannot undo callback side effects.
    func withVerifiedFile<T>(_ body: (Int32) throws -> T) throws -> T {
        let descriptor = try Self.openRegularFile(path)
        defer { close(descriptor) }
        guard try Self.inspect(descriptor, path: path, maximumBytes: maximumBytes) == fingerprint else {
            throw Failure.changed
        }
        guard lseek(descriptor, 0, SEEK_SET) == 0 else { throw Failure.readFailed }
        let result = try body(descriptor)
        guard try Self.inspect(descriptor, path: path, maximumBytes: maximumBytes) == fingerprint else {
            throw Failure.changed
        }
        return result
    }

    private static func openRegularFile(_ path: String) throws -> Int32 {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw Failure.unavailable }
        var value = stat()
        guard fstat(descriptor, &value) == 0 else {
            close(descriptor)
            throw Failure.unavailable
        }
        guard value.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw Failure.notRegularFile
        }
        return descriptor
    }

    private static func inspect(_ descriptor: Int32, path: String, maximumBytes: Int64) throws -> Fingerprint {
        var initial = stat()
        guard fstat(descriptor, &initial) == 0 else { throw Failure.unavailable }
        guard initial.st_mode & S_IFMT == S_IFREG else { throw Failure.notRegularFile }
        guard initial.st_size >= 0, initial.st_size <= maximumBytes else { throw Failure.tooLarge }
        guard lseek(descriptor, 0, SEEK_SET) == 0 else { throw Failure.readFailed }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var total: Int64 = 0
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure.readFailed
            }
            if count == 0 { break }
            guard Int64(count) <= maximumBytes - total else { throw Failure.tooLarge }
            total += Int64(count)
            hasher.update(data: buffer.prefix(count))
        }
        var final = stat()
        var named = stat()
        guard fstat(descriptor, &final) == 0, lstat(path, &named) == 0,
              named.st_mode & S_IFMT == S_IFREG,
              Metadata(initial) == Metadata(final), Metadata(final) == Metadata(named),
              total == final.st_size else { throw Failure.changed }
        return Fingerprint(metadata: Metadata(final), digest: hasher.finalize())
    }
}
