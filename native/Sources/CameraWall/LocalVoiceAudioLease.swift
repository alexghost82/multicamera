import Darwin
import Foundation

final class LocalVoiceAudioLease {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    func duplicateForChild() throws -> FileHandle {
        let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: copy, closeOnDealloc: true)
    }

    static func acquire(url: URL? = nil) throws -> LocalVoiceAudioLease {
        let lockURL = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CameraWall/.voice-audio.lock")
        let directory = lockURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = open(lockURL.path, O_CREAT | O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode_t(0o600))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var acquired = false
        defer { if !acquired { close(fd) } }
        var opened = stat()
        guard fstat(fd, &opened) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard opened.st_mode & S_IFMT == S_IFREG, opened.st_nlink == 1,
              opened.st_uid == geteuid(), opened.st_mode & 0o077 == 0 else {
            throw LeaseError.unsafeLock
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw LeaseError.busy }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var current = stat()
        guard lstat(lockURL.path, &current) == 0,
              current.st_mode & S_IFMT == S_IFREG, current.st_nlink == 1,
              current.st_uid == geteuid(), current.st_mode & 0o077 == 0,
              current.st_dev == opened.st_dev, current.st_ino == opened.st_ino else {
            flock(fd, LOCK_UN)
            throw LeaseError.unsafeLock
        }
        acquired = true
        return LocalVoiceAudioLease(descriptor: fd)
    }

    private enum LeaseError: LocalizedError {
        case busy, unsafeLock

        var errorDescription: String? {
            switch self {
            case .busy: return "Voice input or speech is active in another window or app instance."
            case .unsafeLock: return "The voice coordination lock is unsafe."
            }
        }
    }
}
