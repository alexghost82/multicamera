import Foundation
import CryptoKit
import SQLite3

struct IdentityStoreSnapshot: Equatable, Sendable {
    let digest: Data
}

enum IdentitySnapshotHasher {
    static func snapshot(database: OpaquePointer, queries: [String]) throws -> IdentityStoreSnapshot {
        var hash = SHA256()
        hash.update(data: Data("ACTA identity snapshot v1".utf8))

        func number(_ value: UInt64) {
            var value = value.bigEndian
            withUnsafeBytes(of: &value) { hash.update(bufferPointer: $0) }
        }
        func byte(_ value: UInt8) {
            var value = value
            withUnsafeBytes(of: &value) { hash.update(bufferPointer: $0) }
        }
        func error() -> CameraFeatureStoreError {
            .database(String(cString: sqlite3_errmsg(database)))
        }

        number(UInt64(queries.count))
        for query in queries {
            byte(0x54)
            let queryBytes = Data(query.utf8)
            number(UInt64(queryBytes.count))
            hash.update(data: queryBytes)
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(database, query, -1, &prepared, nil) == SQLITE_OK,
                  let statement = prepared else {
                let failure = error()
                if let prepared { sqlite3_finalize(prepared) }
                throw failure
            }
            var finalized = false
            defer { if !finalized { sqlite3_finalize(statement) } }
            let columnCount = sqlite3_column_count(statement)
            number(UInt64(columnCount))
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw error() }
                byte(0x52)
                for column in 0..<columnCount {
                    let type = sqlite3_column_type(statement, column)
                    switch type {
                    case SQLITE_NULL:
                        byte(0)
                        number(0)
                    case SQLITE_INTEGER:
                        byte(1)
                        number(8)
                        number(UInt64(bitPattern: sqlite3_column_int64(statement, column)))
                    case SQLITE_FLOAT:
                        byte(2)
                        number(8)
                        number(sqlite3_column_double(statement, column).bitPattern)
                    case SQLITE_TEXT, SQLITE_BLOB:
                        byte(type == SQLITE_TEXT ? 3 : 4)
                        let pointer: UnsafeRawPointer?
                        if type == SQLITE_TEXT {
                            pointer = sqlite3_column_text(statement, column).map(UnsafeRawPointer.init)
                        } else {
                            pointer = sqlite3_column_blob(statement, column)
                        }
                        guard sqlite3_errcode(database) != SQLITE_NOMEM else { throw error() }
                        let count = Int(sqlite3_column_bytes(statement, column))
                        guard sqlite3_errcode(database) != SQLITE_NOMEM,
                              type != SQLITE_TEXT || pointer != nil,
                              count == 0 || pointer != nil else { throw error() }
                        number(UInt64(count))
                        if let pointer, count > 0 {
                            hash.update(bufferPointer: UnsafeRawBufferPointer(start: pointer, count: count))
                        }
                    default:
                        throw error()
                    }
                }
            }
            byte(0x45)
            let status = sqlite3_finalize(statement)
            finalized = true
            guard status == SQLITE_OK else { throw error() }
        }
        return IdentityStoreSnapshot(digest: Data(hash.finalize()))
    }
}

public enum CameraFeatureJobStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case completed
    case failed
}

public struct OperationsAlertReview: Codable, Equatable, Identifiable, Sendable {
    public enum Priority: String, Codable, CaseIterable, Sendable { case normal, critical }
    public enum Status: String, Codable, CaseIterable, Sendable { case open, acknowledged, resolved }

    public let alertID: UUID
    public let priority: Priority
    public let status: Status
    public let note: String
    public let updatedAt: Date
    public var id: UUID { alertID }

    public init(alertID: UUID, priority: Priority, status: Status, note: String, updatedAt: Date) {
        self.alertID = alertID
        self.priority = priority
        self.status = status
        self.note = note
        self.updatedAt = updatedAt
    }
}

/// A single database snapshot of alert reviews and acknowledgements.
public struct OperationsAlertReadState: Sendable {
    public let reviews: [UUID: OperationsAlertReview]
    public let acknowledgements: [UUID: Date]
}

public struct CameraFeatureJob: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let featureID: CameraFeatureID
    public let cameraID: UUID?
    public let status: CameraFeatureJobStatus
    public let attempts: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let notBefore: Date
    public let payloadJSON: String?
    public let resultJSON: String?
    public let lastError: String?
}

public struct DescriptionJobRevision: Equatable, Sendable {
    public let id: UUID
    public let status: CameraFeatureJobStatus
    public let attempts: Int
    public let updatedAt: Date
    public let revision: String
}

public struct DescriptionRetryReceipt: Equatable, Sendable {
    public let jobID: UUID
    public let operationID: UUID

    public init(jobID: UUID, operationID: UUID) {
        self.jobID = jobID
        self.operationID = operationID
    }
}

public struct CameraOperatorAction: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case describeTracks = "describe_tracks" }
    public enum Status: String, Codable, Sendable { case pending, applied, rejected }

    public let id: UUID
    public let kind: Kind
    public let trackIDs: [UUID]
    public let createdAt: Date
    public internal(set) var status: Status
    public internal(set) var reviewedAt: Date?
    public internal(set) var jobIDs: [UUID]
}

public enum CameraFeatureStoreError: LocalizedError {
    case database(String)
    case invalidPendingLimit
    case invalidPayload
    case featureDisabled(CameraFeatureID)
    case pendingLimitReached(Int)
    case jobNotFound(UUID)
    case jobNotRunning(UUID)
    case jobNotFailed(UUID)
    case invalidOperationsAlertReview
    case invalidOperatorAction
    case operatorActionNotPending(UUID)
    case unsupportedSchema(Int)
    case invalidIdentityProposal
    case identityCannotLink
    case identityProposalNotPending(UUID)
    case identityCategoryConflict
    case identityAlreadyLinked
    case identityProposalNotFound(UUID)
    case identityProposalNotUndoable(UUID)
    case identityProposalAlreadyUndone(UUID)
    case identityReviewStale
    case descriptionJobStale

    public var errorDescription: String? {
        switch self {
        case .database(let message): "Feature store database error: \(message)"
        case .invalidPendingLimit: "The feature job limit must be greater than zero."
        case .invalidPayload: "Feature job payload must be valid JSON under 64 KB."
        case .featureDisabled(let feature): "Feature \(feature.rawValue) is disabled."
        case .pendingLimitReached(let limit): "The feature job queue is full (limit \(limit))."
        case .jobNotFound(let id): "Feature job \(id) was not found."
        case .jobNotRunning(let id): "Feature job \(id) is not running."
        case .jobNotFailed(let id): "Feature job \(id) is not failed."
        case .invalidOperationsAlertReview: "Alert review requires a valid timestamp, a note under 2000 characters and a nonempty resolution note."
        case .invalidOperatorAction: "Operator actions require one to four distinct existing evidence tracks."
        case .operatorActionNotPending(let id): "Operator action \(id) is not awaiting confirmation."
        case .unsupportedSchema(let version): "Feature store schema version \(version) is newer than this app supports."
        case .invalidIdentityProposal: "Identity proposals require distinct tracks, a supported category and a valid cosine distance."
        case .identityCannotLink: "These tracks have an explicit cannot-link decision."
        case .identityProposalNotPending(let id): "Identity proposal \(id) is no longer pending review."
        case .identityCategoryConflict: "Tracks from different categories cannot share an identity."
        case .identityAlreadyLinked: "These tracks already share a proposed identity; detach or undo that decision first."
        case .identityProposalNotFound(let id): "Identity proposal \(id) was not found."
        case .identityProposalNotUndoable(let id): "Identity proposal \(id) has not been accepted."
        case .identityProposalAlreadyUndone(let id): "Identity proposal \(id) was already undone."
        case .identityReviewStale: "Identity review evidence or graph changed; refresh before reviewing."
        case .descriptionJobStale: "Description job or feature policy changed; refresh before retrying."
        }
    }
}

