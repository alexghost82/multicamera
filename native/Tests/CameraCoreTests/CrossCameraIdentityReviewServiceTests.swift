import Foundation
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
}
