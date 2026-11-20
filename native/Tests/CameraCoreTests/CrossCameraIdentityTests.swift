import XCTest
import SQLite3
@testable import CameraCore

final class CrossCameraIdentityTests: XCTestCase {
    func testReviewDecisionUsesSidecarAndNeverChangesOperatorGroups() throws {
        let fixture = try IsolatedStoreTestDirectory()
        defer { try? fixture.remove() }
        let directory = fixture.url
        let featureStore = try CameraFeatureStore(url: directory.appendingPathComponent("features.sqlite3"))
        let trackingStore = try LocalTrackingStore(url: directory.appendingPathComponent("tracking.sqlite3"))
        let trackA = UUID()
        let trackB = UUID()
        let category = "person"
        for (trackID, cameraID) in [(trackA, UUID()), (trackB, UUID())] {
            let object = DetectedObject(
                id: 0,
                label: category,
                confidence: 0.9,
                box: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                trackID: trackID
            )
            _ = try trackingStore.record(object, cameraID: cameraID, cameraName: "Camera")
        }
        let preferences = CameraFeaturePreferences(enabledFeatures: [.crossCameraIdentity])

        let proposal = try featureStore.proposeIdentityMatch(
            trackA: trackA,
            trackB: trackB,
            category: category,
            cosineDistance: 0.12,
            preferences: preferences
        )
        XCTAssertEqual(proposal.status, .pending)
        XCTAssertEqual(try trackingStore.recentTracks().compactMap(\.operatorGroupID), [])

        let reviewed = try featureStore.reviewIdentityProposal(
            id: proposal.id,
            accept: true,
            preferences: preferences
        )
        XCTAssertEqual(reviewed.status, .accepted)
        XCTAssertNotNil(reviewed.identityID)
        XCTAssertEqual(try featureStore.crossCameraIdentityID(for: trackA), reviewed.identityID)
        XCTAssertEqual(try featureStore.crossCameraIdentityID(for: trackB), reviewed.identityID)
        XCTAssertTrue(try featureStore.hasIdentityDecision(trackA: trackA, trackB: trackB))
        XCTAssertEqual(try trackingStore.recentTracks().compactMap(\.operatorGroupID), [])
        XCTAssertEqual(try featureStore.crossCameraIdentityAudit().map(\.action), [.accepted, .proposed])
    }

