import Darwin
import Foundation

/// Publishes frozen bytes without replacing an existing name. The destination must
/// come from trusted operator UI, never model input. The containing directory must
/// not be concurrently renamed or modified by untrusted processes.
enum ACTACreateOnlyExport {
    enum Failure: Error {
        case invalidDestination, invalidContent, collision, io, uncertain
    }

    static let maximumBytes = 32 * 1024 * 1024

    /// Once publication starts an error can mean that the final name exists.
    /// Callers must reconcile it with the operator before retrying.
    static func publish(_ content: Data, to destination: URL) throws {
        guard !content.isEmpty, content.count <= maximumBytes else { throw Failure.invalidContent }
        let bytes = Data([UInt8](content))
        guard destination.isFileURL, destination.path.hasPrefix("/"),
              destination.path.utf8.count <= 4096,
              !destination.lastPathComponent.isEmpty,
              destination.lastPathComponent != ".", destination.lastPathComponent != ".." else {
            throw Failure.invalidDestination
        }
        let parent = destination.deletingLastPathComponent().path
        let name = destination.lastPathComponent
        let directory = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.io }
        defer { close(directory) }

        let staging = ".acta-export-\(UUID().uuidString)"
        let file = openat(directory, staging, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw Failure.io }
        var stagingExists = true
        defer {
            close(file)
            if stagingExists { _ = unlinkat(directory, staging, 0) }
        }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.io }
                offset += count
            }
        }
        guard fsync(file) == 0 else { throw Failure.io }
        try Task.checkCancellation()
        guard linkat(directory, staging, directory, name, 0) == 0 else {
            if errno == EEXIST { throw Failure.collision }
            throw Failure.io
        }
        var source = stat()
        var published = stat()
        guard fstat(file, &source) == 0,
              fstatat(directory, name, &published, AT_SYMLINK_NOFOLLOW) == 0,
              source.st_dev == published.st_dev, source.st_ino == published.st_ino,
              source.st_size == bytes.count else { throw Failure.uncertain }
        var readback = [UInt8](repeating: 0, count: bytes.count)
        let verified = readback.withUnsafeMutableBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = pread(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, off_t(offset))
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
        guard verified, Data(readback) == bytes else { throw Failure.uncertain }
        guard unlinkat(directory, staging, 0) == 0 else { throw Failure.uncertain }
        stagingExists = false
    }

    static func verify(_ content: Data, at destination: URL) throws -> Bool {
        guard !content.isEmpty, content.count <= maximumBytes, destination.isFileURL,
              destination.path.hasPrefix("/"), destination.path.utf8.count <= 4096 else {
            throw Failure.invalidDestination
        }
        let directory = open(destination.deletingLastPathComponent().path,
                             O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.io }
        defer { close(directory) }
        let name = destination.lastPathComponent
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw Failure.io }
        defer { close(file) }
        var opened = stat()
        var named = stat()
        guard fstat(file, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_size == content.count,
              fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else { return false }
        var readback = [UInt8](repeating: 0, count: content.count)
        let complete = readback.withUnsafeMutableBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = pread(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, off_t(offset))
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
        guard complete, Data(readback) == content, fstat(file, &opened) == 0,
              opened.st_size == content.count,
              fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else { return false }
        return true
    }
}
