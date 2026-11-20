import Foundation
import Darwin
import SQLite3

/// Coordinates participating narrative writers. Old versions and unrelated
/// programs do not participate and must not write the database concurrently.
enum ACTANarrativeWriteCoordination {
    static func withLock<T>(databaseURL: URL, _ body: (Int32) throws -> T) throws -> T {
        guard databaseURL.isFileURL else { throw Failure.invalid }
        let url = databaseURL.resolvingSymlinksInPath().standardizedFileURL
        let path = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).narrative-revision").path
        var created = false
        var fd = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        if fd >= 0 {
            created = true
        } else if errno == EEXIST {
            fd = open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { throw Failure.unavailable }
        defer { close(fd) }
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR,
                  DispatchTime.now().uptimeNanoseconds < deadline else { throw Failure.unavailable }
            usleep(10_000)
        }
        defer { flock(fd, LOCK_UN) }
        var descriptor = stat()
        var entry = stat()
        guard fstat(fd, &descriptor) == 0, lstat(path, &entry) == 0,
              descriptor.st_mode & S_IFMT == S_IFREG,
              entry.st_mode & S_IFMT == S_IFREG,
              descriptor.st_dev == entry.st_dev, descriptor.st_ino == entry.st_ino else {
            throw Failure.unavailable
        }
        if created { try advance(fd) }
        _ = try revision(fd)
        return try body(fd)
    }

    static func revision(_ fd: Int32) throws -> UUID {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_size == 36 else { throw Failure.invalid }
        var bytes = [UInt8](repeating: 0, count: 36)
        guard pread(fd, &bytes, bytes.count, 0) == bytes.count,
              let value = String(bytes: bytes, encoding: .utf8),
              let revision = UUID(uuidString: value), value == revision.uuidString else {
            throw Failure.invalid
        }
        return revision
    }

    /// Advance before any database write. A torn or failed write fails closed.
    static func advance(_ fd: Int32) throws {
        let bytes = Array(UUID().uuidString.utf8)
        guard bytes.withUnsafeBytes({ pwrite(fd, $0.baseAddress, bytes.count, 0) }) == bytes.count,
              ftruncate(fd, off_t(bytes.count)) == 0, fsync(fd) == 0 else {
            throw Failure.unavailable
        }
    }

    enum Failure: Error { case invalid, unavailable }
}

public struct ACTANarrativePinSQLiteSnapshot: Equatable, Sendable {
    public let chapterID: UUID
    public let revision: UUID
    public let pinned: Bool
    public let operatorMarked: Bool
    public let preservedFields: Data

    public init(chapterID: UUID, revision: UUID, pinned: Bool, operatorMarked: Bool, preservedFields: Data) {
        self.chapterID = chapterID
        self.revision = revision
        self.pinned = pinned
        self.operatorMarked = operatorMarked
        self.preservedFields = preservedFields
    }
}

