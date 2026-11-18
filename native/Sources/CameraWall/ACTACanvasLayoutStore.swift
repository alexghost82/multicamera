import CameraCore
import Darwin
import Foundation

// All cooperating writers must use the same persistent lock file. The lock is
// advisory and cannot protect against legacy or otherwise noncooperating writers.
struct ACTACanvasLayoutStore {
    struct Snapshot: Equatable {
        let layout: VideoWallLayout
        fileprivate let bytes: Data?
    }

    enum Failure: Error {
        case busy
        case conflict
        case invalidFile
        case system(Int32)
    }

    private struct Document: Codable {
        let frames: [String: VideoTileFrame]
        let revision: UUID?
    }

    let url: URL

    func read() throws -> Snapshot {
        try withLock { try readLocked() }
    }

    func commit(_ layout: VideoWallLayout, expected: Snapshot) throws -> Snapshot {
        try layout.validate()
        return try withLock {
            guard try readLocked() == expected else { throw Failure.conflict }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Document(frames: layout.frames, revision: UUID()))
            try replaceLocked(data)
            return Snapshot(layout: layout, bytes: data)
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lockURL = url.appendingPathExtension("lock")
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.system(errno) }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1, metadata.st_uid == getuid() else { throw Failure.invalidFile }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN { throw Failure.busy }
            throw Failure.system(errno)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func readLocked() throws -> Snapshot {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 {
            if errno == ENOENT { return Snapshot(layout: VideoWallLayout(), bytes: nil) }
            throw Failure.system(errno)
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG else { throw Failure.invalidFile }
        let data = try file.readToEnd() ?? Data()
        let document = try JSONDecoder().decode(Document.self, from: data)
        var layout = VideoWallLayout()
        layout.frames = document.frames
        try layout.validate()
        return Snapshot(layout: layout, bytes: data)
    }

    private func replaceLocked(_ data: Data) throws {
        let staged = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).stage")
        let fd = open(staged.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.system(errno) }
        var renamed = false
        defer {
            close(fd)
            if !renamed { unlink(staged.path) }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw Failure.system(errno)
                }
                guard count > 0 else { throw Failure.system(EIO) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw Failure.system(errno) }
        guard rename(staged.path, url.path) == 0 else { throw Failure.system(errno) }
        renamed = true
    }
}