public final class CameraFeatureStore: @unchecked Sendable {
    public static let schemaVersion = 7
    public static let defaultPendingLimit = 500
    private static let maximumPayloadBytes = 64 * 1024
    private static let maximumErrorCharacters = 1000

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CameraWall/feature-jobs.sqlite3")
    }

    public let pendingLimit: Int
    private let database: OpaquePointer
    private let lock = NSRecursiveLock()

    public init(url: URL = CameraFeatureStore.defaultURL,
                pendingLimit: Int = CameraFeatureStore.defaultPendingLimit) throws {
        guard pendingLimit > 0 else { throw CameraFeatureStoreError.invalidPendingLimit }
        self.pendingLimit = pendingLimit

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var handle: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite open failed (\(result))"
            if let handle { sqlite3_close(handle) }
            throw CameraFeatureStoreError.database(message)
        }

        database = handle
        sqlite3_busy_timeout(database, 3000)
        do {
            let version = try scalarInt("PRAGMA user_version")
            guard version <= Self.schemaVersion else {
                throw CameraFeatureStoreError.unsupportedSchema(version)
            }
            if version == 0 {
                try transaction {
                    try execute("""
                        CREATE TABLE feature_jobs (
                            id TEXT PRIMARY KEY NOT NULL,
                            feature_id TEXT NOT NULL,
                            camera_id TEXT,
                            status TEXT NOT NULL CHECK(status IN ('queued','running','completed','failed')),
                            attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts >= 0),
                            created_at REAL NOT NULL,
                            updated_at REAL NOT NULL,
                            not_before REAL NOT NULL,
                            payload_json TEXT,
                            result_json TEXT,
                            last_error TEXT
                        )
                        """)
                    try execute("CREATE INDEX feature_jobs_queue ON feature_jobs(status, not_before, created_at)")
                    try execute("PRAGMA user_version = 1")
                }
            }
            if version < 2 {
                try transaction {
                    try execute("""
                        CREATE TABLE cross_camera_identities (
                            identity_id TEXT PRIMARY KEY NOT NULL,
                            category TEXT NOT NULL CHECK(category IN ('person','vehicle')),
                            created_at REAL NOT NULL
                        )
                        """)
                    try execute("""
                        CREATE TABLE cross_camera_identity_links (
                            track_id TEXT PRIMARY KEY NOT NULL,
                            identity_id TEXT NOT NULL,
                            linked_at REAL NOT NULL
                        )
                        """)
                    try execute("CREATE INDEX cross_camera_identity_links_identity ON cross_camera_identity_links(identity_id)")
                    try execute("""
                        CREATE TABLE cross_camera_identity_proposals (
                            id TEXT PRIMARY KEY NOT NULL,
                            track_a TEXT NOT NULL,
                            track_b TEXT NOT NULL,
                            category TEXT NOT NULL CHECK(category IN ('person','vehicle')),
                            cosine_distance REAL NOT NULL CHECK(cosine_distance >= 0 AND cosine_distance <= 2),
                            status TEXT NOT NULL CHECK(status IN ('pending','accepted','rejected')),
                            created_at REAL NOT NULL,
                            reviewed_at REAL,
                            identity_id TEXT,
                            UNIQUE(track_a, track_b)
                        )
                        """)
                    try execute("CREATE INDEX cross_camera_identity_proposals_status ON cross_camera_identity_proposals(status, created_at)")
                    try execute("""
                        CREATE TABLE cross_camera_identity_cannot_links (
                            track_a TEXT NOT NULL,
                            track_b TEXT NOT NULL,
                            created_at REAL NOT NULL,
                            PRIMARY KEY(track_a, track_b)
                        )
                        """)
                    try execute("""
                        CREATE TABLE cross_camera_identity_audit (
                            id TEXT PRIMARY KEY NOT NULL,
                            proposal_id TEXT NOT NULL,
                            action TEXT NOT NULL CHECK(action IN ('proposed','accepted','rejected')),
                            track_a TEXT NOT NULL,
                            track_b TEXT NOT NULL,
                            identity_id TEXT,
                            occurred_at REAL NOT NULL
                        )
                        """)
                    try execute("CREATE INDEX cross_camera_identity_audit_time ON cross_camera_identity_audit(occurred_at)")
                    try execute("PRAGMA user_version = 2")
                }
            }
            if version < 3 {
                try transaction {
                    try execute("""
                        CREATE TABLE cross_camera_identity_undos (
                            proposal_id TEXT PRIMARY KEY NOT NULL,
                            undone_at REAL NOT NULL
                        )
                        """)
                    try execute("ALTER TABLE cross_camera_identity_audit RENAME TO cross_camera_identity_audit_v2")
                    try execute("""
                        CREATE TABLE cross_camera_identity_audit (
                            id TEXT PRIMARY KEY NOT NULL,
                            proposal_id TEXT NOT NULL,
                            action TEXT NOT NULL CHECK(action IN ('proposed','accepted','rejected','undone')),
                            track_a TEXT NOT NULL,
                            track_b TEXT NOT NULL,
                            identity_id TEXT,
                            occurred_at REAL NOT NULL
                        )
                        """)
                    try execute("""
                        INSERT INTO cross_camera_identity_audit (
                            id, proposal_id, action, track_a, track_b, identity_id, occurred_at
                        ) SELECT id, proposal_id, action, track_a, track_b, identity_id, occurred_at
                          FROM cross_camera_identity_audit_v2
                        """)
                    try execute("DROP TABLE cross_camera_identity_audit_v2")
                    try execute("CREATE INDEX cross_camera_identity_audit_time ON cross_camera_identity_audit(occurred_at)")
                    try execute("PRAGMA user_version = 3")
                }
            }
            if version < 4 {
                try transaction {
                    try execute("""
                        CREATE TABLE operations_alert_acknowledgements (
                            alert_id TEXT PRIMARY KEY NOT NULL,
                            acknowledged_at REAL NOT NULL
                        )
                        """)
                    try execute("PRAGMA user_version = 4")
                }
            }
            if version < 5 {
                try transaction {
                    try execute("""
                        CREATE TABLE operator_action_proposals (
                            id TEXT PRIMARY KEY NOT NULL,
                            status TEXT NOT NULL CHECK(status IN ('pending','applied','rejected')),
                            created_at REAL NOT NULL,
                            document_json TEXT NOT NULL
                        )
                        """)
                    try execute("""
                        CREATE TABLE operator_action_audit (
                            sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                            proposal_id TEXT NOT NULL,
                            document_json TEXT NOT NULL
                        )
                        """)
                    try execute("PRAGMA user_version = 5")
                }
            }
            if version < 6 {
                try transaction {
                    try execute("""
                        CREATE TABLE operations_alert_reviews (
                            alert_id TEXT PRIMARY KEY NOT NULL,
                            document_json TEXT NOT NULL
                        )
                        """)
                    try execute("""
                        CREATE TABLE operations_alert_review_audit (
                            sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                            alert_id TEXT NOT NULL,
                            document_json TEXT NOT NULL
                        )
                        """)
                    try execute("CREATE INDEX operations_alert_review_audit_id ON operations_alert_review_audit(alert_id, sequence)")
                    try execute("PRAGMA user_version = 6")
                }
            }
            if version < 7 {
                try transaction {
                    try execute("""
                        CREATE TABLE IF NOT EXISTS description_job_revisions (
                            job_id TEXT PRIMARY KEY NOT NULL,
                            revision TEXT NOT NULL
                        )
                        """)
                    try execute("""
                        INSERT OR IGNORE INTO description_job_revisions (job_id, revision)
                        SELECT id, lower(hex(randomblob(16))) FROM feature_jobs
                        """)
                    try execute("""
                        CREATE TRIGGER IF NOT EXISTS description_job_revision_insert AFTER INSERT ON feature_jobs
                        BEGIN
                            INSERT OR REPLACE INTO description_job_revisions (job_id, revision)
                            VALUES (NEW.id, lower(hex(randomblob(16))));
                        END
                        """)
                    try execute("""
                        CREATE TRIGGER IF NOT EXISTS description_job_revision_update AFTER UPDATE ON feature_jobs
                        BEGIN
                            DELETE FROM description_job_revisions WHERE job_id=OLD.id;
                            INSERT OR REPLACE INTO description_job_revisions (job_id, revision)
                            VALUES (NEW.id, lower(hex(randomblob(16))));
                        END
                        """)
                    try execute("""
                        CREATE TRIGGER IF NOT EXISTS description_job_revision_delete AFTER DELETE ON feature_jobs
                        BEGIN
                            DELETE FROM description_job_revisions WHERE job_id=OLD.id;
                        END
                        """)
                    try execute("""
                        CREATE TABLE IF NOT EXISTS description_retry_receipts (
                            operation_id TEXT PRIMARY KEY NOT NULL,
                            job_id TEXT NOT NULL
                        )
                        """)
                    try execute("PRAGMA user_version = 7")
                }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    deinit {
        sqlite3_close(database)
    }

    @discardableResult
    public func enqueue(
        featureID: CameraFeatureID,
        cameraID: UUID? = nil,
        payloadJSON: String? = nil,
        preferences: CameraFeaturePreferences,
        at time: Date = Date()
    ) throws -> CameraFeatureJob {
        try preferences.validate()
        guard preferences.enabledFeatures.contains(featureID) else {
            throw CameraFeatureStoreError.featureDisabled(featureID)
        }
        try Self.validateJSON(payloadJSON)

        return try locked {
            try transaction {
                let pending = try scalarInt(
                    "SELECT COUNT(*) FROM feature_jobs WHERE status IN ('queued','running')"
                )
                guard pending < pendingLimit else {
                    throw CameraFeatureStoreError.pendingLimitReached(pendingLimit)
                }

                let id = UUID()
                let timestamp = time.timeIntervalSince1970
                let statement = try prepare("""
                    INSERT INTO feature_jobs (
                        id, feature_id, camera_id, status, attempts,
                        created_at, updated_at, not_before, payload_json
                    ) VALUES (?, ?, ?, 'queued', 0, ?, ?, ?, ?)
                    """)
                defer { sqlite3_finalize(statement) }
                bind(id.uuidString, at: 1, to: statement)
                bind(featureID.rawValue, at: 2, to: statement)
                bind(cameraID?.uuidString, at: 3, to: statement)
                sqlite3_bind_double(statement, 4, timestamp)
                sqlite3_bind_double(statement, 5, timestamp)
                sqlite3_bind_double(statement, 6, timestamp)
                bind(payloadJSON, at: 7, to: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
                return try job(id: id)
            }
        }
    }

    public func claimNext(featureID: CameraFeatureID? = nil, at time: Date = Date()) throws -> CameraFeatureJob? {
        try locked {
            try transaction {
                let query = featureID == nil
                    ? "SELECT id FROM feature_jobs WHERE status='queued' AND not_before <= ? ORDER BY created_at ASC, id ASC LIMIT 1"
                    : "SELECT id FROM feature_jobs WHERE status='queued' AND not_before <= ? AND feature_id=? ORDER BY created_at ASC, id ASC LIMIT 1"
                let statement = try prepare(query)
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_double(statement, 1, time.timeIntervalSince1970)
                if let featureID { bind(featureID.rawValue, at: 2, to: statement) }
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return nil }
                guard result == SQLITE_ROW, let id = UUID(uuidString: text(statement, 0)) else {
                    throw databaseError()
                }

                let update = try prepare("""
                    UPDATE feature_jobs SET status='running', attempts=attempts+1, updated_at=?
                    WHERE id=? AND status='queued'
                    """)
                defer { sqlite3_finalize(update) }
                sqlite3_bind_double(update, 1, time.timeIntervalSince1970)
                bind(id.uuidString, at: 2, to: update)
                guard sqlite3_step(update) == SQLITE_DONE, sqlite3_changes(database) == 1 else {
                    throw databaseError()
                }
                return try job(id: id)
            }
        }
    }

    public func claimNextBatch(featureID: CameraFeatureID,
                               limit: Int = 4,
                               at time: Date = Date()) throws -> [CameraFeatureJob] {
        guard limit > 0 else { throw CameraFeatureStoreError.invalidPendingLimit }
        return try locked {
            try transaction {
                let boundedLimit = min(4, limit)
                let statement = try prepare("""
                    SELECT id FROM feature_jobs
                    WHERE status='queued' AND not_before <= ? AND feature_id=?
                    ORDER BY created_at ASC, id ASC LIMIT ?
                    """)
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_double(statement, 1, time.timeIntervalSince1970)
                bind(featureID.rawValue, at: 2, to: statement)
                sqlite3_bind_int(statement, 3, Int32(boundedLimit))
                var ids: [UUID] = []
                while true {
                    let result = sqlite3_step(statement)
                    if result == SQLITE_DONE { break }
                    guard result == SQLITE_ROW, let id = UUID(uuidString: text(statement, 0)) else {
                        throw databaseError()
                    }
                    ids.append(id)
                }

                var claimed: [CameraFeatureJob] = []
                for id in ids {
                    let update = try prepare("""
                        UPDATE feature_jobs SET status='running', attempts=attempts+1, updated_at=?
                        WHERE id=? AND status='queued'
                        """)
                    defer { sqlite3_finalize(update) }
                    sqlite3_bind_double(update, 1, time.timeIntervalSince1970)
                    bind(id.uuidString, at: 2, to: update)
                    guard sqlite3_step(update) == SQLITE_DONE, sqlite3_changes(database) == 1 else {
                        throw databaseError()
                    }
                    claimed.append(try job(id: id))
                }
                return claimed
            }
        }
    }

    @discardableResult
    public func recoverInterruptedJobs(
        featureID: CameraFeatureID,
        staleBefore: Date,
        maximumAttempts: Int = 3,
        at time: Date = Date()
    ) throws -> Int {
        guard maximumAttempts > 0 else { throw CameraFeatureStoreError.invalidPendingLimit }
        return try locked {
            let statement = try prepare("""
                UPDATE feature_jobs
                SET status=CASE WHEN attempts >= ? THEN 'failed' ELSE 'queued' END,
                    updated_at=?, not_before=?, last_error='Interrupted before completion'
                WHERE feature_id=? AND status='running' AND updated_at < ?
                """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(maximumAttempts))
            sqlite3_bind_double(statement, 2, time.timeIntervalSince1970)
            sqlite3_bind_double(statement, 3, time.timeIntervalSince1970)
            bind(featureID.rawValue, at: 4, to: statement)
            sqlite3_bind_double(statement, 5, staleBefore.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
            return Int(sqlite3_changes(database))
        }
    }

    public func complete(jobID: UUID, resultJSON: String? = nil, at time: Date = Date()) throws {
        try Self.validateJSON(resultJSON)
        try updateRunningJob(jobID: jobID) { statement in
            sqlite3_bind_double(statement, 1, time.timeIntervalSince1970)
            bind(resultJSON, at: 2, to: statement)
            bind(jobID.uuidString, at: 3, to: statement)
        } sql: {
            "UPDATE feature_jobs SET status='completed', updated_at=?, result_json=?, last_error=NULL WHERE id=? AND status='running'"
        }
    }

    @discardableResult
    public func fail(
        jobID: UUID,
        message: String,
        retryAt: Date? = nil,
        maximumAttempts: Int = 3,
        at time: Date = Date()
    ) throws -> CameraFeatureJobStatus {
        guard maximumAttempts > 0 else { throw CameraFeatureStoreError.invalidPendingLimit }
        return try locked {
            try transaction {
                let current = try job(id: jobID)
                guard current.status == .running else {
                    throw CameraFeatureStoreError.jobNotRunning(jobID)
                }
                let shouldRetry = retryAt != nil && current.attempts < maximumAttempts
                let status: CameraFeatureJobStatus = shouldRetry ? .queued : .failed
                let statement = try prepare("""
                    UPDATE feature_jobs SET status=?, updated_at=?, not_before=?, last_error=?
                    WHERE id=? AND status='running'
                    """)
                defer { sqlite3_finalize(statement) }
                bind(status.rawValue, at: 1, to: statement)
                sqlite3_bind_double(statement, 2, time.timeIntervalSince1970)
                sqlite3_bind_double(statement, 3, (shouldRetry ? retryAt : time)?.timeIntervalSince1970 ?? time.timeIntervalSince1970)
                bind(String(message.prefix(Self.maximumErrorCharacters)), at: 4, to: statement)
                bind(jobID.uuidString, at: 5, to: statement)
                guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1 else {
                    throw CameraFeatureStoreError.jobNotRunning(jobID)
                }
                return status
            }
        }
    }

    public func proposeDescriptionAction(
        trackIDs: [UUID], allowedTrackIDs: Set<UUID>, preferences: CameraFeaturePreferences,
        at time: Date = Date()
    ) throws -> CameraOperatorAction {
        try requireEnabled(.operatorActions, preferences: preferences)
        guard (1...4).contains(trackIDs.count), Set(trackIDs).count == trackIDs.count,
              Set(trackIDs).isSubset(of: allowedTrackIDs) else { throw CameraFeatureStoreError.invalidOperatorAction }
        return try locked {
            _ = try purgeExpired(retentionDays: preferences.retentionDays, now: time)
            return try transaction {
                guard try scalarInt("SELECT COUNT(*) FROM operator_action_proposals") < 1000 else {
                    throw CameraFeatureStoreError.pendingLimitReached(1000)
                }
                let action = CameraOperatorAction(
                    id: UUID(), kind: .describeTracks, trackIDs: trackIDs, createdAt: time,
                    status: .pending, reviewedAt: nil, jobIDs: []
                )
                try writeOperatorAction(action, inserting: true)
                return action
            }
        }
    }

    public func operatorActions(limit: Int = 100) throws -> [CameraOperatorAction] {
        try locked {
            let statement = try prepare("""
                SELECT document_json FROM operator_action_proposals
                ORDER BY CASE status WHEN 'pending' THEN 0 ELSE 1 END, created_at DESC, id ASC LIMIT ?
                """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(min(1000, max(1, limit))))
            return try readOperatorActions(statement)
        }
    }

    public func operatorActionAudit(id: UUID) throws -> [CameraOperatorAction] {
        try locked {
            let statement = try prepare("""
                SELECT document_json FROM operator_action_audit WHERE proposal_id=? ORDER BY sequence ASC
                """)
            defer { sqlite3_finalize(statement) }
            bind(id.uuidString, at: 1, to: statement)
            return try readOperatorActions(statement)
        }
    }

    public func reviewOperatorAction(
        id: UUID, accept: Bool, existingTrackIDs: Set<UUID>, preferences: CameraFeaturePreferences,
        at time: Date = Date()
    ) throws -> CameraOperatorAction {
        try requireEnabled(.operatorActions, preferences: preferences)
        return try locked {
            try transaction {
                let statement = try prepare("SELECT document_json FROM operator_action_proposals WHERE id=?")
                defer { sqlite3_finalize(statement) }
                bind(id.uuidString, at: 1, to: statement)
                    guard var action = try readOperatorActions(statement).first, action.status == .pending,
                        time.timeIntervalSince(action.createdAt) >= 0,
                        time.timeIntervalSince(action.createdAt) <= Double(preferences.retentionDays) * 86_400 else {
                    throw CameraFeatureStoreError.operatorActionNotPending(id)
                }
                if accept {
                    try requireEnabled(.visionDescriptions, preferences: preferences)
                    guard Set(action.trackIDs).isSubset(of: existingTrackIDs) else {
                        throw CameraFeatureStoreError.invalidOperatorAction
                    }
                    var existingJobs: [UUID: UUID] = [:]
                    let pendingDescriptions = try prepare("""
                        SELECT id, payload_json FROM feature_jobs
                        WHERE feature_id=? AND status IN ('queued','running') ORDER BY created_at ASC, id ASC
                        """)
                    defer { sqlite3_finalize(pendingDescriptions) }
                    bind(CameraFeatureID.visionDescriptions.rawValue, at: 1, to: pendingDescriptions)
                    while true {
                        let step = sqlite3_step(pendingDescriptions)
                        if step == SQLITE_DONE { break }
                        guard step == SQLITE_ROW else { throw databaseError() }
                        if let jobID = UUID(uuidString: text(pendingDescriptions, 0)),
                           let payload = try? JSONDecoder().decode([String: String].self, from: Data(text(pendingDescriptions, 1).utf8)),
                           let trackID = payload["trackID"].flatMap(UUID.init(uuidString:)),
                           existingJobs[trackID] == nil {
                            existingJobs[trackID] = jobID
                        }
                    }
                    let pending = try scalarInt("SELECT COUNT(*) FROM feature_jobs WHERE status IN ('queued','running')")
                    let newJobCount = action.trackIDs.filter { existingJobs[$0] == nil }.count
                    guard pending + newJobCount <= pendingLimit else {
                        throw CameraFeatureStoreError.pendingLimitReached(pendingLimit)
                    }
                    for trackID in action.trackIDs {
                        if let jobID = existingJobs[trackID] {
                            action.jobIDs.append(jobID)
                            continue
                        }
                        let jobID = UUID()
                        let payload = String(decoding: try JSONEncoder().encode(["trackID": trackID.uuidString]), as: UTF8.self)
                        let insert = try prepare("""
                            INSERT INTO feature_jobs (
                                id, feature_id, status, attempts, created_at, updated_at, not_before, payload_json
                            ) VALUES (?, ?, 'queued', 0, ?, ?, ?, ?)
                            """)
                        defer { sqlite3_finalize(insert) }
                        bind(jobID.uuidString, at: 1, to: insert)
                        bind(CameraFeatureID.visionDescriptions.rawValue, at: 2, to: insert)
                        sqlite3_bind_double(insert, 3, time.timeIntervalSince1970)
                        sqlite3_bind_double(insert, 4, time.timeIntervalSince1970)
                        sqlite3_bind_double(insert, 5, time.timeIntervalSince1970)
                        bind(payload, at: 6, to: insert)
                        guard sqlite3_step(insert) == SQLITE_DONE else { throw databaseError() }
                        action.jobIDs.append(jobID)
                    }
                }
                action.status = accept ? .applied : .rejected
                action.reviewedAt = time
                try writeOperatorAction(action, inserting: false)
                return action
            }
        }
    }

    private func readOperatorActions(_ statement: OpaquePointer) throws -> [CameraOperatorAction] {
        var actions: [CameraOperatorAction] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return actions }
            guard step == SQLITE_ROW,
                  let action = try? JSONDecoder().decode(CameraOperatorAction.self, from: Data(text(statement, 0).utf8)) else {
                throw databaseError()
            }
            actions.append(action)
        }
    }

    private func writeOperatorAction(_ action: CameraOperatorAction, inserting: Bool) throws {
        let json = String(decoding: try JSONEncoder().encode(action), as: UTF8.self)
        let statement = try prepare(inserting
            ? "INSERT INTO operator_action_proposals (status, document_json, id, created_at) VALUES (?, ?, ?, ?)"
            : "UPDATE operator_action_proposals SET status=?, document_json=? WHERE id=? AND status='pending'")
        defer { sqlite3_finalize(statement) }
        bind(action.status.rawValue, at: 1, to: statement)
        bind(json, at: 2, to: statement)
        bind(action.id.uuidString, at: 3, to: statement)
        if inserting { sqlite3_bind_double(statement, 4, action.createdAt.timeIntervalSince1970) }
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1 else { throw databaseError() }
        let audit = try prepare("INSERT INTO operator_action_audit (proposal_id, document_json) VALUES (?, ?)")
        defer { sqlite3_finalize(audit) }
        bind(action.id.uuidString, at: 1, to: audit)
        bind(json, at: 2, to: audit)
        guard sqlite3_step(audit) == SQLITE_DONE else { throw databaseError() }
    }

    public func retryFailedJob(
        id: UUID, preferences: CameraFeaturePreferences, at time: Date = Date()
    ) throws {
        try preferences.validate()
        try locked {
            try transaction {
                let current = try job(id: id)
                guard preferences.enabledFeatures.contains(current.featureID) else {
                    throw CameraFeatureStoreError.featureDisabled(current.featureID)
                }
                guard current.status == .failed else { throw CameraFeatureStoreError.jobNotFailed(id) }
                let pending = try scalarInt("SELECT COUNT(*) FROM feature_jobs WHERE status IN ('queued','running')")
                guard pending < pendingLimit else { throw CameraFeatureStoreError.pendingLimitReached(pendingLimit) }
                let statement = try prepare("""
                    UPDATE feature_jobs SET status='queued', updated_at=?, not_before=?, result_json=NULL
                    WHERE id=? AND status='failed'
                    """)
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_double(statement, 1, time.timeIntervalSince1970)
                sqlite3_bind_double(statement, 2, time.timeIntervalSince1970)
                bind(id.uuidString, at: 3, to: statement)
                guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1 else {
                    throw CameraFeatureStoreError.jobNotFailed(id)
                }
            }
        }
    }

    /// Metadata only. The revision changes on every job row update, including other connections.
    func descriptionJobRevision(id: UUID) throws -> DescriptionJobRevision {
        try locked { try readDescriptionJobRevision(id: id) }
    }

    /// The caller must hold the feature-policy lock and perform authorization separately.
    func retryDescriptionJob(
        expected: DescriptionJobRevision, preferences: CameraFeaturePreferences,
        operationID: UUID, at time: Date = Date(), beforeCommit: () throws -> Void
    ) throws -> DescriptionRetryReceipt {
        try preferences.validate()
        return try locked {
            try transaction {
                guard preferences.enabledFeatures.contains(.visionDescriptions) else {
                    throw CameraFeatureStoreError.featureDisabled(.visionDescriptions)
                }
                let current = try readDescriptionJobRevision(id: expected.id)
                guard current == expected else { throw CameraFeatureStoreError.descriptionJobStale }
                guard current.status == .failed else { throw CameraFeatureStoreError.jobNotFailed(expected.id) }
                let pending = try scalarInt("SELECT COUNT(*) FROM feature_jobs WHERE status IN ('queued','running')")
                guard pending < pendingLimit else { throw CameraFeatureStoreError.pendingLimitReached(pendingLimit) }
                try beforeCommit()
                let update = try prepare("""
                    UPDATE feature_jobs SET status='queued', updated_at=?, not_before=?, result_json=NULL
                    WHERE id=? AND feature_id=? AND status='failed'
                    """)
                defer { sqlite3_finalize(update) }
                sqlite3_bind_double(update, 1, time.timeIntervalSince1970)
                sqlite3_bind_double(update, 2, time.timeIntervalSince1970)
                bind(expected.id.uuidString, at: 3, to: update)
                bind(CameraFeatureID.visionDescriptions.rawValue, at: 4, to: update)
                guard sqlite3_step(update) == SQLITE_DONE, sqlite3_changes(database) == 1 else {
                    throw CameraFeatureStoreError.descriptionJobStale
                }
                let receipt = try prepare("INSERT INTO description_retry_receipts (operation_id, job_id) VALUES (?, ?)")
                defer { sqlite3_finalize(receipt) }
                bind(operationID.uuidString, at: 1, to: receipt)
                bind(expected.id.uuidString, at: 2, to: receipt)
                guard sqlite3_step(receipt) == SQLITE_DONE else { throw databaseError() }
                try beforeCommit()
                return DescriptionRetryReceipt(jobID: expected.id, operationID: operationID)
            }
        }
    }

    func hasDescriptionRetryReceipt(_ receipt: DescriptionRetryReceipt) throws -> Bool {
        try locked {
            let statement = try prepare("SELECT 1 FROM description_retry_receipts WHERE operation_id=? AND job_id=?")
            defer { sqlite3_finalize(statement) }
            bind(receipt.operationID.uuidString, at: 1, to: statement)
            bind(receipt.jobID.uuidString, at: 2, to: statement)
            switch sqlite3_step(statement) {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw databaseError()
            }
        }
    }

    private func readDescriptionJobRevision(id: UUID) throws -> DescriptionJobRevision {
        let statement = try prepare("""
            SELECT j.status, j.attempts, j.updated_at, r.revision
            FROM feature_jobs j JOIN description_job_revisions r ON r.job_id=j.id
            WHERE j.id=? AND j.feature_id=?
            """)
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, at: 1, to: statement)
        bind(CameraFeatureID.visionDescriptions.rawValue, at: 2, to: statement)
        let result = sqlite3_step(statement)
        guard result != SQLITE_DONE else { throw CameraFeatureStoreError.jobNotFound(id) }
        guard result == SQLITE_ROW, let status = CameraFeatureJobStatus(rawValue: text(statement, 0)) else {
            throw databaseError()
        }
        return DescriptionJobRevision(id: id, status: status, attempts: Int(sqlite3_column_int(statement, 1)),
                                      updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                                      revision: text(statement, 3))
    }

    public func jobs(limit: Int = 100, featureID: CameraFeatureID? = nil) throws -> [CameraFeatureJob] {
        try locked {
            let statement = try prepare("""
                SELECT id, feature_id, camera_id, status, attempts, created_at, updated_at,
                       not_before, payload_json, result_json, last_error
                FROM feature_jobs WHERE (? IS NULL OR feature_id=?) ORDER BY created_at DESC, id ASC LIMIT ?
                """)
            defer { sqlite3_finalize(statement) }
            bind(featureID?.rawValue, at: 1, to: statement)
            bind(featureID?.rawValue, at: 2, to: statement)
            sqlite3_bind_int(statement, 3, Int32(max(1, min(1000, limit))))
            var result: [CameraFeatureJob] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { return result }
                guard step == SQLITE_ROW, let row = decodeJob(statement) else { throw databaseError() }
                result.append(row)
            }
        }
    }

    @discardableResult
    func proposeIdentityMatch(
        trackA: UUID,
        trackB: UUID,
        category: String,
        cosineDistance: Double,
        preferences: CameraFeaturePreferences,
        at time: Date = Date()
    ) throws -> CrossCameraIdentityProposal {
        try requireEnabled(.crossCameraIdentity, preferences: preferences)
        guard trackA != trackB, ["person", "vehicle"].contains(category),
              cosineDistance.isFinite, (0...2).contains(cosineDistance) else {
            throw CameraFeatureStoreError.invalidIdentityProposal
        }
        let pair = [trackA.uuidString, trackB.uuidString].sorted()
        return try locked {
            try transaction {
                guard try !hasCannotLink(pair[0], pair[1]) else {
                    throw CameraFeatureStoreError.identityCannotLink
                }
                let insert = try prepare("""
                    INSERT OR IGNORE INTO cross_camera_identity_proposals (
                        id, track_a, track_b, category, cosine_distance, status, created_at
                    ) VALUES (?, ?, ?, ?, ?, 'pending', ?)
                    """)
                defer { sqlite3_finalize(insert) }
                bind(UUID().uuidString, at: 1, to: insert)
                bind(pair[0], at: 2, to: insert)
                bind(pair[1], at: 3, to: insert)
                bind(category, at: 4, to: insert)
                sqlite3_bind_double(insert, 5, cosineDistance)
                sqlite3_bind_double(insert, 6, time.timeIntervalSince1970)
                guard sqlite3_step(insert) == SQLITE_DONE else { throw databaseError() }
                let proposal = try identityProposal(trackA: pair[0], trackB: pair[1])
                if sqlite3_changes(database) == 1 {
                    try recordIdentityAudit(proposal, action: "proposed", identityID: nil, at: time)
                }
                return proposal
            }
        }
    }

    public func identityProposals(
        status: CrossCameraIdentityProposalStatus = .pending,
        limit: Int = 200
    ) throws -> [CrossCameraIdentityProposal] {
        try locked {
            let statement = try prepare("""
                SELECT id, track_a, track_b, category, cosine_distance, status,
                       created_at, reviewed_at, identity_id
                  FROM cross_camera_identity_proposals p
                  LEFT JOIN cross_camera_identity_undos u ON u.proposal_id=p.id
                  WHERE p.status=? AND (p.status!='accepted' OR u.proposal_id IS NULL)
                ORDER BY created_at DESC, id LIMIT ?
                """)
            defer { sqlite3_finalize(statement) }
            bind(status.rawValue, at: 1, to: statement)
            sqlite3_bind_int(statement, 2, Int32(max(1, min(1000, limit))))
            var proposals: [CrossCameraIdentityProposal] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return proposals }
                guard result == SQLITE_ROW, let proposal = decodeIdentityProposal(statement) else {
                    throw databaseError()
                }
                proposals.append(proposal)
            }
        }
    }

    func reviewIdentityProposal(
        id: UUID,
        accept: Bool,
        preferences: CameraFeaturePreferences,
        expectedProposal: CrossCameraIdentityProposal? = nil,
        expectedGraph: [String]? = nil,
        expectedStore: IdentityStoreSnapshot? = nil,
        at time: Date = Date()
    ) throws -> CrossCameraIdentityProposal {
        try requireEnabled(.crossCameraIdentity, preferences: preferences)
        return try locked {
            try transaction {
                let current = try identityProposal(id: id)
                guard current.status == .pending else {
                    throw CameraFeatureStoreError.identityProposalNotPending(id)
                }
                if let expectedProposal, current != expectedProposal {
                    throw CameraFeatureStoreError.identityReviewStale
                }
                if let expectedGraph, try identityReviewGraph() != expectedGraph {
                    throw CameraFeatureStoreError.identityReviewStale
                }
                if let expectedStore, try identityStoreSnapshot() != expectedStore {
                    throw CameraFeatureStoreError.identityReviewStale
                }
                var identityID: UUID?
                if accept {
                    guard try !hasCannotLink(current.trackA.uuidString, current.trackB.uuidString) else {
                        throw CameraFeatureStoreError.identityCannotLink
                    }
                    identityID = try linkIdentity(current, at: time)
                } else {
                    let identityA = try crossCameraIdentityID(for: current.trackA)
                    let identityB = try crossCameraIdentityID(for: current.trackB)
                    guard identityA == nil || identityA != identityB else {
                        throw CameraFeatureStoreError.identityAlreadyLinked
                    }
                    try insertCannotLink(current.trackA, current.trackB, at: time)
                }
                let status: CrossCameraIdentityProposalStatus = accept ? .accepted : .rejected
                let update = try prepare("""
                    UPDATE cross_camera_identity_proposals
                    SET status=?, reviewed_at=?, identity_id=? WHERE id=? AND status='pending'
                    """)
                defer { sqlite3_finalize(update) }
                bind(status.rawValue, at: 1, to: update)
                sqlite3_bind_double(update, 2, time.timeIntervalSince1970)
                bind(identityID?.uuidString, at: 3, to: update)
                bind(id.uuidString, at: 4, to: update)
                guard sqlite3_step(update) == SQLITE_DONE, sqlite3_changes(database) == 1 else {
                    throw CameraFeatureStoreError.identityProposalNotPending(id)
                }
                try recordIdentityAudit(current, action: status.rawValue, identityID: identityID, at: time)
                return try identityProposal(id: id)
            }
        }
    }

    func undoIdentityProposal(
        id: UUID,
        preferences: CameraFeaturePreferences,
        expectedProposal: CrossCameraIdentityProposal? = nil,
        expectedGraph: [String]? = nil,
        expectedStore: IdentityStoreSnapshot? = nil,
        at time: Date = Date()
    ) throws {
        try requireEnabled(.crossCameraIdentity, preferences: preferences)
        try locked {
            try transaction {
                let proposal = try identityProposal(id: id)
                if let expectedProposal, proposal != expectedProposal {
                    throw CameraFeatureStoreError.identityReviewStale
                }
                if let expectedGraph, try identityReviewGraph() != expectedGraph {
                    throw CameraFeatureStoreError.identityReviewStale
                }
                if let expectedStore, try identityStoreSnapshot() != expectedStore {
                    throw CameraFeatureStoreError.identityReviewStale
                }
                guard proposal.status == .accepted else {
                    throw CameraFeatureStoreError.identityProposalNotUndoable(id)
                }
                let exists = try prepare("SELECT 1 FROM cross_camera_identity_undos WHERE proposal_id=?")
                bind(id.uuidString, at: 1, to: exists)
                let alreadyUndone = sqlite3_step(exists) == SQLITE_ROW
                sqlite3_finalize(exists)
                guard !alreadyUndone else {
                    throw CameraFeatureStoreError.identityProposalAlreadyUndone(id)
                }
                let insert = try prepare("INSERT INTO cross_camera_identity_undos(proposal_id, undone_at) VALUES(?, ?)")
                bind(id.uuidString, at: 1, to: insert)
                sqlite3_bind_double(insert, 2, time.timeIntervalSince1970)
                guard sqlite3_step(insert) == SQLITE_DONE else {
                    sqlite3_finalize(insert)
                    throw databaseError()
                }
                sqlite3_finalize(insert)
                try rebuildCrossCameraIdentities(at: time)
                try recordIdentityAudit(proposal, action: "undone", identityID: proposal.identityID, at: time)
            }
        }
    }

    public func crossCameraIdentityID(for trackID: UUID) throws -> UUID? {
        try locked {
            let statement = try prepare("SELECT identity_id FROM cross_camera_identity_links WHERE track_id=?")
            defer { sqlite3_finalize(statement) }
            bind(trackID.uuidString, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return UUID(uuidString: text(statement, 0))
        }
    }

    public func crossCameraIdentityAssignments() throws -> [UUID: UUID] {
        try locked {
            let statement = try prepare("SELECT track_id, identity_id FROM cross_camera_identity_links")
            defer { sqlite3_finalize(statement) }
            var assignments: [UUID: UUID] = [:]
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return assignments }
                guard result == SQLITE_ROW,
                      let trackID = UUID(uuidString: text(statement, 0)),
                      let identityID = UUID(uuidString: text(statement, 1)) else { throw databaseError() }
                assignments[trackID] = identityID
            }
        }
    }

    public func acknowledgeOperationsAlert(
        alertID: UUID,
        preferences: CameraFeaturePreferences,
        at time: Date = Date()
    ) throws {
        _ = try reviewOperationsAlert(alertID: alertID, status: .acknowledged, preferences: preferences, at: time)
    }

    public func unacknowledgeOperationsAlert(
        alertID: UUID,
        preferences: CameraFeaturePreferences
    ) throws {
        _ = try reviewOperationsAlert(alertID: alertID, status: .open, preferences: preferences)
    }

    @discardableResult
    public func reviewOperationsAlert(
        alertID: UUID, priority: OperationsAlertReview.Priority? = nil, status: OperationsAlertReview.Status? = nil,
        note: String? = nil, preferences: CameraFeaturePreferences, at time: Date = Date()
    ) throws -> OperationsAlertReview {
        try requireEnabled(.operationalAlerts, preferences: preferences)
        return try locked {
            _ = try purgeExpired(retentionDays: preferences.retentionDays, now: time)
            return try transaction {
                let current = try operationsAlertReviews().first { $0.alertID == alertID }
                let legacyAcknowledged = try operationsAlertAcknowledgements()[alertID] != nil
                let review = OperationsAlertReview(
                    alertID: alertID, priority: priority ?? current?.priority ?? .normal,
                    status: status ?? current?.status ?? (legacyAcknowledged ? .acknowledged : .open),
                    note: (note ?? current?.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    updatedAt: time
                )
                guard time.timeIntervalSince1970.isFinite, review.note.count <= 2000,
                      review.status != .resolved || !review.note.isEmpty else {
                    throw CameraFeatureStoreError.invalidOperationsAlertReview
                }
                    let reviewCount = try scalarInt("SELECT COUNT(*) FROM operations_alert_reviews")
                    let auditCount = try scalarInt("SELECT COUNT(*) FROM operations_alert_review_audit")
                    guard current != nil || reviewCount < 1000, auditCount < 10_000 else {
                    throw CameraFeatureStoreError.pendingLimitReached(1000)
                }
                let json = String(decoding: try JSONEncoder().encode(review), as: UTF8.self)
                let update = try prepare("""
                    INSERT INTO operations_alert_reviews (alert_id, document_json) VALUES (?, ?)
                    ON CONFLICT(alert_id) DO UPDATE SET document_json=excluded.document_json
                    """)
                defer { sqlite3_finalize(update) }
                bind(alertID.uuidString, at: 1, to: update)
                bind(json, at: 2, to: update)
                guard sqlite3_step(update) == SQLITE_DONE else { throw databaseError() }
                let audit = try prepare("INSERT INTO operations_alert_review_audit (alert_id, document_json) VALUES (?, ?)")
                defer { sqlite3_finalize(audit) }
                bind(alertID.uuidString, at: 1, to: audit)
                bind(json, at: 2, to: audit)
                guard sqlite3_step(audit) == SQLITE_DONE else { throw databaseError() }
                let acknowledgement = try prepare(review.status == .open
                    ? "DELETE FROM operations_alert_acknowledgements WHERE alert_id=?"
                    : "INSERT INTO operations_alert_acknowledgements (alert_id, acknowledged_at) VALUES (?, ?) ON CONFLICT(alert_id) DO UPDATE SET acknowledged_at=excluded.acknowledged_at")
                defer { sqlite3_finalize(acknowledgement) }
                bind(alertID.uuidString, at: 1, to: acknowledgement)
                if review.status != .open { sqlite3_bind_double(acknowledgement, 2, time.timeIntervalSince1970) }
                guard sqlite3_step(acknowledgement) == SQLITE_DONE else { throw databaseError() }
                return review
            }
        }
    }

    public func operationsAlertReviews(alertID: UUID? = nil, audit: Bool = false) throws -> [OperationsAlertReview] {
        try locked {
            let table = audit ? "operations_alert_review_audit" : "operations_alert_reviews"
            let order = audit ? "sequence ASC" : "alert_id ASC"
            let statement = try prepare("SELECT document_json FROM \(table) WHERE (? IS NULL OR alert_id=?) ORDER BY \(order)")
            defer { sqlite3_finalize(statement) }
            bind(alertID?.uuidString, at: 1, to: statement)
            bind(alertID?.uuidString, at: 2, to: statement)
            var reviews: [OperationsAlertReview] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { return reviews }
                guard step == SQLITE_ROW,
                      let review = try? JSONDecoder().decode(OperationsAlertReview.self, from: Data(text(statement, 0).utf8)) else {
                    throw databaseError()
                }
                reviews.append(review)
            }
        }
    }

    public func operationsAlertAcknowledgements() throws -> [UUID: Date] {
        try locked {
            let statement = try prepare("SELECT alert_id, acknowledged_at FROM operations_alert_acknowledgements")
            defer { sqlite3_finalize(statement) }
            var acknowledgements: [UUID: Date] = [:]
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return acknowledgements }
                guard result == SQLITE_ROW, let alertID = UUID(uuidString: text(statement, 0)) else {
                    throw databaseError()
                }
                acknowledgements[alertID] = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            }
        }
    }

    /// Reads both tables in one SQLite statement, without purging or modifying the store.
    /// Legacy acknowledgements without a review are retained, as in purgeExpired.
    public func readAlertState(retentionDays: Int, at time: Date = Date(), includeExpired: Bool = false) throws -> OperationsAlertReadState {
        guard (1...365).contains(retentionDays), time.timeIntervalSince1970.isFinite else {
            throw ConfigurationError.invalid("Invalid alert retention or snapshot time.")
        }
        return try locked {
            let statement = try prepare("""
                SELECT r.alert_id, r.document_json, a.acknowledged_at
                FROM operations_alert_reviews r
                LEFT JOIN operations_alert_acknowledgements a ON a.alert_id = r.alert_id
                UNION ALL
                SELECT a.alert_id, NULL, a.acknowledged_at
                FROM operations_alert_acknowledgements a
                WHERE NOT EXISTS (SELECT 1 FROM operations_alert_reviews r WHERE r.alert_id = a.alert_id)
                """)
            defer { sqlite3_finalize(statement) }
            let cutoff = time.addingTimeInterval(-Double(retentionDays) * 86_400)
            var reviews: [UUID: OperationsAlertReview] = [:]
            var acknowledgements: [UUID: Date] = [:]
            var seen = Set<UUID>()
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE {
                    return OperationsAlertReadState(reviews: reviews, acknowledgements: acknowledgements)
                }
                guard step == SQLITE_ROW, let alertID = UUID(uuidString: text(statement, 0)),
                      seen.insert(alertID).inserted else {
                    throw CameraFeatureStoreError.database("Invalid alert snapshot.")
                }
                if sqlite3_column_type(statement, 1) != SQLITE_NULL {
                    guard let review = try? JSONDecoder().decode(OperationsAlertReview.self, from: Data(text(statement, 1).utf8)),
                          review.alertID == alertID, review.updatedAt.timeIntervalSince1970.isFinite else {
                        throw CameraFeatureStoreError.database("Invalid alert snapshot.")
                    }
                    // purgeExpired removes acknowledgements for expired reviews, but not legacy rows.
                    if !includeExpired && review.updatedAt < cutoff { continue }
                    reviews[alertID] = review
                }
                if sqlite3_column_type(statement, 2) != SQLITE_NULL {
                    guard [SQLITE_INTEGER, SQLITE_FLOAT].contains(sqlite3_column_type(statement, 2)) else {
                        throw CameraFeatureStoreError.database("Invalid alert snapshot.")
                    }
                    let value = sqlite3_column_double(statement, 2)
                    guard value.isFinite else { throw CameraFeatureStoreError.database("Invalid alert snapshot.") }
                    acknowledgements[alertID] = Date(timeIntervalSince1970: value)
                }
            }
        }
    }

    public func clearOperationsAlertAcknowledgements(preferences: CameraFeaturePreferences) throws {
        try requireEnabled(.operationalAlerts, preferences: preferences)
        try locked {
            try transaction {
                try execute("DELETE FROM operations_alert_acknowledgements")
                try execute("DELETE FROM operations_alert_reviews")
                try execute("DELETE FROM operations_alert_review_audit")
            }
        }
    }

    public func hasIdentityDecision(trackA: UUID, trackB: UUID) throws -> Bool {
        let pair = [trackA.uuidString, trackB.uuidString].sorted()
        return try locked {
                        let statement = try prepare("""
                                SELECT 1 FROM cross_camera_identity_proposals p
                                LEFT JOIN cross_camera_identity_undos u ON u.proposal_id=p.id
                                WHERE p.track_a=? AND p.track_b=?
                                    AND (p.status!='accepted' OR u.proposal_id IS NULL)
                                """)
            defer { sqlite3_finalize(statement) }
            bind(pair[0], at: 1, to: statement)
            bind(pair[1], at: 2, to: statement)
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW { return true }
            if result == SQLITE_DONE { return false }
            throw databaseError()
        }
    }

    @discardableResult
    func reconcileIdentityTracks(
        existingTrackIDs: Set<UUID>,
        preferences: CameraFeaturePreferences,
        at time: Date = Date()
    ) throws -> Int {
        try requireEnabled(.crossCameraIdentity, preferences: preferences)
        return try locked {
            try transaction {
                try execute("CREATE TEMP TABLE IF NOT EXISTS current_track_ids (track_id TEXT PRIMARY KEY NOT NULL)")
                try execute("DELETE FROM current_track_ids")
                let insert = try prepare("INSERT INTO current_track_ids(track_id) VALUES(?)")
                for trackID in existingTrackIDs {
                    sqlite3_reset(insert)
                    sqlite3_clear_bindings(insert)
                    bind(trackID.uuidString, at: 1, to: insert)
                    guard sqlite3_step(insert) == SQLITE_DONE else {
                        sqlite3_finalize(insert)
                        throw databaseError()
                    }

                }
                sqlite3_finalize(insert)
                try execute("""
                    DELETE FROM cross_camera_identity_undos
                    WHERE proposal_id IN (
                        SELECT id FROM cross_camera_identity_proposals
                        WHERE track_a NOT IN (SELECT track_id FROM current_track_ids)
                           OR track_b NOT IN (SELECT track_id FROM current_track_ids)
                    )
                    """)
                try execute("""
                    DELETE FROM cross_camera_identity_proposals
                    WHERE track_a NOT IN (SELECT track_id FROM current_track_ids)
                       OR track_b NOT IN (SELECT track_id FROM current_track_ids)
                    """)
                let removedProposals = Int(sqlite3_changes(database))
                try execute("""
                    DELETE FROM cross_camera_identity_cannot_links
                    WHERE track_a NOT IN (SELECT track_id FROM current_track_ids)
                       OR track_b NOT IN (SELECT track_id FROM current_track_ids)
                    """)
                try rebuildCrossCameraIdentities(at: time)
                return removedProposals
            }
        }
    }

    func identityReviewSnapshot() throws -> (proposals: [CrossCameraIdentityProposal], accepted: [CrossCameraIdentityProposal], assignments: [UUID: UUID], graph: [String], graphTrackIDs: Set<UUID>, store: IdentityStoreSnapshot) {
        try locked {
            try transaction {
                (try identityProposals(), try identityProposals(status: .accepted),
                 try crossCameraIdentityAssignments(), try identityReviewGraph(), try identityGraphTrackIDs(),
                 try identityStoreSnapshot())
            }
        }
    }

    // Hash every identity row, including timestamps and audit, without bounded UI queries.
    private func identityStoreSnapshot() throws -> IdentityStoreSnapshot {
        let queries = [
            "SELECT identity_id, category, created_at FROM cross_camera_identities ORDER BY identity_id",
            "SELECT track_id, identity_id, linked_at FROM cross_camera_identity_links ORDER BY track_id",
            "SELECT id, track_a, track_b, category, cosine_distance, status, created_at, reviewed_at, identity_id FROM cross_camera_identity_proposals ORDER BY id",
            "SELECT track_a, track_b, created_at FROM cross_camera_identity_cannot_links ORDER BY track_a, track_b",
            "SELECT proposal_id, undone_at FROM cross_camera_identity_undos ORDER BY proposal_id",
            "SELECT id, proposal_id, action, track_a, track_b, identity_id, occurred_at FROM cross_camera_identity_audit ORDER BY id"
        ]
        return try IdentitySnapshotHasher.snapshot(database: database, queries: queries)
    }

    private func identityGraphTrackIDs() throws -> Set<UUID> {
        let statement = try prepare("SELECT track_a, track_b FROM cross_camera_identity_proposals WHERE status='accepted'")
        defer { sqlite3_finalize(statement) }
        var result = Set<UUID>()
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW, let a = UUID(uuidString: text(statement, 0)),
                  let b = UUID(uuidString: text(statement, 1)) else { throw databaseError() }
            result.insert(a)
            result.insert(b)
        }
    }

    private func identityReviewGraph() throws -> [String] {
        let statement = try prepare("""
            SELECT 'link', track_id, identity_id FROM cross_camera_identity_links
            UNION ALL
            SELECT 'cannot', track_a, track_b FROM cross_camera_identity_cannot_links
            UNION ALL
            SELECT 'accepted', p.id,
                   p.track_a || ':' || p.track_b || ':' || p.category || ':' || COALESCE(u.proposal_id, '')
              FROM cross_camera_identity_proposals p
              LEFT JOIN cross_camera_identity_undos u ON u.proposal_id = p.id
             WHERE p.status = 'accepted'
            ORDER BY 1, 2, 3
            """)
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW else { throw databaseError() }
            result.append("\(text(statement, 0)):\(text(statement, 1)):\(text(statement, 2))")
        }
    }

    public func crossCameraIdentityAudit(limit: Int = 500) throws -> [CrossCameraIdentityAuditEvent] {
        try locked {
            let statement = try prepare("""
                SELECT id, proposal_id, action, track_a, track_b, identity_id, occurred_at
                FROM cross_camera_identity_audit ORDER BY occurred_at DESC, id LIMIT ?
                """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(max(1, min(2000, limit))))
            var events: [CrossCameraIdentityAuditEvent] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return events }
                guard result == SQLITE_ROW,
                      let id = UUID(uuidString: text(statement, 0)),
                      let proposalID = UUID(uuidString: text(statement, 1)),
                      let action = CrossCameraIdentityAuditAction(rawValue: text(statement, 2)),
                      let trackA = UUID(uuidString: text(statement, 3)),
                      let trackB = UUID(uuidString: text(statement, 4)) else { throw databaseError() }
                events.append(CrossCameraIdentityAuditEvent(
                    id: id,
                    proposalID: proposalID,
                    action: action,
                    trackA: trackA,
                    trackB: trackB,
                    identityID: optionalText(statement, 5).flatMap(UUID.init(uuidString:)),
                    occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
                ))
            }
        }
    }

    private func requireEnabled(_ feature: CameraFeatureID, preferences: CameraFeaturePreferences) throws {
        try preferences.validate()
        guard preferences.enabledFeatures.contains(feature) else {
            throw CameraFeatureStoreError.featureDisabled(feature)
        }
    }

    private func hasCannotLink(_ trackA: String, _ trackB: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM cross_camera_identity_cannot_links WHERE track_a=? AND track_b=?")
        defer { sqlite3_finalize(statement) }
        bind(trackA, at: 1, to: statement)
        bind(trackB, at: 2, to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        throw databaseError()
    }

    private func insertCannotLink(_ trackA: UUID, _ trackB: UUID, at time: Date) throws {
        let pair = [trackA.uuidString, trackB.uuidString].sorted()
        let statement = try prepare("INSERT OR IGNORE INTO cross_camera_identity_cannot_links(track_a, track_b, created_at) VALUES(?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        bind(pair[0], at: 1, to: statement)
        bind(pair[1], at: 2, to: statement)
        sqlite3_bind_double(statement, 3, time.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func rebuildCrossCameraIdentities(at time: Date) throws {
        let query = try prepare("""
            SELECT p.id, p.track_a, p.track_b, p.category, u.proposal_id IS NULL
            FROM cross_camera_identity_proposals p
            LEFT JOIN cross_camera_identity_undos u ON u.proposal_id=p.id
            WHERE p.status='accepted'
            """)
        var edges: [(id: UUID, trackA: UUID, trackB: UUID, category: String, active: Bool)] = []
        while true {
            let result = sqlite3_step(query)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW,
                  let id = UUID(uuidString: text(query, 0)),
                  let trackA = UUID(uuidString: text(query, 1)),
                  let trackB = UUID(uuidString: text(query, 2)) else {
                sqlite3_finalize(query)
                throw databaseError()
            }
            edges.append((id, trackA, trackB, text(query, 3), sqlite3_column_int(query, 4) != 0))
        }
        sqlite3_finalize(query)

        let oldLinks = try prepare("SELECT track_id, identity_id FROM cross_camera_identity_links")
        var previousIdentityByTrack: [UUID: UUID] = [:]
        while true {
            let result = sqlite3_step(oldLinks)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW,
                  let trackID = UUID(uuidString: text(oldLinks, 0)),
                  let identityID = UUID(uuidString: text(oldLinks, 1)) else {
                sqlite3_finalize(oldLinks)
                throw databaseError()
            }
            previousIdentityByTrack[trackID] = identityID
        }
        sqlite3_finalize(oldLinks)

        var categoryByTrack: [UUID: String] = [:]
        for edge in edges {
            for trackID in [edge.trackA, edge.trackB] {
                if let category = categoryByTrack[trackID], category != edge.category {
                    throw CameraFeatureStoreError.identityCategoryConflict
                }
                categoryByTrack[trackID] = edge.category
            }
        }
        let tracks = categoryByTrack.keys.sorted { $0.uuidString < $1.uuidString }
        var indexByTrack: [UUID: Int] = [:]
        for (index, trackID) in tracks.enumerated() { indexByTrack[trackID] = index }
        var parents = Array(tracks.indices)

        func root(of index: Int, parents: inout [Int]) -> Int {
            var current = index
            while parents[current] != current { current = parents[current] }
            let result = current
            current = index
            while parents[current] != current {
                let next = parents[current]
                parents[current] = result
                current = next
            }
            return result
        }

        for edge in edges where edge.active {
            guard let indexA = indexByTrack[edge.trackA], let indexB = indexByTrack[edge.trackB] else {
                throw CameraFeatureStoreError.database("Accepted identity edge has a missing track index")
            }
            let rootA = root(of: indexA, parents: &parents)
            let rootB = root(of: indexB, parents: &parents)
            if rootA != rootB { parents[rootB] = rootA }
        }

        var components: [Int: [UUID]] = [:]
        for (index, trackID) in tracks.enumerated() {
            components[root(of: index, parents: &parents), default: []].append(trackID)
        }
        let orderedComponents = components.values.sorted {
            ($0.first?.uuidString ?? "") < ($1.first?.uuidString ?? "")
        }
        try execute("DELETE FROM cross_camera_identity_links")
        try execute("DELETE FROM cross_camera_identities")
        var usedIdentityIDs = Set<UUID>()
        for members in orderedComponents {
            guard let firstTrack = members.first, let category = categoryByTrack[firstTrack] else { continue }
            let previousIDs = Set(members.compactMap { previousIdentityByTrack[$0] })
                .sorted { $0.uuidString < $1.uuidString }
            let identityID = previousIDs.first(where: { !usedIdentityIDs.contains($0) }) ?? UUID()
            usedIdentityIDs.insert(identityID)
            let identity = try prepare("INSERT INTO cross_camera_identities(identity_id, category, created_at) VALUES(?, ?, ?)")
            bind(identityID.uuidString, at: 1, to: identity)
            bind(category, at: 2, to: identity)
            sqlite3_bind_double(identity, 3, time.timeIntervalSince1970)
            guard sqlite3_step(identity) == SQLITE_DONE else {
                sqlite3_finalize(identity)
                throw databaseError()
            }
            sqlite3_finalize(identity)
            for trackID in members {
                let link = try prepare("INSERT INTO cross_camera_identity_links(track_id, identity_id, linked_at) VALUES(?, ?, ?)")
                bind(trackID.uuidString, at: 1, to: link)
                bind(identityID.uuidString, at: 2, to: link)
                sqlite3_bind_double(link, 3, time.timeIntervalSince1970)
                guard sqlite3_step(link) == SQLITE_DONE else {
                    sqlite3_finalize(link)
                    throw databaseError()
                }
                sqlite3_finalize(link)
            }
        }
    }

    private func linkIdentity(_ proposal: CrossCameraIdentityProposal, at time: Date) throws -> UUID {
        var linkedIdentities: [UUID] = []
        for trackID in [proposal.trackA, proposal.trackB] {
            let query = try prepare("SELECT identity_id FROM cross_camera_identity_links WHERE track_id=?")
            bind(trackID.uuidString, at: 1, to: query)
            if sqlite3_step(query) == SQLITE_ROW, let identityID = UUID(uuidString: text(query, 0)) {
                linkedIdentities.append(identityID)
            }
            sqlite3_finalize(query)
        }
        let allTracks = Set([proposal.trackA, proposal.trackB] + (try linkedIdentities.flatMap(linkedTracks(for:))))
        let sortedTracks = allTracks.sorted { $0.uuidString < $1.uuidString }
        for index in sortedTracks.indices {
            for otherIndex in sortedTracks.indices where otherIndex > index {
                guard try !hasCannotLink(sortedTracks[index].uuidString, sortedTracks[otherIndex].uuidString) else {
                    throw CameraFeatureStoreError.identityCannotLink
                }
            }
        }
        let identityID = linkedIdentities.min { $0.uuidString < $1.uuidString } ?? UUID()
        for existingID in Set(linkedIdentities) {
            let existingCategory = try identityCategory(for: existingID)
            guard existingCategory == proposal.category else {
                throw CameraFeatureStoreError.identityCategoryConflict
            }
        }
        let insertIdentity = try prepare("INSERT OR IGNORE INTO cross_camera_identities(identity_id, category, created_at) VALUES(?, ?, ?)")
        bind(identityID.uuidString, at: 1, to: insertIdentity)
        bind(proposal.category, at: 2, to: insertIdentity)
        sqlite3_bind_double(insertIdentity, 3, time.timeIntervalSince1970)
        guard sqlite3_step(insertIdentity) == SQLITE_DONE else {
            sqlite3_finalize(insertIdentity)
            throw databaseError()
        }
        sqlite3_finalize(insertIdentity)
        let category = try prepare("SELECT category FROM cross_camera_identities WHERE identity_id=?")
        bind(identityID.uuidString, at: 1, to: category)
        guard sqlite3_step(category) == SQLITE_ROW, text(category, 0) == proposal.category else {
            sqlite3_finalize(category)
            throw CameraFeatureStoreError.identityCategoryConflict
        }
        sqlite3_finalize(category)
        for existingID in Set(linkedIdentities) where existingID != identityID {
            let merge = try prepare("UPDATE cross_camera_identity_links SET identity_id=? WHERE identity_id=?")
            bind(identityID.uuidString, at: 1, to: merge)
            bind(existingID.uuidString, at: 2, to: merge)
            guard sqlite3_step(merge) == SQLITE_DONE else {
                sqlite3_finalize(merge)
                throw databaseError()
            }
            sqlite3_finalize(merge)
            let remove = try prepare("DELETE FROM cross_camera_identities WHERE identity_id=?")
            bind(existingID.uuidString, at: 1, to: remove)
            guard sqlite3_step(remove) == SQLITE_DONE else {
                sqlite3_finalize(remove)
                throw databaseError()
            }
            sqlite3_finalize(remove)
        }
        for trackID in [proposal.trackA, proposal.trackB] {
            let link = try prepare("""
                INSERT INTO cross_camera_identity_links(track_id, identity_id, linked_at) VALUES(?, ?, ?)
                ON CONFLICT(track_id) DO UPDATE SET identity_id=excluded.identity_id, linked_at=excluded.linked_at
                """)
            bind(trackID.uuidString, at: 1, to: link)
            bind(identityID.uuidString, at: 2, to: link)
            sqlite3_bind_double(link, 3, time.timeIntervalSince1970)
            guard sqlite3_step(link) == SQLITE_DONE else {
                sqlite3_finalize(link)
                throw databaseError()
            }
            sqlite3_finalize(link)
        }
        return identityID
    }

    private func linkedTracks(for identityID: UUID) throws -> [UUID] {
        let statement = try prepare("SELECT track_id FROM cross_camera_identity_links WHERE identity_id=?")
        defer { sqlite3_finalize(statement) }
        bind(identityID.uuidString, at: 1, to: statement)
        var trackIDs: [UUID] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return trackIDs }
            guard result == SQLITE_ROW, let trackID = UUID(uuidString: text(statement, 0)) else {
                throw databaseError()
            }
            trackIDs.append(trackID)
        }
    }

    private func identityCategory(for identityID: UUID) throws -> String? {
        let statement = try prepare("SELECT category FROM cross_camera_identities WHERE identity_id=?")
        defer { sqlite3_finalize(statement) }
        bind(identityID.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, 0)
    }

    private func recordIdentityAudit(
        _ proposal: CrossCameraIdentityProposal,
        action: String,
        identityID: UUID?,
        at time: Date
    ) throws {
        let statement = try prepare("""
            INSERT INTO cross_camera_identity_audit (
                id, proposal_id, action, track_a, track_b, identity_id, occurred_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(statement) }
        bind(UUID().uuidString, at: 1, to: statement)
        bind(proposal.id.uuidString, at: 2, to: statement)
        bind(action, at: 3, to: statement)
        bind(proposal.trackA.uuidString, at: 4, to: statement)
        bind(proposal.trackB.uuidString, at: 5, to: statement)
        bind(identityID?.uuidString, at: 6, to: statement)
        sqlite3_bind_double(statement, 7, time.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func identityProposal(trackA: String, trackB: String) throws -> CrossCameraIdentityProposal {
        let statement = try prepare("""
            SELECT id, track_a, track_b, category, cosine_distance, status,
                   created_at, reviewed_at, identity_id
            FROM cross_camera_identity_proposals WHERE track_a=? AND track_b=?
            """)
        defer { sqlite3_finalize(statement) }
        bind(trackA, at: 1, to: statement)
        bind(trackB, at: 2, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW, let proposal = decodeIdentityProposal(statement) else {
            throw databaseError()
        }
        return proposal
    }

    private func identityProposal(id: UUID) throws -> CrossCameraIdentityProposal {
        let statement = try prepare("""
            SELECT id, track_a, track_b, category, cosine_distance, status,
                   created_at, reviewed_at, identity_id
            FROM cross_camera_identity_proposals WHERE id=?
            """)
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW, let proposal = decodeIdentityProposal(statement) else {
            throw CameraFeatureStoreError.identityProposalNotFound(id)
        }
        return proposal
    }

    private func decodeIdentityProposal(_ statement: OpaquePointer) -> CrossCameraIdentityProposal? {
        guard let id = UUID(uuidString: text(statement, 0)),
              let trackA = UUID(uuidString: text(statement, 1)),
              let trackB = UUID(uuidString: text(statement, 2)),
              let status = CrossCameraIdentityProposalStatus(rawValue: text(statement, 5)) else { return nil }
        return CrossCameraIdentityProposal(
            id: id,
            trackA: trackA,
            trackB: trackB,
            category: text(statement, 3),
            cosineDistance: sqlite3_column_double(statement, 4),
            status: status,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            reviewedAt: sqlite3_column_type(statement, 7) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
            identityID: optionalText(statement, 8).flatMap(UUID.init(uuidString:))
        )
    }

    @discardableResult
    public func purgeExpired(retentionDays: Int, now: Date = Date()) throws -> Int {
        guard (1...365).contains(retentionDays) else {
            throw ConfigurationError.invalid("Feature retention must be between 1 and 365 days.")
        }
        return try locked {
            try transaction {
                let cutoff = now.addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60).timeIntervalSince1970
                let statement = try prepare("DELETE FROM feature_jobs WHERE created_at < ? AND status IN ('completed','failed')")
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_double(statement, 1, cutoff)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
                let removedJobs = Int(sqlite3_changes(database))
                for sql in [
                    "DELETE FROM operator_action_audit WHERE proposal_id IN (SELECT id FROM operator_action_proposals WHERE created_at < ?)",
                    "DELETE FROM operator_action_proposals WHERE created_at < ?"
                ] {
                    let cleanup = try prepare(sql)
                    defer { sqlite3_finalize(cleanup) }
                    sqlite3_bind_double(cleanup, 1, cutoff)
                    guard sqlite3_step(cleanup) == SQLITE_DONE else { throw databaseError() }
                }
                let referenceCutoff = Date(timeIntervalSince1970: cutoff).timeIntervalSinceReferenceDate
                for sql in [
                    "DELETE FROM operations_alert_acknowledgements WHERE alert_id IN (SELECT alert_id FROM operations_alert_reviews WHERE json_extract(document_json, '$.updatedAt') < ?)",
                    "DELETE FROM operations_alert_reviews WHERE json_extract(document_json, '$.updatedAt') < ?",
                    "DELETE FROM operations_alert_review_audit WHERE json_extract(document_json, '$.updatedAt') < ?"
                ] {
                    let cleanup = try prepare(sql)
                    defer { sqlite3_finalize(cleanup) }
                    sqlite3_bind_double(cleanup, 1, referenceCutoff)
                    guard sqlite3_step(cleanup) == SQLITE_DONE else { throw databaseError() }
                }
                return removedJobs
            }
        }
    }

    private func updateRunningJob(
        jobID: UUID,
        bindValues: (OpaquePointer) -> Void,
        sql: () -> String
    ) throws {
        try locked {
            try transaction {
                let statement = try prepare(sql())
                defer { sqlite3_finalize(statement) }
                bindValues(statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
                guard sqlite3_changes(database) == 1 else {
                    throw CameraFeatureStoreError.jobNotRunning(jobID)
                }
            }
        }
    }

    private func job(id: UUID) throws -> CameraFeatureJob {
        let statement = try prepare("""
            SELECT id, feature_id, camera_id, status, attempts, created_at, updated_at,
                   not_before, payload_json, result_json, last_error
            FROM feature_jobs WHERE id=?
            """)
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW, let result = decodeJob(statement) else {
            throw CameraFeatureStoreError.jobNotFound(id)
        }
        return result
    }

    private func decodeJob(_ statement: OpaquePointer) -> CameraFeatureJob? {
        guard let id = UUID(uuidString: text(statement, 0)),
              let featureID = CameraFeatureID(rawValue: text(statement, 1)),
              let status = CameraFeatureJobStatus(rawValue: text(statement, 3)) else { return nil }
        let cameraIDText = optionalText(statement, 2)
        let cameraID = cameraIDText.flatMap(UUID.init(uuidString:))
        return CameraFeatureJob(
            id: id,
            featureID: featureID,
            cameraID: cameraID,
            status: status,
            attempts: Int(sqlite3_column_int(statement, 4)),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            notBefore: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
            payloadJSON: optionalText(statement, 8),
            resultJSON: optionalText(statement, 9),
            lastError: optionalText(statement, 10)
        )
    }

    private static func validateJSON(_ value: String?) throws {
        guard let value else { return }
        let data = Data(value.utf8)
        guard data.count <= maximumPayloadBytes,
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
            throw CameraFeatureStoreError.invalidPayload
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw CameraFeatureStoreError.database(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw databaseError() }
        return statement
    }

    private func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return text(statement, column)
    }

    private func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try operation()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func locked<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private func databaseError() -> CameraFeatureStoreError {
        CameraFeatureStoreError.database(String(cString: sqlite3_errmsg(database)))
    }
}