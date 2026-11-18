import Foundation
import Darwin
import SQLite3
import XCTest
@testable import CameraCore

final class CrossCameraIdentityReviewServiceTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let tracking: LocalTrackingStore
        let features: CameraFeatureStore
        let service: CrossCameraIdentityReviewService
        let preferences = CameraFeaturePreferences(enabledFeatures: [.crossCameraIdentity])

        init() throws {
            root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".identity-review-test-\(UUID().uuidString)")
            tracking = try LocalTrackingStore(url: root.appendingPathComponent("tracks.sqlite"))
            features = try CameraFeatureStore(url: root.appendingPathComponent("features.sqlite"))
            service = CrossCameraIdentityReviewService(tracking: tracking, features: features)
        }

        func track() throws -> TrackedObjectRecord {
            let id = UUID()
            let object = DetectedObject(id: 0, label: "person", confidence: 0.9,
                box: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), trackID: id)
            _ = try tracking.record(object, cameraID: UUID(), cameraName: "Synthetic")
            return try XCTUnwrap(tracking.track(trackID: id))
        }

        func propose(_ a: TrackedObjectRecord, _ b: TrackedObjectRecord) throws -> CrossCameraIdentityProposal {
            try service.propose(candidate: ReIDValidationCandidate(trackA: a, trackB: b, distance: 0.1),
                                preferences: preferences)
        }

        func prepare(_ proposal: CrossCameraIdentityProposal, _ records: [TrackedObjectRecord],
                     _ snapshot: CrossCameraIdentityReviewSnapshot, accept: Bool) throws -> CrossCameraIdentityPreparedReview {
            try service.prepareReview(proposal: proposal, records: records, snapshot: snapshot,
                                      accept: accept, preferences: preferences)
        }
    }

    func testDeletedTrackCannotBeReviewedOrProposed() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let a = try f.track(), b = try f.track()
        let proposal = try f.propose(a, b)
        let snapshot = try f.service.snapshot()
        let accept = try f.prepare(proposal, [a, b], snapshot, accept: true)
        let reject = try f.prepare(proposal, [a, b], snapshot, accept: false)
        try f.tracking.delete(trackID: a.trackID)
        for prepared in [accept, reject] {
            XCTAssertThrowsError(try f.service.review(prepared, preferences: f.preferences))
        }
        XCTAssertThrowsError(try f.propose(a, b))
        XCTAssertNil(try f.features.crossCameraIdentityID(for: b.trackID))
        XCTAssertEqual(try f.features.identityProposals().map(\.id), [proposal.id])
        XCTAssertEqual(try f.features.crossCameraIdentityAudit().map(\.action), [.proposed])
    }

    func testChangedEvidenceRequiresRefreshAndReconcileRemovesDeletedProposal() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let a = try f.track(), b = try f.track()
        let proposal = try f.propose(a, b)
        let snapshot = try f.service.snapshot()
        let prepared = try f.prepare(proposal, [a, b], snapshot, accept: true)
        let object = DetectedObject(id: 0, label: "person", confidence: 0.9,
            box: a.box, trackID: a.trackID)
        _ = try f.tracking.record(object, cameraID: a.cameraID, cameraName: a.cameraName)
        XCTAssertThrowsError(try f.service.review(prepared, preferences: f.preferences))
        let updated = try XCTUnwrap(f.tracking.track(trackID: a.trackID))
        let refreshed = try f.prepare(proposal, [updated, b], try f.service.snapshot(), accept: true)
        _ = try f.service.review(refreshed, preferences: f.preferences)
        try f.tracking.delete(trackID: a.trackID)
        XCTAssertEqual(try f.service.reconcile(preferences: f.preferences), 1)
        XCTAssertNil(try f.features.crossCameraIdentityID(for: b.trackID))
        XCTAssertEqual(Set(try f.features.crossCameraIdentityAudit().map(\.action)), Set([.proposed, .accepted]))
    }

    func testChangedGraphAndRepeatedReviewFailClosedAcrossStoreInstances() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let a = try f.track(), b = try f.track(), c = try f.track()
        let ab = try f.propose(a, b), bc = try f.propose(b, c)
        let old = try f.service.snapshot()
        let preparedAB = try f.prepare(ab, [a, b], old, accept: true)
        let preparedBC = try f.prepare(bc, [b, c], old, accept: true)
        let rejectedAB = try f.prepare(ab, [a, b], old, accept: false)
        let otherFeatures = try CameraFeatureStore(url: f.root.appendingPathComponent("features.sqlite"))
        let otherTracking = try LocalTrackingStore(url: f.root.appendingPathComponent("tracks.sqlite"))
        let other = CrossCameraIdentityReviewService(tracking: otherTracking, features: otherFeatures)
        _ = try other.review(preparedAB, preferences: f.preferences)
        XCTAssertThrowsError(try f.service.review(preparedBC, preferences: f.preferences))
        XCTAssertThrowsError(try f.service.review(rejectedAB, preferences: f.preferences))
        XCTAssertEqual(try f.features.identityProposals().map(\.id), [bc.id])
        XCTAssertNil(try f.features.crossCameraIdentityID(for: c.trackID))
    }

    func testPreparedReviewBindsDecisionAndPreferences() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let a = try f.track(), b = try f.track()
        let proposal = try f.propose(a, b)
        let prepared = try f.prepare(proposal, [a, b], try f.service.snapshot(), accept: false)
        var changed = f.preferences
        changed.enabledFeatures.remove(.crossCameraIdentity)
        XCTAssertThrowsError(try f.service.review(prepared, preferences: changed))
        XCTAssertEqual(try f.features.identityProposals().map(\.id), [proposal.id])
        let result = try f.service.review(prepared, preferences: f.preferences)
        XCTAssertEqual(result.status, .rejected)
        XCTAssertThrowsError(try f.service.review(prepared, preferences: f.preferences))
    }

    func testPreparedReviewDescribesAllRelatedTracks() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let a = try f.track(), b = try f.track(), c = try f.track()
        let ab = try f.propose(a, b)
        let approved = try f.prepare(ab, [a, b], try f.service.snapshot(), accept: true)
        _ = try f.service.review(approved, preferences: f.preferences)
        let bc = try f.propose(b, c)
        let prepared = try f.prepare(bc, [b, c], try f.service.snapshot(), accept: true)
        XCTAssertEqual(Set(prepared.affectedTrackIDs), Set([a.trackID, b.trackID, c.trackID]))
        try f.tracking.delete(trackID: a.trackID)
        XCTAssertThrowsError(try f.service.review(prepared, preferences: f.preferences))
        XCTAssertEqual(try f.features.identityProposals().map(\.id), [bc.id])
    }

    func testTrackingReservationBlocksOtherSQLiteWriters() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let track = try f.track()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(f.root.appendingPathComponent("tracks.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = "DELETE FROM tracked_objects WHERE track_id='\(track.trackID.uuidString)'"
        try f.tracking.withIdentityReadReservation {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_BUSY)
            XCTAssertTrue(try f.tracking.contains(trackID: track.trackID))
        }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        XCTAssertFalse(try f.tracking.contains(trackID: track.trackID))
    }

    func testPrepareByIDUsesLiveEvidenceAndRejectsDeletedTracks() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let a = try f.track(), b = try f.track()
        let proposal = try f.propose(a, b)
        let prepared = try f.service.prepareReview(proposalID: proposal.id, accept: true, preferences: f.preferences)
        XCTAssertEqual(prepared.proposal, proposal)
        XCTAssertEqual(Set([prepared.trackA.trackID, prepared.trackB.trackID]), Set([a.trackID, b.trackID]))
        XCTAssertThrowsError(try f.service.prepareReview(proposalID: UUID(), accept: true, preferences: f.preferences))
        try f.tracking.delete(trackID: a.trackID)
        XCTAssertThrowsError(try f.service.prepareReview(proposalID: proposal.id, accept: true, preferences: f.preferences))
        XCTAssertThrowsError(try f.service.review(prepared, preferences: f.preferences))
    }

    func testReviewVerificationCoversBothDecisionsAndUndo() throws {
        for accept in [true, false] {
            let f = try Fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            let a = try f.track(), b = try f.track()
            let proposal = try f.propose(a, b)
            let prepared = try f.service.prepareReview(proposalID: proposal.id, accept: accept, preferences: f.preferences)
            XCTAssertFalse(try f.service.verifyReview(prepared, result: proposal))
            var disabled = f.preferences
            disabled.enabledFeatures.remove(.crossCameraIdentity)
            XCTAssertThrowsError(try f.service.review(prepared, preferences: disabled))
            let result = try f.service.review(prepared, preferences: f.preferences)
            XCTAssertTrue(try f.service.verifyReview(prepared, result: result))
            if accept {
                try f.service.undo(proposal: result, snapshot: f.service.snapshot(), preferences: f.preferences)
                XCTAssertFalse(try f.service.verifyReview(prepared, result: result))
            } else {
                try f.tracking.delete(trackID: a.trackID)
                XCTAssertFalse(try f.service.verifyReview(prepared, result: result))
            }
        }
    }

    func testPrepareAndVerifyFailForDeletedRelatedTrack() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let a = try f.track(), b = try f.track(), c = try f.track()
        let ab = try f.propose(a, b)
        let first = try f.service.prepareReview(proposalID: ab.id, accept: true, preferences: f.preferences)
        let firstResult = try f.service.review(first, preferences: f.preferences)
        XCTAssertTrue(try f.service.verifyReview(first, result: firstResult))
        let bc = try f.propose(b, c)
        let next = try f.service.prepareReview(proposalID: bc.id, accept: true, preferences: f.preferences)
        XCTAssertEqual(Set(next.affectedTrackIDs), Set([a.trackID, b.trackID, c.trackID]))
        try f.tracking.delete(trackID: a.trackID)
        XCTAssertFalse(try f.service.verifyReview(first, result: firstResult))
        XCTAssertThrowsError(try f.service.prepareReview(proposalID: bc.id, accept: true, preferences: f.preferences))
        XCTAssertThrowsError(try f.service.review(next, preferences: f.preferences))
    }

    func testVerificationRequiresMatchingPersistedAudit() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let proposal = try f.propose(f.track(), f.track())
        let prepared = try f.service.prepareReview(proposalID: proposal.id, accept: false, preferences: f.preferences)
        let result = try f.service.review(prepared, preferences: f.preferences)
        XCTAssertTrue(try f.service.verifyReview(prepared, result: result))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(f.root.appendingPathComponent("features.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = "DELETE FROM cross_camera_identity_audit WHERE proposal_id='\(proposal.id.uuidString)' AND action='rejected'"
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        XCTAssertFalse(try f.service.verifyReview(prepared, result: result))
    }

    func testPolicyRevisionRejectsDisableReenableAndOtherPreferenceWrites() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let url = f.root.appendingPathComponent("preferences.json")
        try CameraFeaturePreferencesStore.save(f.preferences, to: url)
        let policy = CrossCameraIdentityPolicyReviewService(tracking: f.tracking, features: f.features, preferencesURL: url)
        let proposal = try f.propose(f.track(), f.track())
        let prepared = try policy.prepareReview(proposalID: proposal.id, accept: true)
        var disabled = f.preferences
        disabled.enabledFeatures.remove(.crossCameraIdentity)
        let provider = DefaultACTAFeaturePreferencesProvider(url: url)
        try provider.savePreferences(disabled)
        try provider.savePreferences(f.preferences)
        XCTAssertThrowsError(try policy.review(prepared))
        XCTAssertEqual(try f.features.identityProposals().map(\.id), [proposal.id])

        let refreshed = try policy.prepareReview(proposalID: proposal.id, accept: false)
        var changed = f.preferences
        changed.retentionDays = 42
        try CameraFeaturePreferencesStore.save(changed, to: url)
        XCTAssertThrowsError(try policy.review(refreshed))
        let latest = try policy.prepareReview(proposalID: proposal.id, accept: false)
        XCTAssertEqual(try policy.review(latest).status, .rejected)
    }

    func testPolicyLockCoversReviewUntilSQLiteCommit() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let url = f.root.appendingPathComponent("preferences.json")
        try CameraFeaturePreferencesStore.save(f.preferences, to: url)
        let policy = CrossCameraIdentityPolicyReviewService(tracking: f.tracking, features: f.features, preferencesURL: url)
        let proposal = try f.propose(f.track(), f.track())
        let prepared = try policy.prepareReview(proposalID: proposal.id, accept: true)

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(f.root.appendingPathComponent("tracks.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        let reviewDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { reviewDone.signal() }
            do {
                let result = try policy.review(prepared)
                XCTAssertEqual(result.status, .accepted)
            }
            catch { XCTFail("Review failed: \(error)") }
        }
        let lockURL = f.root.appendingPathComponent(".preferences.json.lock")
        let fd = open(lockURL.path, O_RDWR | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { if fd >= 0 { close(fd) } }
        var held = false
        for _ in 0..<200 {
            if flock(fd, LOCK_EX | LOCK_NB) != 0 { held = true; break }
            flock(fd, LOCK_UN)
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertTrue(held, "Review did not acquire the policy lock")
        let writeDone = DispatchSemaphore(value: 0)
        let coordinator = CameraFeatureCoordinator(preferencesURL: url,
            databaseURL: f.root.appendingPathComponent("other.sqlite"))
        DispatchQueue.global().async {
            defer { writeDone.signal() }
            do {
                try coordinator.savePreferences(CameraFeaturePreferences())
                XCTFail("Conflicting policy write succeeded")
            } catch {
                XCTAssertEqual(error as? CameraFeaturePreferencesStoreError, .busy)
            }
        }
        let writeFinished = writeDone.wait(timeout: .now() + 1)
        XCTAssertEqual(writeFinished, .success, "A conflicting writer must fail without waiting")
        XCTAssertEqual(try CameraFeaturePreferencesStore.load(from: url), f.preferences)
        XCTAssertEqual(sqlite3_exec(db, "COMMIT", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(reviewDone.wait(timeout: .now() + 3), .success)
        if writeFinished != .success { _ = writeDone.wait(timeout: .now() + 3) }
        try coordinator.savePreferences(CameraFeaturePreferences())
        XCTAssertFalse(try CameraFeaturePreferencesStore.load(from: url).enabledFeatures.contains(.crossCameraIdentity))
    }

    func testPolicyWrapperRejectsDisabledFeatureAndLegacyPreferenceChange() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let url = f.root.appendingPathComponent("preferences.json")
        try JSONEncoder().encode(f.preferences).write(to: url)
        let policy = CrossCameraIdentityPolicyReviewService(tracking: f.tracking, features: f.features, preferencesURL: url)
        let proposal = try f.propose(f.track(), f.track())
        let prepared = try policy.prepareReview(proposalID: proposal.id, accept: true)
        try CameraFeaturePreferencesStore.save(CameraFeaturePreferences(), to: url)
        XCTAssertThrowsError(try policy.review(prepared))
        XCTAssertThrowsError(try policy.prepareReview(proposalID: proposal.id, accept: true))
        XCTAssertThrowsError(try policy.reconcile())
    }

    func testPolicyLockConflictFailsClosedAndRetrySucceeds() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let url = f.root.appendingPathComponent("preferences.json")
        try CameraFeaturePreferencesStore.save(f.preferences, to: url)
        let policy = CrossCameraIdentityPolicyReviewService(tracking: f.tracking, features: f.features, preferencesURL: url)
        let proposal = try f.propose(f.track(), f.track())
        let prepared = try policy.prepareReview(proposalID: proposal.id, accept: true)
        let fd = open(f.root.appendingPathComponent(".preferences.json.lock").path, O_RDWR | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { if fd >= 0 { close(fd) } }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        for operation in [
            { _ = try policy.review(prepared) },
            { try CameraFeaturePreferencesStore.save(CameraFeaturePreferences(), to: url) },
            { _ = try CameraFeaturePreferencesStore.update(at: url) { $0.retentionDays = 42 } }
        ] {
            XCTAssertThrowsError(try operation()) { error in
                XCTAssertEqual(error as? CameraFeaturePreferencesStoreError, .busy)
                XCTAssertEqual(error.localizedDescription, "Feature preferences are busy. Please try again.")
            }
        }
        XCTAssertEqual(try f.features.identityProposals().map(\.id), [proposal.id])
        XCTAssertEqual(try CameraFeaturePreferencesStore.load(from: url), f.preferences)
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        XCTAssertEqual(try policy.review(prepared).status, .accepted)
        try CameraFeaturePreferencesStore.save(CameraFeaturePreferences(), to: url)
        XCTAssertEqual(try CameraFeaturePreferencesStore.load(from: url), CameraFeaturePreferences())
    }

    func testAtomicIdentityTogglePreservesCurrentOtherPreferences() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let url = f.root.appendingPathComponent("preferences.json")
        var current = f.preferences
        current.retentionDays = 42
        current.enabledFeatures.insert(.historyResearch)
        try CameraFeaturePreferencesStore.save(current, to: url)
        let updated = try CameraFeaturePreferencesStore.update(at: url) {
            $0.enabledFeatures.remove(.crossCameraIdentity)
        }
        XCTAssertEqual(updated.retentionDays, 42)
        XCTAssertTrue(updated.enabledFeatures.contains(.historyResearch))
        XCTAssertFalse(updated.enabledFeatures.contains(.crossCameraIdentity))
        XCTAssertEqual(try CameraFeaturePreferencesStore.load(from: url), updated)
    }
}
