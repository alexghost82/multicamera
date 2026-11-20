import XCTest
import SQLite3
@testable import CameraCore

final class CameraFeatureStoreTests: XCTestCase {
    func testVersionSixJobsGainRevisionsAndRetryReceipts() throws {
        let fixture = try IsolatedStoreTestDirectory()
        defer { try? fixture.remove() }
        let directory = fixture.url
        let url = directory.appendingPathComponent("features.sqlite3")
        let jobID = UUID()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let database = try XCTUnwrap(db)
        let sql = """
            CREATE TABLE feature_jobs (
                id TEXT PRIMARY KEY NOT NULL, feature_id TEXT NOT NULL, camera_id TEXT,
                status TEXT NOT NULL, attempts INTEGER NOT NULL, created_at REAL NOT NULL,
                updated_at REAL NOT NULL, not_before REAL NOT NULL, payload_json TEXT,
                result_json TEXT, last_error TEXT
            );
            INSERT INTO feature_jobs VALUES
                ('\(jobID.uuidString)', 'visionDescriptions', NULL, 'failed', 1, 1, 1, 1, NULL, NULL, 'fixture');
            PRAGMA user_version=6;
            """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(database), SQLITE_OK)
        let store = try CameraFeatureStore(url: url)
        let revision = try store.descriptionJobRevision(id: jobID)
        XCTAssertEqual(revision.status, .failed)
        let receipt = try store.retryDescriptionJob(expected: revision,
            preferences: CameraFeaturePreferences(enabledFeatures: [.visionDescriptions]),
            operationID: UUID(), beforeCommit: {})
        let reopened = try CameraFeatureStore(url: url)
        XCTAssertTrue(try reopened.hasDescriptionRetryReceipt(receipt))
        let updated = try reopened.descriptionJobRevision(id: jobID)
        XCTAssertEqual(updated.status, .queued)
        XCTAssertNotEqual(updated.revision, revision.revision)
    }

    func testVersionFiveMigrationPreservesJobsActionsAndLegacyAcknowledgements() throws {
        let fixture = try IsolatedStoreTestDirectory()
        defer { try? fixture.remove() }
        let directory = fixture.url
        let url = directory.appendingPathComponent("features.sqlite3")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let alertID = UUID()
        let trackID = UUID()
        let preferences = CameraFeaturePreferences(enabledFeatures: [.operationalAlerts, .operatorActions, .visionDescriptions])
        let ids = try { () throws -> (UUID, UUID) in
            let store = try CameraFeatureStore(url: url)
            let job = try store.enqueue(featureID: .visionDescriptions, preferences: preferences, at: now)
            let action = try store.proposeDescriptionAction(trackIDs: [trackID], allowedTrackIDs: [trackID], preferences: preferences, at: now)
            try store.acknowledgeOperationsAlert(alertID: alertID, preferences: preferences, at: now)
            return (job.id, action.id)
        }()
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "DROP TABLE operations_alert_reviews; DROP TABLE operations_alert_review_audit; PRAGMA user_version=5;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        let migrated = try CameraFeatureStore(url: url)
        XCTAssertEqual(try migrated.jobs().first?.id, ids.0)
        XCTAssertEqual(try migrated.operatorActions().first?.id, ids.1)
        XCTAssertEqual(try migrated.operationsAlertAcknowledgements()[alertID], now)
        XCTAssertTrue(try migrated.operationsAlertReviews().isEmpty)
        let review = try migrated.reviewOperationsAlert(alertID: alertID, priority: .critical, preferences: preferences, at: now.addingTimeInterval(1))
        XCTAssertEqual(review.status, .acknowledged)
        XCTAssertEqual(review.priority, .critical)
    }

    func testExpiredAlertReviewAndAuditFollowFeatureRetention() throws {
        let (store, directory, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let alertID = UUID()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let preferences = CameraFeaturePreferences(enabledFeatures: [.operationalAlerts], retentionDays: 1)
        _ = try store.reviewOperationsAlert(alertID: alertID, status: .resolved, note: "Checked", preferences: preferences, at: now)
        XCTAssertNotNil(try store.operationsAlertAcknowledgements()[alertID])
        _ = try store.purgeExpired(retentionDays: 1, now: now.addingTimeInterval(2 * 86_400))
        XCTAssertTrue(try store.operationsAlertReviews().isEmpty)
        XCTAssertTrue(try store.operationsAlertReviews(alertID: alertID, audit: true).isEmpty)
        XCTAssertNil(try store.operationsAlertAcknowledgements()[alertID])
    }

    func testAlertTriagePersistsAndSynchronizesAcknowledgementsWithAudit() throws {
        let (store, directory, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let alertID = UUID()
        let preferences = CameraFeaturePreferences(enabledFeatures: [.operationalAlerts])
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let critical = try store.reviewOperationsAlert(alertID: alertID, priority: .critical, preferences: preferences, at: now)
        XCTAssertEqual(critical.status, .open)
        XCTAssertNil(try store.operationsAlertAcknowledgements()[alertID])
        try store.acknowledgeOperationsAlert(alertID: alertID, preferences: preferences, at: now.addingTimeInterval(1))
        let resolved = try store.reviewOperationsAlert(
            alertID: alertID, status: .resolved, note: "Checked local evidence", preferences: preferences, at: now.addingTimeInterval(2)
        )
        XCTAssertEqual(resolved.priority, .critical)
        let reopened = try CameraFeatureStore(url: url)
        XCTAssertEqual(try reopened.operationsAlertReviews(alertID: alertID), [resolved])
        XCTAssertEqual(try reopened.operationsAlertReviews(alertID: alertID, audit: true).map(\.status), [.open, .acknowledged, .resolved])
        try reopened.unacknowledgeOperationsAlert(alertID: alertID, preferences: preferences)
        XCTAssertNil(try reopened.operationsAlertAcknowledgements()[alertID])
        XCTAssertEqual(try reopened.operationsAlertReviews(alertID: alertID).first?.status, .open)
    }

    func testAlertResolutionRequiresOptInAndBoundedNonemptyNote() throws {
        let (store, directory, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let alertID = UUID()
        let preferences = CameraFeaturePreferences(enabledFeatures: [.operationalAlerts])
        XCTAssertThrowsError(try store.reviewOperationsAlert(alertID: alertID, priority: .critical, preferences: CameraFeaturePreferences()))
        XCTAssertThrowsError(try store.reviewOperationsAlert(alertID: alertID, status: .resolved, note: " ", preferences: preferences))
        XCTAssertThrowsError(try store.reviewOperationsAlert(alertID: alertID, note: String(repeating: "a", count: 2001), preferences: preferences))
        XCTAssertTrue(try store.operationsAlertReviews().isEmpty)
        XCTAssertTrue(try store.operationsAlertReviews(alertID: alertID, audit: true).isEmpty)
        XCTAssertTrue(try store.operationsAlertAcknowledgements().isEmpty)
    }

    func testExpiredOperatorActionCannotExecuteAndItsAuditIsPurged() throws {
        let (store, directory, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let preferences = CameraFeaturePreferences(enabledFeatures: [.operatorActions, .visionDescriptions], retentionDays: 1)
        let trackID = UUID()
        let proposal = try store.proposeDescriptionAction(
            trackIDs: [trackID], allowedTrackIDs: [trackID], preferences: preferences, at: start
        )
        XCTAssertThrowsError(try store.reviewOperatorAction(
            id: proposal.id, accept: true, existingTrackIDs: [trackID], preferences: preferences,
            at: start.addingTimeInterval(2 * 86_400)
        ))
        XCTAssertTrue(try store.jobs().isEmpty)
        _ = try store.purgeExpired(retentionDays: 1, now: start.addingTimeInterval(2 * 86_400))
        XCTAssertTrue(try store.operatorActions().isEmpty)
        XCTAssertTrue(try store.operatorActionAudit(id: proposal.id).isEmpty)
    }

    func testConfirmedActionReusesExistingDescriptionJobEvenWhenQueueIsFull() throws {
        let (store, directory, _) = try makeStore(pendingLimit: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = CameraFeaturePreferences(enabledFeatures: [.operatorActions, .visionDescriptions])
        let trackID = UUID()
        let payload = String(decoding: try JSONEncoder().encode(["trackID": trackID.uuidString]), as: UTF8.self)
        let job = try store.enqueue(featureID: .visionDescriptions, payloadJSON: payload, preferences: preferences)
        let proposal = try store.proposeDescriptionAction(trackIDs: [trackID], allowedTrackIDs: [trackID], preferences: preferences)
        let accepted = try store.reviewOperatorAction(
            id: proposal.id, accept: true, existingTrackIDs: [trackID], preferences: preferences
        )
        XCTAssertEqual(accepted.jobIDs, [job.id])
        XCTAssertEqual(try store.jobs().count, 1)
    }

    func testDescriptionActionRequiresConfirmationAndIsAuditedAtomically() throws {
        let (store, directory, databaseURL) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = CameraFeaturePreferences(enabledFeatures: [.operatorActions, .visionDescriptions])
        let tracks: Set<UUID> = [UUID(), UUID()]
        let proposal = try store.proposeDescriptionAction(
            trackIDs: Array(tracks), allowedTrackIDs: tracks, preferences: preferences
        )
        XCTAssertTrue(try store.jobs().isEmpty)
        XCTAssertEqual(try store.operatorActionAudit(id: proposal.id).map(\.status), [.pending])
        let accepted = try store.reviewOperatorAction(
            id: proposal.id, accept: true, existingTrackIDs: tracks, preferences: preferences
        )
        XCTAssertEqual(accepted.status, .applied)
        XCTAssertEqual(accepted.jobIDs.count, 2)
        XCTAssertEqual(Set(try store.jobs().map(\.id)), Set(accepted.jobIDs))
        XCTAssertThrowsError(try store.reviewOperatorAction(
            id: proposal.id, accept: true, existingTrackIDs: tracks, preferences: preferences
        ))
        let reopened = try CameraFeatureStore(url: databaseURL)
        XCTAssertEqual(try reopened.operatorActions().first, accepted)
        XCTAssertEqual(try reopened.operatorActionAudit(id: proposal.id).map(\.status), [.pending, .applied])
    }

    func testDescriptionActionRejectsUnsupportedTracksDisabledFeatureAndFullQueue() throws {
        let (store, directory, _) = try makeStore(pendingLimit: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = CameraFeaturePreferences(enabledFeatures: [.operatorActions, .visionDescriptions])
        let track = UUID()
        XCTAssertThrowsError(try store.proposeDescriptionAction(trackIDs: [track], allowedTrackIDs: [], preferences: preferences))
        XCTAssertThrowsError(try store.proposeDescriptionAction(trackIDs: [track, track], allowedTrackIDs: [track], preferences: preferences))
        XCTAssertThrowsError(try store.proposeDescriptionAction(trackIDs: [track], allowedTrackIDs: [track], preferences: CameraFeaturePreferences()))
        let action = try store.proposeDescriptionAction(trackIDs: [track], allowedTrackIDs: [track], preferences: preferences)
        XCTAssertThrowsError(try store.reviewOperatorAction(id: action.id, accept: true, existingTrackIDs: [], preferences: preferences))
        XCTAssertThrowsError(try store.reviewOperatorAction(
            id: action.id, accept: true, existingTrackIDs: [track],
            preferences: CameraFeaturePreferences(enabledFeatures: [.operatorActions])
        ))
        _ = try store.enqueue(featureID: .visionDescriptions, preferences: preferences)
        XCTAssertThrowsError(try store.reviewOperatorAction(id: action.id, accept: true, existingTrackIDs: [track], preferences: preferences))
        XCTAssertEqual(try store.operatorActions().first?.status, .pending)
        XCTAssertEqual(try store.operatorActionAudit(id: action.id).count, 1)
        let rejected = try store.reviewOperatorAction(id: action.id, accept: false, existingTrackIDs: [], preferences: preferences)
        XCTAssertEqual(rejected.status, .rejected)
        XCTAssertEqual(try store.jobs().count, 1)
    }

    func testManualRetryRequiresFailedOptedInJobAndPreservesAttemptCount() throws {
        let (store, directory, databaseURL) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = CameraFeaturePreferences(enabledFeatures: [.visionDescriptions, .knowledgeSearch])
        let job = try store.enqueue(featureID: .visionDescriptions, preferences: preferences)
        _ = try store.enqueue(featureID: .knowledgeSearch, preferences: preferences)
        XCTAssertThrowsError(try store.retryFailedJob(id: job.id, preferences: preferences))
        _ = try store.claimNext(featureID: .visionDescriptions)
        try store.fail(jobID: job.id, message: "Local model missing")
        XCTAssertThrowsError(try store.retryFailedJob(id: job.id, preferences: CameraFeaturePreferences()))
        try store.retryFailedJob(id: job.id, preferences: preferences)
        XCTAssertThrowsError(try store.retryFailedJob(id: job.id, preferences: preferences))
        let reopened = try CameraFeatureStore(url: databaseURL)
        let retried = try XCTUnwrap(reopened.jobs(featureID: .visionDescriptions).first)
        XCTAssertEqual(retried.id, job.id)
        XCTAssertEqual(retried.attempts, 1)
        XCTAssertEqual(retried.status, .queued)
        XCTAssertEqual(retried.lastError, "Local model missing")
        let claimed = try XCTUnwrap(reopened.claimNext(featureID: .visionDescriptions))
        XCTAssertEqual(claimed.attempts, 2)
        try reopened.complete(jobID: claimed.id)
        XCTAssertThrowsError(try reopened.retryFailedJob(id: job.id, preferences: preferences))
    }

    func testManualRetryCannotBypassPendingLimit() throws {
        let (store, directory, _) = try makeStore(pendingLimit: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = CameraFeaturePreferences(enabledFeatures: [.visionDescriptions])
        let failed = try store.enqueue(featureID: .visionDescriptions, preferences: preferences)
        _ = try store.claimNext()
        try store.fail(jobID: failed.id, message: "Fixture failure")
        _ = try store.enqueue(featureID: .visionDescriptions, preferences: preferences)
        XCTAssertThrowsError(try store.retryFailedJob(id: failed.id, preferences: preferences))
        XCTAssertEqual(try store.jobs().first(where: { $0.id == failed.id })?.status, .failed)
    }

    func testDescriptionRetryRejectsStaleRevisionAndCommitsReceiptAtomically() throws {
        let (store, directory, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = CameraFeaturePreferences(enabledFeatures: [.visionDescriptions])
        let job = try store.enqueue(featureID: .visionDescriptions, preferences: preferences)
        _ = try store.claimNext(featureID: .visionDescriptions)
        try store.fail(jobID: job.id, message: "Synthetic failure")
        let reviewed = try store.descriptionJobRevision(id: job.id)
        let other = try CameraFeatureStore(url: url)
        try other.retryFailedJob(id: job.id, preferences: preferences)
        _ = try other.claimNext(featureID: .visionDescriptions)
        try other.fail(jobID: job.id, message: "Another failure")
        let operation = UUID()
        XCTAssertThrowsError(try store.retryDescriptionJob(
            expected: reviewed, preferences: preferences, operationID: operation, beforeCommit: {}
        ))
        XCTAssertFalse(try store.hasDescriptionRetryReceipt(.init(jobID: job.id, operationID: operation)))
        let current = try store.descriptionJobRevision(id: job.id)
        var calls = 0
        XCTAssertThrowsError(try store.retryDescriptionJob(
            expected: current, preferences: preferences, operationID: operation, beforeCommit: {
                calls += 1
                if calls == 2 { throw CancellationError() }
            }
        ))
        XCTAssertEqual(try store.descriptionJobRevision(id: job.id), current)
        XCTAssertFalse(try other.hasDescriptionRetryReceipt(.init(jobID: job.id, operationID: operation)))
        let receipt = try store.retryDescriptionJob(
            expected: current, preferences: preferences, operationID: operation, beforeCommit: {}
        )
        let reopened = try CameraFeatureStore(url: url)
        XCTAssertTrue(try reopened.hasDescriptionRetryReceipt(receipt))
        XCTAssertEqual(try reopened.jobs(featureID: .visionDescriptions).first?.status, .queued)
    }

    func testJobsRequireFeatureOptInAndRespectPendingLimit() throws {
        let (store, directory, databaseURL) = try makeStore(pendingLimit: 1)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try store.enqueue(
            featureID: .scheduledMissions,
            preferences: CameraFeaturePreferences()
        )) { error in
            guard case CameraFeatureStoreError.featureDisabled(.scheduledMissions) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let preferences = CameraFeaturePreferences(enabledFeatures: [.scheduledMissions])
        let job = try store.enqueue(featureID: .scheduledMissions, preferences: preferences)
        XCTAssertEqual(job.status, .queued)
        XCTAssertThrowsError(try store.enqueue(featureID: .scheduledMissions, preferences: preferences))

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: databaseURL.deletingLastPathComponent().path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testJobCanBeClaimedRetriedAndCompleted() throws {
        let (store, directory, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let preferences = CameraFeaturePreferences(enabledFeatures: [.crossCameraIdentity])
        let job = try store.enqueue(
            featureID: .crossCameraIdentity,
            payloadJSON: #"{"track":"track-1"}"#,
            preferences: preferences,
            at: start
        )

        let firstClaim = try XCTUnwrap(store.claimNext(at: start))
        XCTAssertEqual(firstClaim.id, job.id)
        XCTAssertEqual(firstClaim.status, .running)
        XCTAssertEqual(firstClaim.attempts, 1)

        let retryAt = start.addingTimeInterval(30)
        XCTAssertEqual(try store.fail(jobID: job.id, message: "temporary", retryAt: retryAt, at: start), .queued)
        XCTAssertNil(try store.claimNext(at: retryAt.addingTimeInterval(-1)))

        let secondClaim = try XCTUnwrap(store.claimNext(at: retryAt))
        XCTAssertEqual(secondClaim.attempts, 2)
        try store.complete(jobID: job.id, resultJSON: #"{"ok":true}"#, at: retryAt)

        let completed = try XCTUnwrap(store.jobs().first)
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.attempts, 2)
        XCTAssertEqual(completed.resultJSON, #"{"ok":true}"#)
        XCTAssertNil(completed.lastError)
    }

    func testInvalidPayloadIsRejected() throws {
        let (store, directory, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = CameraFeaturePreferences(enabledFeatures: [.knowledgeSearch])

        XCTAssertThrowsError(try store.enqueue(
            featureID: .knowledgeSearch,
            payloadJSON: "not-json",
            preferences: preferences
        ))
    }

    func testQueuedJobPersistsAfterStoreReopen() throws {
        let (initialStore, directory, databaseURL) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = CameraFeaturePreferences(enabledFeatures: [.historyResearch])
        let jobID = try initialStore.enqueue(
            featureID: .historyResearch,
            payloadJSON: #"{"query":"recent tracks"}"#,
            preferences: preferences
        ).id

        let reopenedStore = try CameraFeatureStore(url: databaseURL)
        let persisted = try XCTUnwrap(reopenedStore.jobs().first)

        XCTAssertEqual(persisted.id, jobID)
        XCTAssertEqual(persisted.featureID, .historyResearch)
        XCTAssertEqual(persisted.status, .queued)
        XCTAssertEqual(persisted.payloadJSON, #"{"query":"recent tracks"}"#)
    }

    func testExpiredTerminalJobsArePurged() throws {
        let (store, directory, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let preferences = CameraFeaturePreferences(enabledFeatures: [.knowledgeSearch])
        let job = try store.enqueue(featureID: .knowledgeSearch, preferences: preferences, at: createdAt)
        _ = try store.claimNext(at: createdAt)
        try store.complete(jobID: job.id, at: createdAt)

        XCTAssertEqual(try store.purgeExpired(retentionDays: 1, now: createdAt.addingTimeInterval(2 * 86_400)), 1)
        XCTAssertTrue(try store.jobs().isEmpty)
    }

    func testClaimCanBeScopedToFeature() throws {
        let (store, directory, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let preferences = CameraFeaturePreferences(enabledFeatures: [.visionDescriptions, .knowledgeSearch])
        let researchJob = try store.enqueue(featureID: .knowledgeSearch, preferences: preferences, at: now)
        let descriptionJob = try store.enqueue(featureID: .visionDescriptions, preferences: preferences, at: now)

        let claimed = try XCTUnwrap(store.claimNext(featureID: .visionDescriptions, at: now))

        XCTAssertEqual(claimed.id, descriptionJob.id)
        XCTAssertEqual(try XCTUnwrap(store.jobs().first(where: { $0.id == researchJob.id })).status, .queued)
    }

    func testBatchClaimIsBoundedAndFeatureScoped() throws {
        let (store, directory, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let preferences = CameraFeaturePreferences(enabledFeatures: [.visionDescriptions, .knowledgeSearch])
        for _ in 0..<5 {
            _ = try store.enqueue(featureID: .visionDescriptions, preferences: preferences, at: now)
        }
        let researchJob = try store.enqueue(featureID: .knowledgeSearch, preferences: preferences, at: now)

        let claimed = try store.claimNextBatch(featureID: .visionDescriptions, limit: 10, at: now)
        let jobs = try store.jobs()
        let descriptionStatuses = jobs.filter { $0.featureID == .visionDescriptions }.map(\.status)

        XCTAssertEqual(claimed.count, 4)
        XCTAssertTrue(claimed.allSatisfy { $0.status == .running && $0.attempts == 1 })
        XCTAssertEqual(descriptionStatuses.filter { $0 == .running }.count, 4)
        XCTAssertEqual(descriptionStatuses.filter { $0 == .queued }.count, 1)
        XCTAssertEqual(try XCTUnwrap(jobs.first(where: { $0.id == researchJob.id })).status, .queued)
    }

    func testInterruptedJobsAreRequeuedOrFailedAtAttemptLimit() throws {
        let (store, directory, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let preferences = CameraFeaturePreferences(enabledFeatures: [.visionDescriptions])
        let retryJob = try store.enqueue(featureID: .visionDescriptions, preferences: preferences, at: start)
        let failedJob = try store.enqueue(featureID: .visionDescriptions, preferences: preferences, at: start)
        _ = try store.claimNext(featureID: .visionDescriptions, at: start)
        _ = try store.claimNext(featureID: .visionDescriptions, at: start)
        try store.fail(jobID: failedJob.id, message: "retry", retryAt: start, maximumAttempts: 2, at: start)
        _ = try store.claimNext(featureID: .visionDescriptions, at: start)

        XCTAssertEqual(try store.recoverInterruptedJobs(
            featureID: .visionDescriptions,
            staleBefore: start.addingTimeInterval(1),
            maximumAttempts: 2,
            at: start.addingTimeInterval(2)
        ), 2)
        XCTAssertEqual(try XCTUnwrap(store.jobs().first(where: { $0.id == retryJob.id })).status, .queued)
        XCTAssertEqual(try XCTUnwrap(store.jobs().first(where: { $0.id == failedJob.id })).status, .failed)
    }

    func testAlertAcknowledgementIsOptInAndPersistsAcrossReopen() throws {
        let (store, directory, databaseURL) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let alertID = UUID()
        let acknowledgedAt = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertThrowsError(try store.acknowledgeOperationsAlert(
            alertID: alertID,
            preferences: CameraFeaturePreferences(),
            at: acknowledgedAt
        ))

        let preferences = CameraFeaturePreferences(enabledFeatures: [.operationalAlerts])
        try store.acknowledgeOperationsAlert(alertID: alertID, preferences: preferences, at: acknowledgedAt)
        let reopenedStore = try CameraFeatureStore(url: databaseURL)
        XCTAssertEqual(try reopenedStore.operationsAlertAcknowledgements()[alertID], acknowledgedAt)
        try reopenedStore.unacknowledgeOperationsAlert(alertID: alertID, preferences: preferences)
        XCTAssertNil(try reopenedStore.operationsAlertAcknowledgements()[alertID])
    }

    private func makeStore(pendingLimit: Int = 10) throws -> (CameraFeatureStore, URL, URL) {
        let fixture = try IsolatedStoreTestDirectory()
        let directory = fixture.url
        let databaseURL = directory.appendingPathComponent("store", isDirectory: true)
            .appendingPathComponent("feature-jobs.sqlite3")
        do {
            return (try CameraFeatureStore(url: databaseURL, pendingLimit: pendingLimit), directory, databaseURL)
        } catch {
            try? fixture.remove()
            throw error
        }
    }
}