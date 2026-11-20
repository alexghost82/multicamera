import Foundation
import SQLite3

/// Experimental, unregistered transaction foundation. The caller must persist a
/// reservation before releasing its source frames and enforce privacy/authorization.
public struct ACTANarrativeCloseReservation: Codable, Equatable, Sendable {
    public let chapterID: UUID
    public let cameraID: UUID
    public let cameraName: String
    public let startedAt: Date
    public let endedAt: Date
    public let frameCount: Int
    public let sightingCount: Int
    public let identityCount: Int
    public let inferenceInput: Data

    public init(chapterID: UUID, cameraID: UUID, cameraName: String, startedAt: Date,
                endedAt: Date, frameCount: Int, sightingCount: Int, identityCount: Int,
                inferenceInput: Data) {
        self.chapterID = chapterID
        self.cameraID = cameraID
        self.cameraName = cameraName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.frameCount = frameCount
        self.sightingCount = sightingCount
        self.identityCount = identityCount
        self.inferenceInput = inferenceInput
    }
}

public enum ACTANarrativeCloseJournalError: Error, Equatable {
    case invalidReservation
    case reservationConflict
    case missingReservation
    case invalidResult
    case database(String)
}

/// Uses the same SQLite database as `LocalTrackingStore`, but has no dependency
/// on its connection. SQLite serializes competing writers across connections.
/// A completed row and the chapter are committed together; no external JPEG is
/// written. Pending input remains sensitive and has no retention policy yet.
public final class ACTANarrativeCloseJournal: @unchecked Sendable {
    private let db: OpaquePointer
    private let databaseURL: URL
    private let lock = NSLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let maxInputBytes = 8 * 1024 * 1024

    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL.standardizedFileURL
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(databaseURL.path, &handle,
                                    SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? String(status)
            if let handle { sqlite3_close(handle) }
            throw ACTANarrativeCloseJournalError.database(message)
        }
        db = handle
        sqlite3_busy_timeout(handle, 3000)
        do {
            try exec("PRAGMA synchronous=FULL")
            try exec("""
                CREATE TABLE IF NOT EXISTS acta_narrative_close_journal (
                    chapter_id TEXT PRIMARY KEY NOT NULL,
                    reservation BLOB NOT NULL,
                    result BLOB
                )
                """)
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    /// Repeating the same reservation is safe; reusing an ID for different input is not.
    public func reserve(_ reservation: ACTANarrativeCloseReservation) throws {
        guard reservation.startedAt.timeIntervalSince1970.isFinite,
              reservation.endedAt.timeIntervalSince1970.isFinite,
              reservation.startedAt <= reservation.endedAt,
              !reservation.cameraName.isEmpty, reservation.cameraName.utf8.count <= 1024,
              !reservation.cameraName.utf8.contains(0),
              !reservation.inferenceInput.isEmpty,
              reservation.inferenceInput.count <= Self.maxInputBytes,
              [reservation.frameCount, reservation.sightingCount, reservation.identityCount]
                .allSatisfy({ $0 >= 0 && $0 <= Int(Int32.max) }) else {
            throw ACTANarrativeCloseJournalError.invalidReservation
        }
        let data = try JSONEncoder().encode(reservation)
        try lock.withLock {
            try transaction {
                if let row = try row(id: reservation.chapterID) {
                    guard try JSONDecoder().decode(ACTANarrativeCloseReservation.self, from: row.reservation) == reservation else {
                        throw ACTANarrativeCloseJournalError.reservationConflict
                    }
                    return
                }
                let stmt = try prepare("INSERT INTO acta_narrative_close_journal(chapter_id, reservation) VALUES(?, ?)")
                defer { sqlite3_finalize(stmt) }
                try bind(reservation.chapterID.uuidString, to: stmt, at: 1)
                try bind(data, to: stmt, at: 2)
                try stepDone(stmt)
            }
        }
    }

    public func reservation(chapterID: UUID) throws -> ACTANarrativeCloseReservation? {
        try lock.withLock {
            guard let row = try row(id: chapterID) else { return nil }
            let reservation = try JSONDecoder().decode(ACTANarrativeCloseReservation.self, from: row.reservation)
            guard reservation.chapterID == chapterID else { throw ACTANarrativeCloseJournalError.reservationConflict }
            return reservation
        }
    }

    public func pendingReservations() throws -> [ACTANarrativeCloseReservation] {
        try lock.withLock {
            let stmt = try prepare("SELECT chapter_id, reservation FROM acta_narrative_close_journal WHERE result IS NULL ORDER BY chapter_id")
            defer { sqlite3_finalize(stmt) }
            var reservations: [ACTANarrativeCloseReservation] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { return reservations }
                guard status == SQLITE_ROW, let id = sqlite3_column_text(stmt, 0),
                      let bytes = sqlite3_column_blob(stmt, 1) else { throw error() }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 1)))
                let reservation = try JSONDecoder().decode(ACTANarrativeCloseReservation.self, from: data)
                guard reservation.chapterID.uuidString == String(cString: id) else {
                    throw ACTANarrativeCloseJournalError.reservationConflict
                }
                reservations.append(reservation)
            }
        }
    }

    /// Commits the immutable generated record, or returns the first committed
    /// result after a retry. Operator edits are never overwritten.
    public func commit(chapterID: UUID, record: ACTANarrativeChapterRecord) throws -> ACTANarrativeChapterRecord {
        try lock.withLock {
            try ACTANarrativeWriteCoordination.withLock(databaseURL: databaseURL) { fd in
            try ACTANarrativeWriteCoordination.advance(fd)
            return try transaction {
                guard let row = try row(id: chapterID) else { throw ACTANarrativeCloseJournalError.missingReservation }
                if let result = row.result {
                    let saved = try JSONDecoder().decode(ACTANarrativeChapterRecord.self, from: result)
                    try verifyChapter(saved)
                    return saved
                }
                let reservation = try JSONDecoder().decode(ACTANarrativeCloseReservation.self, from: row.reservation)
                guard reservation.chapterID == chapterID,
                      record.chapterID == chapterID.uuidString, record.cameraID == reservation.cameraID,
                      record.cameraName == reservation.cameraName, record.startedAt == reservation.startedAt,
                      record.endedAt == reservation.endedAt, record.frameCount == reservation.frameCount,
                      record.sightingCount == reservation.sightingCount, record.identityCount == reservation.identityCount,
                      record.collagePath == nil, record.operatorText == nil,
                      !record.operatorMarked, !record.pinned,
                      !record.aiSummary.isEmpty, record.aiSummary == record.narrative.summary,
                      !record.aiSummary.utf8.contains(0) else {
                    throw ACTANarrativeCloseJournalError.invalidResult
                }
                let narrative = try JSONEncoder().encode(record.narrative)
                let result = try JSONEncoder().encode(record)
                guard result.count <= 1024 * 1024 else { throw ACTANarrativeCloseJournalError.invalidResult }
                guard let json = String(data: narrative, encoding: .utf8) else {
                    throw ACTANarrativeCloseJournalError.invalidResult
                }
                let stmt = try prepare("""
                    INSERT INTO ghost_narrative_chapters(
                      chapter_id, camera_id, camera_name, started_at, ended_at, chapter_json,
                      ai_summary, operator_text, operator_marked, pinned, frame_count, sighting_count,
                      identity_count, collage_path)
                    VALUES(?, ?, ?, ?, ?, ?, ?, NULL, 0, 0, ?, ?, ?, NULL)
                    """)
                defer { sqlite3_finalize(stmt) }
                try bind(record.chapterID, to: stmt, at: 1)
                try bind(record.cameraID.uuidString, to: stmt, at: 2)
                try bind(record.cameraName, to: stmt, at: 3)
                sqlite3_bind_double(stmt, 4, record.startedAt.timeIntervalSince1970)
                sqlite3_bind_double(stmt, 5, record.endedAt.timeIntervalSince1970)
                try bind(json, to: stmt, at: 6)
                try bind(record.aiSummary, to: stmt, at: 7)
                sqlite3_bind_int(stmt, 8, Int32(record.frameCount))
                sqlite3_bind_int(stmt, 9, Int32(record.sightingCount))
                sqlite3_bind_int(stmt, 10, Int32(record.identityCount))
                try stepDone(stmt)

                let update = try prepare("UPDATE acta_narrative_close_journal SET result = ? WHERE chapter_id = ? AND result IS NULL")
                defer { sqlite3_finalize(update) }
                try bind(result, to: update, at: 1)
                try bind(chapterID.uuidString, to: update, at: 2)
                try stepDone(update)
                guard sqlite3_changes(db) == 1 else { throw ACTANarrativeCloseJournalError.invalidResult }
                return record
            }
            }
        }
    }

    public func completed(chapterID: UUID) throws -> ACTANarrativeChapterRecord? {
        try lock.withLock {
            guard let data = try row(id: chapterID)?.result else { return nil }
            let saved = try JSONDecoder().decode(ACTANarrativeChapterRecord.self, from: data)
            guard saved.chapterID == chapterID.uuidString else { throw ACTANarrativeCloseJournalError.invalidResult }
            try verifyChapter(saved)
            return saved
        }
    }

    private func verifyChapter(_ expected: ACTANarrativeChapterRecord) throws {
        let stmt = try prepare("""
            SELECT camera_id, camera_name, started_at, ended_at, chapter_json, ai_summary,
                   frame_count, sighting_count, identity_count, collage_path
            FROM ghost_narrative_chapters WHERE chapter_id = ?
            """)
        defer { sqlite3_finalize(stmt) }
        try bind(expected.chapterID, to: stmt, at: 1)
        let status = sqlite3_step(stmt)
        guard status == SQLITE_ROW else {
            if status == SQLITE_DONE { throw ACTANarrativeCloseJournalError.invalidResult }
            throw error()
        }
        func text(_ index: Int32) -> String? {
            sqlite3_column_text(stmt, index).map { String(cString: $0) }
        }
        guard let json = text(4), let data = json.data(using: .utf8),
              text(0) == expected.cameraID.uuidString, text(1) == expected.cameraName,
              sqlite3_column_double(stmt, 2) == expected.startedAt.timeIntervalSince1970,
              sqlite3_column_double(stmt, 3) == expected.endedAt.timeIntervalSince1970,
              try JSONDecoder().decode(ACTATemporalNarrativeResult.self, from: data) == expected.narrative,
              text(5) == expected.aiSummary,
              sqlite3_column_int64(stmt, 6) == Int64(expected.frameCount),
              sqlite3_column_int64(stmt, 7) == Int64(expected.sightingCount),
              sqlite3_column_int64(stmt, 8) == Int64(expected.identityCount),
              sqlite3_column_type(stmt, 9) == SQLITE_NULL else {
            throw ACTANarrativeCloseJournalError.invalidResult
        }
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { try? exec("ROLLBACK") } }
        let result = try body()
        try exec("COMMIT")
        committed = true
        return result
    }

    private func row(id: UUID) throws -> (reservation: Data, result: Data?)? {
        let stmt = try prepare("SELECT reservation, result FROM acta_narrative_close_journal WHERE chapter_id = ?")
        defer { sqlite3_finalize(stmt) }
        try bind(id.uuidString, to: stmt, at: 1)
        switch sqlite3_step(stmt) {
        case SQLITE_DONE: return nil
        case SQLITE_ROW:
            func blob(_ column: Int32) -> Data {
                let count = Int(sqlite3_column_bytes(stmt, column))
                guard count > 0, let bytes = sqlite3_column_blob(stmt, column) else { return Data() }
                return Data(bytes: bytes, count: count)
            }
            return (blob(0), sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : blob(1))
        default: throw error()
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw error() }
        return stmt
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    private func bind(_ value: String, to stmt: OpaquePointer, at index: Int32) throws {
        guard sqlite3_bind_text(stmt, index, value, -1, transient) == SQLITE_OK else { throw error() }
    }

    private func bind(_ value: Data, to stmt: OpaquePointer, at index: Int32) throws {
        let status = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(stmt, index, bytes.baseAddress, Int32(bytes.count), transient)
        }
        guard status == SQLITE_OK else { throw error() }
    }

    private func stepDone(_ stmt: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }

    private func error() -> ACTANarrativeCloseJournalError {
        .database(String(cString: sqlite3_errmsg(db)))
    }
}
