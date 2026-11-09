import Foundation

public enum CrossCameraIdentityProposalStatus: String, Codable, Sendable {
    case pending
    case accepted
    case rejected
}

public struct CrossCameraIdentityProposal: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let trackA: UUID
    public let trackB: UUID
    public let category: String
    public let cosineDistance: Double
    public let status: CrossCameraIdentityProposalStatus
    public let createdAt: Date
    public let reviewedAt: Date?
    public let identityID: UUID?
}

public enum CrossCameraIdentityAuditAction: String, Codable, Sendable {
    case proposed
    case accepted
    case rejected
    case undone
}

public struct CrossCameraIdentityAuditEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let proposalID: UUID
    public let action: CrossCameraIdentityAuditAction
    public let trackA: UUID
    public let trackB: UUID
    public let identityID: UUID?
    public let occurredAt: Date
}

public struct CrossCameraIdentityCandidateEvidence: Identifiable, Sendable {
    public let candidate: ReIDValidationCandidate
    public let category: String
    public let gapSeconds: TimeInterval?
    public let overlapSeconds: TimeInterval
    public let differentOperatorGroups: Bool

    public var id: String { candidate.id }
    public var earliestSeen: Date { min(candidate.trackA.firstSeen, candidate.trackB.firstSeen) }
    public var latestSeen: Date { max(candidate.trackA.lastSeen, candidate.trackB.lastSeen) }
}

public enum CrossCameraIdentityCandidateSelector {
    public static func evidence(for candidate: ReIDValidationCandidate) -> CrossCameraIdentityCandidateEvidence? {
        let trackA = candidate.trackA
        let trackB = candidate.trackB
        guard trackA.trackID != trackB.trackID, trackA.cameraID != trackB.cameraID,
              candidate.distance.isFinite, (0...2).contains(candidate.distance),
              let category = Self.category(trackA.label), category == Self.category(trackB.label),
              [trackA, trackB].allSatisfy({
                  $0.firstSeen.timeIntervalSince1970.isFinite && $0.lastSeen.timeIntervalSince1970.isFinite
                      && $0.firstSeen <= $0.lastSeen && $0.observationCount > 0
                      && $0.bestConfidence.isFinite && (0...1).contains($0.bestConfidence)
              }) else { return nil }
        let overlap = max(0, min(trackA.lastSeen, trackB.lastSeen).timeIntervalSince(max(trackA.firstSeen, trackB.firstSeen)))
        let gap: TimeInterval?
        if trackA.lastSeen <= trackB.firstSeen {
            gap = trackB.firstSeen.timeIntervalSince(trackA.lastSeen)
        } else if trackB.lastSeen <= trackA.firstSeen {
            gap = trackA.firstSeen.timeIntervalSince(trackB.lastSeen)
        } else {
            gap = nil
        }
        return CrossCameraIdentityCandidateEvidence(
            candidate: candidate, category: category, gapSeconds: gap, overlapSeconds: overlap,
            differentOperatorGroups: trackA.operatorGroupID != nil && trackB.operatorGroupID != nil
                && trackA.operatorGroupID != trackB.operatorGroupID
        )
    }

    public static func rankedReviewEvidence(
        _ candidates: [ReIDValidationCandidate]
    ) -> [CrossCameraIdentityCandidateEvidence] {
        var seen = Set<String>()
        return candidates.compactMap(evidence).sorted {
            if $0.candidate.distance != $1.candidate.distance { return $0.candidate.distance < $1.candidate.distance }
            let samplesA = min($0.candidate.trackA.observationCount, $0.candidate.trackB.observationCount)
            let samplesB = min($1.candidate.trackA.observationCount, $1.candidate.trackB.observationCount)
            if samplesA != samplesB { return samplesA > samplesB }
            let confidenceA = min($0.candidate.trackA.bestConfidence, $0.candidate.trackB.bestConfidence)
            let confidenceB = min($1.candidate.trackA.bestConfidence, $1.candidate.trackB.bestConfidence)
            if confidenceA != confidenceB { return confidenceA > confidenceB }
            return $0.id < $1.id
        }.filter { seen.insert($0.id).inserted }
    }

    public static func calibratedReviewCandidates(
        _ candidates: [ReIDValidationCandidate],
        recommendedDistance: Double?
    ) -> [ReIDValidationCandidate] {
        guard let recommendedDistance, recommendedDistance.isFinite,
              (0...2).contains(recommendedDistance) else { return [] }
        return rankedReviewEvidence(candidates).map(\.candidate).filter { $0.distance <= recommendedDistance }
    }

    private static func category(_ label: String) -> String? {
        if label == "person" { return "person" }
        return ["bicycle", "car", "motorcycle", "bus", "train", "truck", "boat"].contains(label) ? "vehicle" : nil
    }
}