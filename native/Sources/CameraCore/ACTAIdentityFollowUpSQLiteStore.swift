import Foundation
import SQLite3

/// A local operator follow-up flag, not an identity match or verification.
/// SQLite triggers fence participating profile writers, including other processes.
/// Older applications and unrelated schema-modifying writers must be closed.
public struct ACTAIdentityFollowUpSnapshot: Equatable, Sendable {
    public let identityID: String
    public let flagged: Bool
    fileprivate let hasFlag: Bool
    fileprivate let revision: Data
    fileprivate let profile: Data
}

public struct ACTAIdentityFollowUpRecoverySnapshot: Equatable, Sendable {
    public let snapshot: ACTAIdentityFollowUpSnapshot
    fileprivate let token: String
}

public final class ACTAIdentityFollowUpSQLiteStore: @unchecked Sendable {
    private let database: OpaquePointer
    private let lock = NSLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var pendingToken: String?

    public init(databaseURL: URL) throws {
        guard databaseURL.isFileURL else { throw Failure.unavailable }
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.resolvingSymlinksInPath().standardizedFileURL.path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            throw Failure.unavailable
        }
        database = db
        sqlite3_busy_timeout(db, 3000)
    }

    deinit { sqlite3_close(database) }

    public static func validIdentityID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 45 || $0 == 95 || $0 == 46 || $0 == 58
        }
    }

    public func capture(identityID: String) throws -> ACTAIdentityFollowUpSnapshot? {
        guard Self.validIdentityID(identityID) else { throw Failure.unavailable }
        return try lock.withLock {
            try transaction("BEGIN") {
                guard try pending() == nil else { throw Failure.unavailable }
                return try read(identityID: identityID)
            }
        }
    }

    public func hasPendingRecovery() throws -> Bool {
        try lock.withLock { try transaction("BEGIN") { try pending() != nil } }
    }

    /// Nil means a stale review. A successful write remains blocked until finish succeeds.
    /// The pending marker is committed before the write, so it survives a process exit.
    public func commit(expected: ACTAIdentityFollowUpSnapshot, flagged: Bool) throws
        -> ACTAIdentityFollowUpSnapshot? {
        try lock.withLock {
            let token = UUID().uuidString
            let armed = try transaction("BEGIN IMMEDIATE") {
                guard try pending() == nil else { throw Failure.unavailable }
                guard try read(identityID: expected.identityID) == expected else { return false }
                let statement = try prepare("INSERT INTO ghost_identity_follow_up_pending VALUES (1, ?, ?)")
                defer { sqlite3_finalize(statement) }
                try bind(expected.identityID, to: statement, at: 1)
                try bind(token, to: statement, at: 2)
                let changes = sqlite3_total_changes64(database)
                guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1,
                      sqlite3_total_changes64(database) == changes + 1,
                      try pending()?.token == token else { throw Failure.unavailable }
                return true
            }
            guard armed else { return nil }
            pendingToken = token
            return try transaction("BEGIN IMMEDIATE") {
                guard let current = try pending(), current.id == expected.identityID,
                      current.token == token else { throw Failure.unavailable }
                if try read(identityID: expected.identityID) != expected {
                    try deletePending(token: token)
                    pendingToken = nil
                    return nil
                }
                let statement = try prepare("""
                    INSERT INTO ghost_identity_follow_up(identity_id, flagged) VALUES (?, ?)
                    ON CONFLICT(identity_id) DO UPDATE SET flagged = excluded.flagged
                    """)
                defer { sqlite3_finalize(statement) }
                try bind(expected.identityID, to: statement, at: 1)
                guard sqlite3_bind_int(statement, 2, flagged ? 1 : 0) == SQLITE_OK else { throw Failure.unavailable }
                let changes = sqlite3_total_changes64(database)
                guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1,
                      sqlite3_total_changes64(database) == changes + 2,
                      let after = try read(identityID: expected.identityID),
                      after.flagged == flagged, after.hasFlag, after.profile == expected.profile,
                      after.revision != expected.revision else { throw Failure.unavailable }
                return after
            }
        }
    }

    /// The initiating store verifies and releases its own marker atomically.
    public func finish(_ snapshot: ACTAIdentityFollowUpSnapshot) throws -> Bool {
        try lock.withLock {
            guard let token = pendingToken else { return false }
            let finished = try transaction("BEGIN IMMEDIATE") {
                guard let current = try pending(), current.id == snapshot.identityID,
                      current.token == token, try read(identityID: snapshot.identityID) == snapshot else { return false }
                try deletePending(token: token)
                return true
            }
            if finished { pendingToken = nil }
            return finished
        }
    }

    public func recoverySnapshot() throws -> ACTAIdentityFollowUpRecoverySnapshot? {
        try lock.withLock {
            try transaction("BEGIN") {
                guard let current = try pending() else { return nil }
                guard let snapshot = try read(identityID: current.id) else { throw Failure.unavailable }
                return ACTAIdentityFollowUpRecoverySnapshot(snapshot: snapshot, token: current.token)
            }
        }
    }

    /// Trusted operator UI only: clear exactly the pending marker and snapshot reviewed.
    public func reconcile(_ reviewed: ACTAIdentityFollowUpRecoverySnapshot) throws -> Bool {
        try lock.withLock {
            let reconciled = try transaction("BEGIN IMMEDIATE") {
                guard let current = try pending(), current.id == reviewed.snapshot.identityID,
                      current.token == reviewed.token,
                      try read(identityID: current.id) == reviewed.snapshot else { return false }
                try deletePending(token: current.token)
                return true
            }
            if reconciled { pendingToken = nil }
            return reconciled
        }
    }

    private func pending() throws -> (id: String, token: String)? {
        let statement = try prepare("SELECT identity_id, token FROM ghost_identity_follow_up_pending WHERE singleton = 1")
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, sqlite3_column_type(statement, 0) == SQLITE_TEXT,
              sqlite3_column_type(statement, 1) == SQLITE_TEXT,
              let idBytes = sqlite3_column_text(statement, 0), let tokenBytes = sqlite3_column_text(statement, 1) else {
            throw Failure.unavailable
        }
        let id = String(cString: idBytes), token = String(cString: tokenBytes)
        guard Self.validIdentityID(id), UUID(uuidString: token)?.uuidString == token,
              sqlite3_step(statement) == SQLITE_DONE else { throw Failure.unavailable }
        return (id, token)
    }

    private func deletePending(token: String) throws {
        let statement = try prepare("DELETE FROM ghost_identity_follow_up_pending WHERE singleton = 1 AND token = ?")
        defer { sqlite3_finalize(statement) }
        try bind(token, to: statement, at: 1)
        let changes = sqlite3_total_changes64(database)
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1,
              sqlite3_total_changes64(database) == changes + 1, try pending() == nil else { throw Failure.unavailable }
    }

    private func transaction<T>(_ begin: String, _ operation: () throws -> T) throws -> T {
        try execute(begin)
        var open = true
        defer { if open { try? execute("ROLLBACK") } }
        let value = try operation()
        try execute("COMMIT")
        open = false
        return value
    }

    private struct Field: Encodable {
        let name: String
        let type: Int32
        let bytes: Data
    }

    private func read(identityID: String) throws -> ACTAIdentityFollowUpSnapshot? {
        let triggers = try prepare("""
            SELECT count(*) FROM sqlite_master WHERE type = 'trigger' AND name IN (
                'ghost_identity_follow_up_profile_insert', 'ghost_identity_follow_up_profile_update',
                'ghost_identity_follow_up_profile_delete', 'ghost_identity_follow_up_flag_insert',
                'ghost_identity_follow_up_flag_update', 'ghost_identity_follow_up_flag_delete')
            """)
        defer { sqlite3_finalize(triggers) }
        guard sqlite3_step(triggers) == SQLITE_ROW, sqlite3_column_int(triggers, 0) == 6 else { throw Failure.unavailable }
        let revisionStatement = try prepare("SELECT revision FROM ghost_identity_follow_up_revision WHERE singleton = 1")
        defer { sqlite3_finalize(revisionStatement) }
        guard sqlite3_step(revisionStatement) == SQLITE_ROW,
              sqlite3_column_type(revisionStatement, 0) == SQLITE_BLOB,
              sqlite3_column_bytes(revisionStatement, 0) == 16,
              let revisionBytes = sqlite3_column_blob(revisionStatement, 0) else { throw Failure.unavailable }
        let revision = Data(bytes: revisionBytes, count: 16)
        let statement = try prepare("SELECT * FROM ghost_identities WHERE identity_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(identityID, to: statement, at: 1)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw Failure.unavailable }
        var fields: [Field] = []
        for index in 0..<sqlite3_column_count(statement) {
            guard let rawName = sqlite3_column_name(statement, index) else { throw Failure.unavailable }
            let type = sqlite3_column_type(statement, index)
            let bytes: Data
            switch type {
            case SQLITE_NULL: bytes = Data()
            case SQLITE_INTEGER: bytes = Data(String(sqlite3_column_int64(statement, index)).utf8)
            case SQLITE_FLOAT: bytes = Data(String(sqlite3_column_double(statement, index).bitPattern).utf8)
            case SQLITE_TEXT, SQLITE_BLOB:
                let pointer = type == SQLITE_TEXT
                    ? sqlite3_column_text(statement, index).map { UnsafeRawPointer($0) }
                    : sqlite3_column_blob(statement, index)
                let count = Int(sqlite3_column_bytes(statement, index))
                if count == 0 { bytes = Data() }
                else if let pointer { bytes = Data(bytes: pointer, count: count) }
                else { throw Failure.unavailable }
            default: throw Failure.unavailable
            }
            fields.append(Field(name: String(cString: rawName), type: type, bytes: bytes))
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.unavailable }
        let flags = try prepare("SELECT flagged FROM ghost_identity_follow_up WHERE identity_id = ?")
        defer { sqlite3_finalize(flags) }
        try bind(identityID, to: flags, at: 1)
        let flagStatus = sqlite3_step(flags)
        var flagged = false
        if flagStatus == SQLITE_ROW {
            guard sqlite3_column_type(flags, 0) == SQLITE_INTEGER,
                  (0...1).contains(sqlite3_column_int64(flags, 0)) else { throw Failure.unavailable }
            flagged = sqlite3_column_int(flags, 0) == 1
            guard sqlite3_step(flags) == SQLITE_DONE else { throw Failure.unavailable }
        } else if flagStatus != SQLITE_DONE { throw Failure.unavailable }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return ACTAIdentityFollowUpSnapshot(identityID: identityID, flagged: flagged,
                                           hasFlag: flagStatus == SQLITE_ROW,
                                           revision: revision, profile: try encoder.encode(fields))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw Failure.unavailable }
        return statement
    }

    private func bind(_ text: String, to statement: OpaquePointer, at index: Int32) throws {
        guard sqlite3_bind_text(statement, index, text, -1, transient) == SQLITE_OK else { throw Failure.unavailable }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.unavailable }
    }

    public enum Failure: Error { case unavailable }
}
