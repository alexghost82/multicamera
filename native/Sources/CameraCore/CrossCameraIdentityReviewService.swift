import Foundation

public struct CrossCameraIdentityReviewSnapshot: Sendable {
    public let proposals: [CrossCameraIdentityProposal]
    public let accepted: [CrossCameraIdentityProposal]
    public let assignments: [UUID: UUID]
    fileprivate let graph: [String]
    fileprivate let graphTrackIDs: Set<UUID>
    fileprivate let store: IdentityStoreSnapshot
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
    fileprivate let affectedRecords: [UUID: TrackedObjectRecord]
}

public struct CrossCameraIdentityPolicyPreparedReview: Identifiable, Sendable {
    public var id: UUID { review.id }
    public let review: CrossCameraIdentityPreparedReview
    fileprivate let policyRevision: String?
}

/// Frozen input for an undo; preparing it is not operator approval.
/// This value is not an authorization token or an outcome-verification receipt.
public struct CrossCameraIdentityPreparedUndo: Identifiable, Sendable {
    public let id = UUID()
    public let proposal: CrossCameraIdentityProposal
    /// Undo rebuilds the entire graph, not just the proposal's component.
    public let graphTrackIDs: [UUID]
    fileprivate let snapshot: CrossCameraIdentityReviewSnapshot
    fileprivate let preferences: CameraFeaturePreferences
    fileprivate let records: [UUID: TrackedObjectRecord]
}

public struct CrossCameraIdentityPolicyPreparedUndo: Identifiable, Sendable {
    public var id: UUID { undo.id }
    public let undo: CrossCameraIdentityPreparedUndo
    fileprivate let policyRevision: String?
}

/// Serializes policy changes and identity writes for cooperating preferences-store writers.
public struct CrossCameraIdentityPolicyReviewService: Sendable {
    private let service: CrossCameraIdentityReviewService
    private let preferencesURL: URL

    public init(tracking: LocalTrackingStore, features: CameraFeatureStore, preferencesURL: URL) {
        service = CrossCameraIdentityReviewService(tracking: tracking, features: features)
        self.preferencesURL = preferencesURL
    }

    public func prepareReview(proposal: CrossCameraIdentityProposal, records: [TrackedObjectRecord],
                              snapshot: CrossCameraIdentityReviewSnapshot,
                              accept: Bool) throws -> CrossCameraIdentityPolicyPreparedReview {
        try CameraFeaturePreferencesStore.withLockedSnapshot(from: preferencesURL) { policy in
            let prepared = try service.prepareReview(proposal: proposal, records: records, snapshot: snapshot,
                                                     accept: accept, preferences: policy.preferences)
            return CrossCameraIdentityPolicyPreparedReview(review: prepared, policyRevision: policy.revision)
        }
    }

    public func prepareReview(proposalID: UUID, accept: Bool) throws -> CrossCameraIdentityPolicyPreparedReview {
        try CameraFeaturePreferencesStore.withLockedSnapshot(from: preferencesURL) { policy in
            let prepared = try service.prepareReview(proposalID: proposalID, accept: accept,
                                                     preferences: policy.preferences)
            return CrossCameraIdentityPolicyPreparedReview(review: prepared, policyRevision: policy.revision)
        }
    }

    @discardableResult
    public func review(_ prepared: CrossCameraIdentityPolicyPreparedReview) throws -> CrossCameraIdentityProposal {
        try CameraFeaturePreferencesStore.withLockedSnapshot(from: preferencesURL) { policy in
            guard policy.revision == prepared.policyRevision else { throw CameraFeatureStoreError.identityReviewStale }
            return try service.review(prepared.review, preferences: policy.preferences)
        }
    }

    @discardableResult
    public func reconcile() throws -> Int {
        try CameraFeaturePreferencesStore.withLockedSnapshot(from: preferencesURL) {
            try service.reconcile(preferences: $0.preferences)
        }
    }

    @discardableResult
    public func propose(candidate: ReIDValidationCandidate) throws -> CrossCameraIdentityProposal {
        try CameraFeaturePreferencesStore.withLockedSnapshot(from: preferencesURL) {
            try service.propose(candidate: candidate, preferences: $0.preferences)
        }
    }

