import Foundation
import CryptoKit
import SQLite3
import Darwin

/// Experimental storage foundation, not an agent action or a replacement for GUI deletion.
/// The snapshot covers the track row, operator group and different-pair rows, and
/// the bytes of its two referenced images. Other derived identity data is not deleted.
public struct ACTATrackDeletionSnapshot: Equatable, Sendable {
    public let trackID: UUID
    public let imageNames: [String]
    fileprivate let digest: Data
    fileprivate let images: [ACTATrackDeletionImage]
}

fileprivate struct ACTATrackDeletionImage: Codable, Equatable, Sendable {
    let name: String
    let digest: Data
}

public enum ACTATrackDeletionError: Error, Equatable {
    case missingTrack
    case staleSnapshot
    case invalidImage
    case sharedImage
    case imageChanged
    case pendingDeletion
    case database(String)
}

/// DB deletion and cleanup intent commit together. Image cleanup is explicitly
/// retried; a failure never discards the intent. This does not fence legacy file
/// writers, active trackers, ABA changes, or power loss during filesystem
/// cleanup. Derived identity indexes and dossiers are not erased. Neither the
/// existing GUI path nor startup recovery uses this journal; it is not action-safe.
public final class ACTATrackDeletionJournal: @unchecked Sendable {
    private let db: OpaquePointer
    private let imageDirectory: URL
    private let lock = NSLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(databaseURL: URL) throws {
        imageDirectory = databaseURL.deletingLastPathComponent().appendingPathComponent("identity-crops", isDirectory: true)
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let handle else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? String(status)
            if let handle { sqlite3_close(handle) }
            throw ACTATrackDeletionError.database(detail)
        }
        db = handle
        sqlite3_busy_timeout(db, 3000)
        do {
            try exec("PRAGMA synchronous=FULL")
            try exec("""
                CREATE TABLE IF NOT EXISTS acta_track_deletion_journal (
                    track_id TEXT PRIMARY KEY NOT NULL,
                    images BLOB NOT NULL
                )
                """)
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    public func snapshot(trackID: UUID) throws -> ACTATrackDeletionSnapshot {
        try lock.withLock {
            try transaction { try readSnapshot(trackID: trackID) }
        }
    }

    /// Commits the database portion only; callers must report pending cleanup
    /// until `recover` succeeds, including after process restart.
    public func commit(_ expected: ACTATrackDeletionSnapshot) throws {
        try lock.withLock {
            try transaction {
                guard try !hasPending(trackID: expected.trackID) else { throw ACTATrackDeletionError.pendingDeletion }
                guard try readSnapshot(trackID: expected.trackID) == expected else {
                    throw ACTATrackDeletionError.staleSnapshot
                }
                for image in expected.images {
                    guard try !isReferencedElsewhere(image.name, excluding: expected.trackID) else {
                        throw ACTATrackDeletionError.sharedImage
                    }
                }
                let insert = try prepare("INSERT INTO acta_track_deletion_journal(track_id, images) VALUES(?, ?)")
                defer { sqlite3_finalize(insert) }
                bind(expected.trackID.uuidString, insert, 1)
                let encoded = try JSONEncoder().encode(expected.images)
                encoded.withUnsafeBytes { bytes in
                    _ = sqlite3_bind_blob(insert, 2, bytes.baseAddress, Int32(bytes.count), transient)
                }
                try done(insert)
                for sql in [
                    "DELETE FROM operator_identity_groups WHERE track_id = ?",
                    "DELETE FROM operator_reid_different_pairs WHERE track_a = ? OR track_b = ?",
                    "DELETE FROM tracked_objects WHERE track_id = ?"
                ] {
                    let stmt = try prepare(sql)
                    defer { sqlite3_finalize(stmt) }
                    bind(expected.trackID.uuidString, stmt, 1)
                    if sqlite3_bind_parameter_count(stmt) == 2 { bind(expected.trackID.uuidString, stmt, 2) }
                    try done(stmt)
                }
                guard sqlite3_changes(db) == 1 else { throw ACTATrackDeletionError.staleSnapshot }
            }
        }
    }

    public func pendingTrackIDs() throws -> [UUID] {
        try lock.withLock {
            let stmt = try prepare("SELECT track_id FROM acta_track_deletion_journal ORDER BY track_id")
            defer { sqlite3_finalize(stmt) }
            var ids: [UUID] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { return ids }
                guard status == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0),
                      let id = UUID(uuidString: String(cString: text)) else { throw error() }
                ids.append(id)
            }
        }
    }

    public func recover(trackID: UUID) throws {
        try lock.withLock {
            try transaction {
                let stmt = try prepare("SELECT images FROM acta_track_deletion_journal WHERE track_id = ?")
                defer { sqlite3_finalize(stmt) }
                bind(trackID.uuidString, stmt, 1)
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { return }
                guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { throw error() }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
                let images = try JSONDecoder().decode([ACTATrackDeletionImage].self, from: data)
                for image in images {
                    guard try !isReferencedElsewhere(image.name, excluding: nil) else {
                        throw ACTATrackDeletionError.sharedImage
                    }
                    let url = try imageURL(image.name)
                    var info = stat()
                    if lstat(url.path, &info) != 0 {
                        if errno == ENOENT { continue }
                        throw ACTATrackDeletionError.invalidImage
                    }
                    guard (info.st_mode & S_IFMT) == S_IFREG else { throw ACTATrackDeletionError.invalidImage }
                    guard try imageDigest(image.name) == image.digest else { throw ACTATrackDeletionError.imageChanged }
                    try FileManager.default.removeItem(at: url)
                }
                let delete = try prepare("DELETE FROM acta_track_deletion_journal WHERE track_id = ?")
                defer { sqlite3_finalize(delete) }
                bind(trackID.uuidString, delete, 1)
                try done(delete)
            }
        }
    }

    private func readSnapshot(trackID: UUID) throws -> ACTATrackDeletionSnapshot {
        var hash = SHA256()
        var count = 0
        for sql in [
            "SELECT * FROM tracked_objects WHERE track_id = ?",
            "SELECT * FROM operator_identity_groups WHERE track_id = ? ORDER BY track_id",
            "SELECT * FROM operator_reid_different_pairs WHERE track_a = ? OR track_b = ? ORDER BY track_a, track_b"
        ] {
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bind(trackID.uuidString, stmt, 1)
            if sqlite3_bind_parameter_count(stmt) == 2 { bind(trackID.uuidString, stmt, 2) }
            hash.update(data: Data(sql.utf8))
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw error() }
                if sql.hasPrefix("SELECT * FROM tracked_objects") { count += 1 }
                for column in 0..<sqlite3_column_count(stmt) {
                    let type = sqlite3_column_type(stmt, column)
                    hash.update(data: Data([UInt8(type)]))
                    let data: Data
                    switch type {
                    case SQLITE_INTEGER:
                        var value = sqlite3_column_int64(stmt, column).bigEndian
                        data = withUnsafeBytes(of: &value) { Data($0) }
                    case SQLITE_FLOAT:
                        var value = sqlite3_column_double(stmt, column).bitPattern.bigEndian
                        data = withUnsafeBytes(of: &value) { Data($0) }
                    case SQLITE_TEXT, SQLITE_BLOB:
                        let length = Int(sqlite3_column_bytes(stmt, column))
                        if length > 0, let bytes = sqlite3_column_blob(stmt, column) {
                            data = Data(bytes: bytes, count: length)
                        } else { data = Data() }
                    default: data = Data()
                    }
                    var length = UInt64(data.count).bigEndian
                    hash.update(data: withUnsafeBytes(of: &length) { Data($0) })
                    hash.update(data: data)
                }
            }
        }
        guard count == 1 else { throw ACTATrackDeletionError.missingTrack }
        let paths = try prepare("SELECT crop_path, cutout_path FROM tracked_objects WHERE track_id = ?")
        defer { sqlite3_finalize(paths) }
        bind(trackID.uuidString, paths, 1)
        guard sqlite3_step(paths) == SQLITE_ROW else { throw error() }
        var names: [String] = []
        for column: Int32 in 0..<2 where sqlite3_column_type(paths, column) != SQLITE_NULL {
            guard sqlite3_column_type(paths, column) == SQLITE_TEXT,
                  let text = sqlite3_column_text(paths, column) else { throw ACTATrackDeletionError.invalidImage }
            let bytes = Data(bytes: text, count: Int(sqlite3_column_bytes(paths, column)))
            guard let name = String(data: bytes, encoding: .utf8), !bytes.contains(0) else {
                throw ACTATrackDeletionError.invalidImage
            }
            names.append(name)
        }
        guard Set(names).count == names.count else { throw ACTATrackDeletionError.invalidImage }
        let images = try names.map { ACTATrackDeletionImage(name: $0, digest: try imageDigest($0)) }
        return ACTATrackDeletionSnapshot(trackID: trackID, imageNames: names, digest: Data(hash.finalize()), images: images)
    }

    private func imageURL(_ name: String) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.utf8.contains(0),
              URL(fileURLWithPath: name).lastPathComponent == name else { throw ACTATrackDeletionError.invalidImage }
        let directory = try imageDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directory.isDirectory == true, directory.isSymbolicLink != true else { throw ACTATrackDeletionError.invalidImage }
        return imageDirectory.appendingPathComponent(name)
    }

    private func imageDigest(_ name: String) throws -> Data {
        let url = try imageURL(name)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 32 * 1024 * 1024 else { throw ACTATrackDeletionError.invalidImage }
        return Data(SHA256.hash(data: try Data(contentsOf: url)))
    }

    private func isReferencedElsewhere(_ name: String, excluding: UUID?) throws -> Bool {
        let stmt = try prepare("SELECT 1 FROM tracked_objects WHERE (crop_path = ? OR cutout_path = ?) AND (? IS NULL OR track_id != ?) LIMIT 1")
        defer { sqlite3_finalize(stmt) }
        bind(name, stmt, 1); bind(name, stmt, 2)
        if let excluding { bind(excluding.uuidString, stmt, 3); bind(excluding.uuidString, stmt, 4) }
        else { sqlite3_bind_null(stmt, 3); sqlite3_bind_null(stmt, 4) }
        let status = sqlite3_step(stmt)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw error() }
        return status == SQLITE_ROW
    }

    private func hasPending(trackID: UUID) throws -> Bool {
        let stmt = try prepare("SELECT 1 FROM acta_track_deletion_journal WHERE track_id = ?")
        defer { sqlite3_finalize(stmt) }
        bind(trackID.uuidString, stmt, 1)
        let status = sqlite3_step(stmt)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw error() }
        return status == SQLITE_ROW
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw error() }
        return stmt
    }

    private func bind(_ value: String, _ stmt: OpaquePointer, _ index: Int32) {
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }

    private func done(_ stmt: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }

    private func error() -> ACTATrackDeletionError {
        .database(String(cString: sqlite3_errmsg(db)))
    }
}
