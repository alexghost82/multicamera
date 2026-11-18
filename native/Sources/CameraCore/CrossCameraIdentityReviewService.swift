import Foundation

public struct CrossCameraIdentityReviewSnapshot: Sendable {
    public let proposals: [CrossCameraIdentityProposal]
    public let accepted: [CrossCameraIdentityProposal]
    public let assignments: [UUID: UUID]
    fileprivate let graph: [String]
}

/// A frozen GUI review request; constructing it does not itself constitute approval.
public struct CrossCameraIdentityPreparedReview: Identifiable, Sendable {
    public let id = UUID()
    public let proposal: CrossCameraIdentityProposal
    public let trackA: TrackedObjectRecord
    public let trackB: TrackedObjectRecord
    public let accept: Bool
    public let affectedTrackIDs: [UUID]
    fileprivate let snapshot: CrossCameraIdentityReviewSnapshot
    fileprivate let preferences: CameraFeaturePreferences
}

/// Coordinates SQLite writers, not crash recovery across stores. Preferences are
/// caller-supplied snapshots and are not locked against concurrent file writes.
public struct CrossCameraIdentityReviewService: Sendable {
    private let tracking: LocalTrackingStore
    private let features: CameraFeatureStore

    public init(tracking: LocalTrackingStore, features: CameraFeatureStore) {
        self.tracking = tracking
        self.features = features
    }

    public func snapshot() throws -> CrossCameraIdentityReviewSnapshot {
        let snapshot = try features.identityReviewSnapshot()
        return CrossCameraIdentityReviewSnapshot(
            proposals: snapshot.proposals, accepted: snapshot.accepted,
            assignments: snapshot.assignments, graph: snapshot.graph
        )
    }

    @discardableResult
    public func reconcile(preferences: CameraFeaturePreferences) throws -> Int {
        try tracking.withIdentityReadReservation {
            try features.reconcileIdentityTracks(existingTrackIDs: tracking.trackIDs(), preferences: preferences)
        }
    }

    @discardableResult
    public func propose(candidate: ReIDValidationCandidate, preferences: CameraFeaturePreferences) throws -> CrossCameraIdentityProposal {
        guard let evidence = CrossCameraIdentityCandidateSelector.evidence(for: candidate) else {
            throw CameraFeatureStoreError.invalidIdentityProposal
        }
        return try tracking.withIdentityReadReservation {
            guard try tracking.track(trackID: candidate.trackA.trackID) == candidate.trackA,
                  try tracking.track(trackID: candidate.trackB.trackID) == candidate.trackB else {
                throw CameraFeatureStoreError.identityReviewStale
            }
            return try features.proposeIdentityMatch(
                trackA: candidate.trackA.trackID, trackB: candidate.trackB.trackID,
                category: evidence.category, cosineDistance: candidate.distance, preferences: preferences
            )
        }
    }

    @discardableResult
    public func prepareReview(
        proposal: CrossCameraIdentityProposal, records: [TrackedObjectRecord],
        snapshot: CrossCameraIdentityReviewSnapshot, accept: Bool,
        preferences: CameraFeaturePreferences
    ) throws -> CrossCameraIdentityPreparedReview {
        try preferences.validate()
        guard preferences.enabledFeatures.contains(.crossCameraIdentity) else {
            throw CameraFeatureStoreError.featureDisabled(.crossCameraIdentity)
        }
        guard snapshot.proposals.contains(proposal),
              let a = records.first(where: { $0.trackID == proposal.trackA }),
              let b = records.first(where: { $0.trackID == proposal.trackB }) else {
            throw CameraFeatureStoreError.identityReviewStale
        }
        let candidate = ReIDValidationCandidate(trackA: a, trackB: b, distance: proposal.cosineDistance)
        guard CrossCameraIdentityCandidateSelector.evidence(for: candidate)?.category == proposal.category else {
            throw CameraFeatureStoreError.identityReviewStale
        }
        let identities = Set([snapshot.assignments[a.trackID], snapshot.assignments[b.trackID]].compactMap { $0 })
        let affected = Set(snapshot.assignments.compactMap { identities.contains($0.value) ? $0.key : nil })
            .union([a.trackID, b.trackID])
            .sorted { $0.uuidString < $1.uuidString }
        return CrossCameraIdentityPreparedReview(
            proposal: proposal, trackA: a, trackB: b, accept: accept, affectedTrackIDs: affected,
            snapshot: snapshot, preferences: preferences
        )
    }

    @discardableResult
    public func review(_ prepared: CrossCameraIdentityPreparedReview,
                       preferences: CameraFeaturePreferences) throws -> CrossCameraIdentityProposal {
        guard preferences == prepared.preferences else { throw CameraFeatureStoreError.identityReviewStale }
        let proposal = prepared.proposal
        return try tracking.withIdentityReadReservation {
            guard try tracking.track(trackID: proposal.trackA) == prepared.trackA,
                  try tracking.track(trackID: proposal.trackB) == prepared.trackB else {
                throw CameraFeatureStoreError.identityReviewStale
            }
            for trackID in prepared.affectedTrackIDs {
                guard try tracking.contains(trackID: trackID) else {
                    throw CameraFeatureStoreError.identityReviewStale
                }
            }
            return try features.reviewIdentityProposal(
                id: proposal.id, accept: prepared.accept, preferences: preferences,
                expectedProposal: proposal, expectedGraph: prepared.snapshot.graph
            )
        }
    }

    public func undo(proposal: CrossCameraIdentityProposal, snapshot: CrossCameraIdentityReviewSnapshot,
                     preferences: CameraFeaturePreferences) throws {
        guard snapshot.accepted.contains(proposal) else { throw CameraFeatureStoreError.identityReviewStale }
        try tracking.withIdentityReadReservation {
            guard try tracking.contains(trackID: proposal.trackA),
                  try tracking.contains(trackID: proposal.trackB) else {
                throw CameraFeatureStoreError.identityReviewStale
            }
            try features.undoIdentityProposal(
                id: proposal.id, preferences: preferences,
                expectedProposal: proposal, expectedGraph: snapshot.graph
            )
        }
    }
}