/// No schema migration: the revision sidecar fences all participating writers.
/// A failed commit may have an unknown outcome.
public final class ACTANarrativePinSQLiteStore: @unchecked Sendable {
    private let databaseURL: URL
    private let database: OpaquePointer
    private let lock = NSLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(databaseURL: URL) throws {
        guard databaseURL.isFileURL else { throw StoreError.unavailable }
        self.databaseURL = databaseURL.resolvingSymlinksInPath().standardizedFileURL
        var handle: OpaquePointer?
        guard sqlite3_open_v2(self.databaseURL.path, &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }
            throw StoreError.unavailable
        }
        database = handle
        sqlite3_busy_timeout(handle, 3000)
    }

    deinit { sqlite3_close(database) }

    public func revision() throws -> UUID {
        try lock.withLock {
            try ACTANarrativeWriteCoordination.withLock(databaseURL: databaseURL) { fd in
                try ACTANarrativeWriteCoordination.revision(fd)
            }
        }
    }

    public func capture(chapterID: UUID) throws -> ACTANarrativePinSQLiteSnapshot? {
        try lock.withLock {
            try ACTANarrativeWriteCoordination.withLock(databaseURL: databaseURL) { fd in
                try read(chapterID: chapterID, revision: ACTANarrativeWriteCoordination.revision(fd))
            }
        }
    }

    public func commit(expected: ACTANarrativePinSQLiteSnapshot,
                       pinned: Bool) throws -> ACTANarrativePinSQLiteSnapshot? {
        try lock.withLock {
            try ACTANarrativeWriteCoordination.withLock(databaseURL: databaseURL) { fd in
                try exec("BEGIN IMMEDIATE")
                var open = true
                defer { if open { try? exec("ROLLBACK") } }
                let revision = try ACTANarrativeWriteCoordination.revision(fd)
                guard try read(chapterID: expected.chapterID, revision: revision) == expected,
                      !pinned || expected.operatorMarked else { return nil }
                try ACTANarrativeWriteCoordination.advance(fd)
                let nextRevision = try ACTANarrativeWriteCoordination.revision(fd)
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, "UPDATE ghost_narrative_chapters SET pinned = ? WHERE chapter_id = ? COLLATE NOCASE", -1, &statement, nil) == SQLITE_OK,
                      let statement else { throw StoreError.unavailable }
                defer { sqlite3_finalize(statement) }
                let changes = sqlite3_total_changes64(database)
                guard sqlite3_bind_int(statement, 1, pinned ? 1 : 0) == SQLITE_OK,
                      sqlite3_bind_text(statement, 2, expected.chapterID.uuidString, -1, transient) == SQLITE_OK,
                      sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1,
                      sqlite3_total_changes64(database) == changes + 1,
                      let result = try read(chapterID: expected.chapterID, revision: nextRevision),
                      result.pinned == pinned, result.operatorMarked == expected.operatorMarked,
                      result.preservedFields == expected.preservedFields
                else { throw StoreError.unavailable }
                try exec("COMMIT")
                open = false
                return result
            }
        }
    }

    private struct Field: Encodable {
        let name: String
        let type: Int32
        let bytes: Data
    }

    private func read(chapterID: UUID, revision: UUID) throws -> ACTANarrativePinSQLiteSnapshot? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT * FROM ghost_narrative_chapters WHERE chapter_id = ? COLLATE NOCASE", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StoreError.unavailable }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, chapterID.uuidString, -1, transient) == SQLITE_OK else { throw StoreError.unavailable }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw StoreError.unavailable }
        var fields: [Field] = []
        var pinned: Bool?
        var marked: Bool?
        for index in 0..<sqlite3_column_count(statement) {
            guard let rawName = sqlite3_column_name(statement, index) else { throw StoreError.unavailable }
            let name = String(cString: rawName)
            let type = sqlite3_column_type(statement, index)
            if name == "pinned" || name == "operator_marked" {
                guard type == SQLITE_INTEGER else { throw StoreError.unavailable }
                let value = sqlite3_column_int64(statement, index)
                guard value == 0 || value == 1 else { throw StoreError.unavailable }
                if name == "pinned" { pinned = value == 1; continue }
                marked = value == 1
            }
            let bytes: Data
            switch type {
            case SQLITE_NULL: bytes = Data()
            case SQLITE_INTEGER:
                bytes = Data(String(sqlite3_column_int64(statement, index)).utf8)
            case SQLITE_FLOAT:
                bytes = Data(String(sqlite3_column_double(statement, index).bitPattern).utf8)
            case SQLITE_TEXT, SQLITE_BLOB:
                let pointer = type == SQLITE_TEXT
                    ? sqlite3_column_text(statement, index).map { UnsafeRawPointer($0) }
                    : sqlite3_column_blob(statement, index)
                let count = Int(sqlite3_column_bytes(statement, index))
                if count == 0 { bytes = Data() }
                else if let pointer { bytes = Data(bytes: pointer, count: count) }
                else { throw StoreError.unavailable }
            default: throw StoreError.unavailable
            }
            fields.append(Field(name: name, type: type, bytes: bytes))
        }
        guard let pinned, let marked, sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.unavailable }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return ACTANarrativePinSQLiteSnapshot(chapterID: chapterID, revision: revision,
            pinned: pinned, operatorMarked: marked, preservedFields: try encoder.encode(fields))
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.unavailable }
    }

    public enum StoreError: Error { case unavailable }
}