    public func undo(proposal: CrossCameraIdentityProposal, snapshot: CrossCameraIdentityReviewSnapshot) throws {
        try CameraFeaturePreferencesStore.withLockedSnapshot(from: preferencesURL) {
            try service.undo(proposal: proposal, snapshot: snapshot, preferences: $0.preferences)
        }
    }

    public func prepareUndo(proposalID: UUID) throws -> CrossCameraIdentityPolicyPreparedUndo {
        try CameraFeaturePreferencesStore.withLockedSnapshot(from: preferencesURL) { policy in
            let prepared = try service.prepareUndo(proposalID: proposalID, preferences: policy.preferences)
            return CrossCameraIdentityPolicyPreparedUndo(undo: prepared, policyRevision: policy.revision)
        }
    }

    public func undo(_ prepared: CrossCameraIdentityPolicyPreparedUndo) throws {
        try CameraFeaturePreferencesStore.withLockedSnapshot(from: preferencesURL) { policy in
            guard policy.revision == prepared.policyRevision else { throw CameraFeatureStoreError.identityReviewStale }
            try service.undo(prepared.undo, preferences: policy.preferences)
        }
    }
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
            assignments: snapshot.assignments, graph: snapshot.graph, graphTrackIDs: snapshot.graphTrackIDs,
            store: snapshot.store
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
        var affectedRecords: [UUID: TrackedObjectRecord] = [:]
        for id in affected {
            guard let record = try tracking.track(trackID: id) else {
                throw CameraFeatureStoreError.identityReviewStale
            }
            affectedRecords[id] = record
        }
        guard affectedRecords[a.trackID] == a, affectedRecords[b.trackID] == b else {
            throw CameraFeatureStoreError.identityReviewStale
        }
        return CrossCameraIdentityPreparedReview(
            proposal: proposal, trackA: a, trackB: b, accept: accept, affectedTrackIDs: affected,
            snapshot: snapshot, preferences: preferences, affectedRecords: affectedRecords
        )
    }

    /// Captures the pending proposal and its current source records without modifying either store.
    /// Callers must display this exact prepared review before seeking confirmation.
    public func prepareReview(
        proposalID: UUID, accept: Bool, preferences: CameraFeaturePreferences
    ) throws -> CrossCameraIdentityPreparedReview {
        try tracking.withIdentityReadReservation {
            let snapshot = try snapshot()
            guard let proposal = snapshot.proposals.first(where: { $0.id == proposalID }),
                  let a = try tracking.track(trackID: proposal.trackA),
                  let b = try tracking.track(trackID: proposal.trackB) else {
                throw CameraFeatureStoreError.identityReviewStale
            }
            let prepared = try prepareReview(
                proposal: proposal, records: [a, b], snapshot: snapshot,
                accept: accept, preferences: preferences
            )
            for id in prepared.affectedTrackIDs {
                guard try tracking.contains(trackID: id) else {
                    throw CameraFeatureStoreError.identityReviewStale
                }
            }
            return prepared
        }
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
                guard try tracking.track(trackID: trackID) == prepared.affectedRecords[trackID] else {
                    throw CameraFeatureStoreError.identityReviewStale
                }
            }
            return try features.reviewIdentityProposal(
                id: proposal.id, accept: prepared.accept, preferences: preferences,
                expectedProposal: proposal, expectedGraph: prepared.snapshot.graph,
                expectedStore: prepared.snapshot.store
            )
        }
    }

    /// Conservative read-after-write verification. A false result can also mean the
    /// review was subsequently changed or fell outside the bounded history queries.
    public func verifyReview(_ prepared: CrossCameraIdentityPreparedReview,
                             result: CrossCameraIdentityProposal) throws -> Bool {
        let original = prepared.proposal
        let expectedStatus: CrossCameraIdentityProposalStatus = prepared.accept ? .accepted : .rejected
        guard result.id == original.id, result.trackA == original.trackA, result.trackB == original.trackB,
              result.category == original.category, result.cosineDistance == original.cosineDistance,
              result.createdAt == original.createdAt, result.status == expectedStatus,
              let reviewedAt = result.reviewedAt,
              prepared.accept ? result.identityID != nil : result.identityID == nil else { return false }

        return try tracking.withIdentityReadReservation {
            guard try tracking.track(trackID: original.trackA) == prepared.trackA,
                  try tracking.track(trackID: original.trackB) == prepared.trackB else { return false }
            for id in prepared.affectedTrackIDs {
                guard try tracking.track(trackID: id) == prepared.affectedRecords[id] else { return false }
            }
            let before = try snapshot()
            guard try features.identityProposals(status: expectedStatus, limit: 1000).contains(result) else {
                return false
            }
            let expectedAction: CrossCameraIdentityAuditAction = prepared.accept ? .accepted : .rejected
            guard try features.crossCameraIdentityAudit(limit: 2000).contains(where: {
                $0.proposalID == original.id && $0.action == expectedAction &&
                $0.trackA == original.trackA && $0.trackB == original.trackB &&
                $0.identityID == result.identityID && $0.occurredAt == reviewedAt
            }) else { return false }
            if let identityID = result.identityID {
                guard prepared.affectedTrackIDs.allSatisfy({ before.assignments[$0] == identityID }) else {
                    return false
                }
            } else {
                let pair = [original.trackA.uuidString, original.trackB.uuidString].sorted()
                guard before.graph.contains("cannot:\(pair[0]):\(pair[1])") else { return false }
            }
            let after = try snapshot()
            return before.graph == after.graph && before.assignments == after.assignments
        }
    }

    public func undo(proposal: CrossCameraIdentityProposal, snapshot: CrossCameraIdentityReviewSnapshot,
                     preferences: CameraFeaturePreferences) throws {
        guard snapshot.accepted.contains(proposal) else { throw CameraFeatureStoreError.identityReviewStale }
        try tracking.withIdentityReadReservation {
            // Undo rebuilds the entire sidecar graph, including unrelated components.
            for trackID in snapshot.graphTrackIDs.union(snapshot.assignments.keys) {
                guard try tracking.contains(trackID: trackID) else {
                    throw CameraFeatureStoreError.identityReviewStale
                }
            }
            try features.undoIdentityProposal(
                id: proposal.id, preferences: preferences,
                expectedProposal: proposal, expectedGraph: snapshot.graph, expectedStore: snapshot.store
            )
        }
    }

    /// Freezes every tracking record involved in the sidecar's whole-graph rebuild.
    public func prepareUndo(proposalID: UUID, preferences: CameraFeaturePreferences) throws
        -> CrossCameraIdentityPreparedUndo {
        try preferences.validate()
        guard preferences.enabledFeatures.contains(.crossCameraIdentity) else {
            throw CameraFeatureStoreError.featureDisabled(.crossCameraIdentity)
        }
        return try tracking.withIdentityReadReservation {
            let current = try snapshot()
            guard let proposal = current.accepted.first(where: { $0.id == proposalID }) else {
                throw CameraFeatureStoreError.identityReviewStale
            }
            let ids = current.graphTrackIDs.union(current.assignments.keys)
                .sorted { $0.uuidString < $1.uuidString }
            var records: [UUID: TrackedObjectRecord] = [:]
            for id in ids {
                guard let record = try tracking.track(trackID: id) else {
                    throw CameraFeatureStoreError.identityReviewStale
                }
                records[id] = record
            }
            return CrossCameraIdentityPreparedUndo(proposal: proposal, graphTrackIDs: ids,
                snapshot: current, preferences: preferences, records: records)
        }
    }

    /// A thrown error is not proof of rollback after an uncertain storage failure.
    public func undo(_ prepared: CrossCameraIdentityPreparedUndo,
                     preferences: CameraFeaturePreferences) throws {
        guard preferences == prepared.preferences else { throw CameraFeatureStoreError.identityReviewStale }
        try tracking.withIdentityReadReservation {
            for id in prepared.graphTrackIDs {
                guard try tracking.track(trackID: id) == prepared.records[id] else {
                    throw CameraFeatureStoreError.identityReviewStale
                }
            }
            try features.undoIdentityProposal(
                id: prepared.proposal.id, preferences: preferences,
                expectedProposal: prepared.proposal, expectedGraph: prepared.snapshot.graph,
                expectedStore: prepared.snapshot.store
            )
        }
    }
}