    func testRejectedPairBecomesCannotLinkAndFeatureMustBeEnabled() throws {
        let fixture = try IsolatedStoreTestDirectory()
        defer { try? fixture.remove() }
        let directory = fixture.url
        let store = try CameraFeatureStore(url: directory.appendingPathComponent("features.sqlite3"))
        let trackA = UUID()
        let trackB = UUID()

        XCTAssertThrowsError(try store.proposeIdentityMatch(
            trackA: trackA,
            trackB: trackB,
            category: "person",
            cosineDistance: 0.1,
            preferences: CameraFeaturePreferences()
        ))

        let preferences = CameraFeaturePreferences(enabledFeatures: [.crossCameraIdentity])
        let proposal = try store.proposeIdentityMatch(
            trackA: trackA,
            trackB: trackB,
            category: "person",
            cosineDistance: 0.1,
            preferences: preferences
        )
        let rejected = try store.reviewIdentityProposal(id: proposal.id, accept: false, preferences: preferences)
        XCTAssertEqual(rejected.status, .rejected)
        XCTAssertThrowsError(try store.proposeIdentityMatch(
            trackA: trackB,
            trackB: trackA,
            category: "person",
            cosineDistance: 0.08,
            preferences: preferences
        )) { error in
            guard case CameraFeatureStoreError.identityCannotLink = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCannotLinkBlocksTransitiveIdentityMerge() throws {
        let fixture = try IsolatedStoreTestDirectory()
        defer { try? fixture.remove() }
        let directory = fixture.url
        let store = try CameraFeatureStore(url: directory.appendingPathComponent("features.sqlite3"))
        let preferences = CameraFeaturePreferences(enabledFeatures: [.crossCameraIdentity])
        let trackA = UUID()
        let trackB = UUID()
        let trackC = UUID()

        let rejectedPair = try store.proposeIdentityMatch(
            trackA: trackA, trackB: trackB, category: "person", cosineDistance: 0.3,
            preferences: preferences
        )
        _ = try store.reviewIdentityProposal(id: rejectedPair.id, accept: false, preferences: preferences)
        let acceptedPair = try store.proposeIdentityMatch(
            trackA: trackA, trackB: trackC, category: "person", cosineDistance: 0.1,
            preferences: preferences
        )
        _ = try store.reviewIdentityProposal(id: acceptedPair.id, accept: true, preferences: preferences)

        let transitiveProposal = try store.proposeIdentityMatch(
            trackA: trackB, trackB: trackC, category: "person", cosineDistance: 0.1,
            preferences: preferences
        )
        XCTAssertThrowsError(try store.reviewIdentityProposal(
            id: transitiveProposal.id, accept: true, preferences: preferences
        )) { error in
            guard case CameraFeatureStoreError.identityCannotLink = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertNil(try store.crossCameraIdentityID(for: trackB))
        XCTAssertEqual(try store.identityProposals().map(\.id), [transitiveProposal.id])
    }

    func testUndoAcceptedEdgeSplitsIdentityChainTransactionally() throws {
        let fixture = try IsolatedStoreTestDirectory()
        defer { try? fixture.remove() }
        let directory = fixture.url
        let store = try CameraFeatureStore(url: directory.appendingPathComponent("features.sqlite3"))
        let preferences = CameraFeaturePreferences(enabledFeatures: [.crossCameraIdentity])
        let trackA = UUID()
        let trackB = UUID()
        let trackC = UUID()
        func accept(_ lhs: UUID, _ rhs: UUID) throws -> CrossCameraIdentityProposal {
            let proposal = try store.proposeIdentityMatch(
                trackA: lhs, trackB: rhs, category: "person", cosineDistance: 0.1,
                preferences: preferences
            )
            return try store.reviewIdentityProposal(id: proposal.id, accept: true, preferences: preferences)
        }

        let edgeAB = try accept(trackA, trackB)
        let edgeBC = try accept(trackB, trackC)
        XCTAssertEqual(try store.crossCameraIdentityID(for: trackA), try store.crossCameraIdentityID(for: trackC))

        try store.undoIdentityProposal(id: edgeAB.id, preferences: preferences)

        XCTAssertNotEqual(try store.crossCameraIdentityID(for: trackA), try store.crossCameraIdentityID(for: trackB))
        XCTAssertEqual(try store.crossCameraIdentityID(for: trackB), try store.crossCameraIdentityID(for: trackC))
        XCTAssertEqual(try store.identityProposals(status: .accepted).map(\.id), [edgeBC.id])
        XCTAssertFalse(try store.hasIdentityDecision(trackA: trackA, trackB: trackB))
        XCTAssertEqual(try store.crossCameraIdentityAudit().first?.action, .undone)
        XCTAssertThrowsError(try store.undoIdentityProposal(id: edgeAB.id, preferences: preferences)) { error in
            guard case CameraFeatureStoreError.identityProposalAlreadyUndone(edgeAB.id) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testReconciliationRemovesExpiredTrackLinksButKeepsAudit() throws {
        let fixture = try IsolatedStoreTestDirectory()
        defer { try? fixture.remove() }
        let directory = fixture.url
        let trackingStore = try LocalTrackingStore(url: directory.appendingPathComponent("tracking.sqlite3"))
        let featureStore = try CameraFeatureStore(url: directory.appendingPathComponent("features.sqlite3"))
        let trackA = UUID()
        let trackB = UUID()
        for trackID in [trackA, trackB] {
            let object = DetectedObject(
                id: 0, label: "person", confidence: 0.9,
                box: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), trackID: trackID
            )
            _ = try trackingStore.record(object, cameraID: UUID(), cameraName: "Camera")
        }
        let preferences = CameraFeaturePreferences(enabledFeatures: [.crossCameraIdentity])
        let proposal = try featureStore.proposeIdentityMatch(
            trackA: trackA, trackB: trackB, category: "person", cosineDistance: 0.1,
            preferences: preferences
        )
        _ = try featureStore.reviewIdentityProposal(id: proposal.id, accept: true, preferences: preferences)
        try trackingStore.delete(trackID: trackA)

        XCTAssertEqual(try featureStore.reconcileIdentityTracks(
            existingTrackIDs: trackingStore.trackIDs(), preferences: preferences
        ), 1)
        XCTAssertNil(try featureStore.crossCameraIdentityID(for: trackB))
        XCTAssertFalse(try featureStore.hasIdentityDecision(trackA: trackA, trackB: trackB))
        XCTAssertEqual(try featureStore.crossCameraIdentityAudit().map(\.action), [.accepted, .proposed])
    }

    func testVersionOneFeatureDatabaseMigratesWithoutReplacingExistingTables() throws {
        let fixture = try IsolatedStoreTestDirectory()
        defer { try? fixture.remove() }
        let directory = fixture.url
        let databaseURL = directory.appendingPathComponent("features.sqlite3")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        let setupResult = sqlite3_exec(
            database,
            "CREATE TABLE feature_jobs (id TEXT PRIMARY KEY); PRAGMA user_version = 1;",
            nil,
            nil,
            nil
        )
        XCTAssertEqual(setupResult, SQLITE_OK)
        sqlite3_close(database)

        let migratedStore = try CameraFeatureStore(url: databaseURL)
        XCTAssertTrue(try migratedStore.operatorActions().isEmpty)
        XCTAssertTrue(try migratedStore.operationsAlertReviews().isEmpty)

        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        var versionStatement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &versionStatement, nil), SQLITE_OK)
        defer { sqlite3_finalize(versionStatement) }
        XCTAssertEqual(sqlite3_step(versionStatement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(versionStatement, 0), 7)

        var tableStatement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(
            database,
            "SELECT name FROM sqlite_master WHERE type='table' AND name='feature_jobs'",
            -1,
            &tableStatement,
            nil
        ), SQLITE_OK)
        defer { sqlite3_finalize(tableStatement) }
        XCTAssertEqual(sqlite3_step(tableStatement), SQLITE_ROW)
    }

    func testCalibratedCandidateSelectorOnlyReturnsReviewCandidatesUnderThreshold() {
        let close = makeCandidate(distance: 0.1)
        let distant = makeCandidate(distance: 0.4)

        XCTAssertTrue(CrossCameraIdentityCandidateSelector.calibratedReviewCandidates(
            [close, distant], recommendedDistance: nil
        ).isEmpty)
        XCTAssertEqual(
            CrossCameraIdentityCandidateSelector.calibratedReviewCandidates(
                [close, distant], recommendedDistance: 0.2
            ).map(\.id),
            [close.id]
        )
        XCTAssertTrue(CrossCameraIdentityCandidateSelector.calibratedReviewCandidates(
            [close], recommendedDistance: .nan
        ).isEmpty)
    }

    func testCandidateEvidenceRejectsInvalidPairsBeforeCalibration() {
        for distance in [-0.1, 2.1, Double.nan, .infinity] {
            XCTAssertNil(CrossCameraIdentityCandidateSelector.evidence(for: makeCandidate(distance: distance)))
        }
        XCTAssertNil(CrossCameraIdentityCandidateSelector.evidence(for: makeCandidate(distance: 0.1, sameCamera: true)))
        XCTAssertNil(CrossCameraIdentityCandidateSelector.evidence(for: makeCandidate(distance: 0.1, labelB: "car")))
        XCTAssertNil(CrossCameraIdentityCandidateSelector.evidence(for: makeCandidate(distance: 0.1, firstA: 20, lastA: 10)))
        XCTAssertTrue(CrossCameraIdentityCandidateSelector.calibratedReviewCandidates(
            [makeCandidate(distance: -0.1)], recommendedDistance: 0.2
        ).isEmpty)
    }

    func testTemporalEvidenceReportsOverlapWithoutInventingCameraTopology() throws {
        let overlapping = makeCandidate(distance: 0.1, firstA: 10, lastA: 30, firstB: 20, lastB: 40)
        let evidence = try XCTUnwrap(CrossCameraIdentityCandidateSelector.evidence(for: overlapping))
        XCTAssertNil(evidence.gapSeconds)
        XCTAssertEqual(evidence.overlapSeconds, 10)
        XCTAssertEqual(CrossCameraIdentityCandidateSelector.calibratedReviewCandidates(
            [overlapping], recommendedDistance: 0.2
        ).count, 1)
        let ordered = try XCTUnwrap(CrossCameraIdentityCandidateSelector.evidence(
            for: makeCandidate(distance: 0.1, firstA: 30, lastA: 40, firstB: 10, lastB: 20)
        ))
        XCTAssertEqual(ordered.gapSeconds, 10)
        XCTAssertEqual(ordered.overlapSeconds, 0)
    }

    func testCandidateRankingDeduplicatesPairsAndPrefersCloserAppearance() {
        let close = makeCandidate(distance: 0.1)
        let distant = makeCandidate(distance: 0.3)
        let reversed = ReIDValidationCandidate(trackA: close.trackB, trackB: close.trackA, distance: close.distance)
        let ranked = CrossCameraIdentityCandidateSelector.rankedReviewEvidence([distant, close, reversed])
        XCTAssertEqual(ranked.map(\.id), [close.id, distant.id])
    }

    private func makeCandidate(
        distance: Double, sameCamera: Bool = false, labelB: String = "person",
        firstA: TimeInterval = 10, lastA: TimeInterval = 20,
        firstB: TimeInterval = 30, lastB: TimeInterval = 40
    ) -> ReIDValidationCandidate {
        let cameraA = UUID()
        let recordA = TrackedObjectRecord(
            trackID: UUID(), cameraID: cameraA, cameraName: "Front", label: "person",
            firstSeen: Date(timeIntervalSince1970: firstA), lastSeen: Date(timeIntervalSince1970: lastA),
            observationCount: 1, bestConfidence: 0.9,
            box: .zero, cropPath: nil, cutoutPath: nil, operatorGroupID: nil,
            description: nil, describedAt: nil
        )
        let recordB = TrackedObjectRecord(
            trackID: UUID(), cameraID: sameCamera ? cameraA : UUID(), cameraName: "Back", label: labelB,
            firstSeen: Date(timeIntervalSince1970: firstB), lastSeen: Date(timeIntervalSince1970: lastB),
            observationCount: 1, bestConfidence: 0.9,
            box: .zero, cropPath: nil, cutoutPath: nil, operatorGroupID: nil,
            description: nil, describedAt: nil
        )
        return ReIDValidationCandidate(trackA: recordA, trackB: recordB, distance: distance)
    }
}