import Foundation
import simd

// MARK: - 1. Same-Camera Tracklet Stitcher

public struct ACTAActiveTracklet: Sendable, Equatable {
    public var trackKey: String
    public var cameraID: String
    public var label: String
    public var normalizedRect: NormalizedRect
    public var velocityXPerSec: Double
    public var velocityYPerSec: Double
    public var lastSeenAt: Date
    public var embedding: [Float]
    public var chromaPrint: ACTAChromaSignature?

    public init(
        trackKey: String,
        cameraID: String,
        label: String,
        normalizedRect: NormalizedRect,
        velocityXPerSec: Double = 0,
        velocityYPerSec: Double = 0,
        lastSeenAt: Date,
        embedding: [Float] = [],
        chromaPrint: ACTAChromaSignature? = nil
    ) {
        self.trackKey = trackKey
        self.cameraID = cameraID
        self.label = label
        self.normalizedRect = normalizedRect
        self.velocityXPerSec = velocityXPerSec
        self.velocityYPerSec = velocityYPerSec
        self.lastSeenAt = lastSeenAt
        self.embedding = embedding
        self.chromaPrint = chromaPrint
    }

    public var centerX: Double { normalizedRect.x + normalizedRect.width * 0.5 }
    public var centerY: Double { normalizedRect.y + normalizedRect.height * 0.5 }
    public var diagonal: Double {
        max(0.01, hypot(normalizedRect.width, normalizedRect.height))
    }
    public var aspectRatio: Double {
        normalizedRect.width / max(0.001, normalizedRect.height)
    }
}

public struct ACTAStitchMatch: Sendable, Equatable {
    public var matchedTrackKey: String
    public var score: Double
    public var reidCosine: Double
    public var predictedDistanceRatio: Double

    public init(
        matchedTrackKey: String,
        score: Double,
        reidCosine: Double,
        predictedDistanceRatio: Double
    ) {
        self.matchedTrackKey = matchedTrackKey
        self.score = score
        self.reidCosine = reidCosine
        self.predictedDistanceRatio = predictedDistanceRatio
    }
}

public struct ACTATrackletStitcher: Sendable {
    public static let maxGapSeconds: TimeInterval = 15.0
    public static let maxPredictedDistanceDiagMultiplier: Double = 1.5
    public static let minReIDCosine: Double = 0.58
    public static let maxAspectRatioDelta: Double = 0.35

    private var lostTrackletsByCamera: [String: [ACTAActiveTracklet]] = [:]

    public init() {}

    public mutating func recordTracklet(_ tracklet: ACTAActiveTracklet) {
        pruneExpired(now: tracklet.lastSeenAt)
        var list = lostTrackletsByCamera[tracklet.cameraID] ?? []
        if let idx = list.firstIndex(where: { $0.trackKey == tracklet.trackKey }) {
            let previous = list[idx]
            let dt = max(0.05, tracklet.lastSeenAt.timeIntervalSince(previous.lastSeenAt))
            var updated = tracklet
            if dt <= 5.0 {
                let vx = (tracklet.centerX - previous.centerX) / dt
                let vy = (tracklet.centerY - previous.centerY) / dt
                updated.velocityXPerSec = 0.6 * vx + 0.4 * previous.velocityXPerSec
                updated.velocityYPerSec = 0.6 * vy + 0.4 * previous.velocityYPerSec
            }
            list[idx] = updated
        } else {
            list.append(tracklet)
        }
        lostTrackletsByCamera[tracklet.cameraID] = list
    }

    public mutating func findStitchCandidate(
        cameraID: String,
        candidateTrackKey: String,
        label: String,
        normalizedRect: NormalizedRect,
        embedding: [Float],
        timestamp: Date
    ) -> ACTAStitchMatch? {
        pruneExpired(now: timestamp)
        guard let candidates = lostTrackletsByCamera[cameraID], !candidates.isEmpty else {
            return nil
        }

        let candCenterX = normalizedRect.x + normalizedRect.width * 0.5
        let candCenterY = normalizedRect.y + normalizedRect.height * 0.5
        let candDiag = max(0.01, hypot(normalizedRect.width, normalizedRect.height))
        let candAspect = normalizedRect.width / max(0.001, normalizedRect.height)

        var bestMatch: ACTAStitchMatch?
        for previous in candidates {
            guard previous.trackKey != candidateTrackKey,
                  previous.label.caseInsensitiveCompare(label) == .orderedSame else {
                continue
            }
            let dt = timestamp.timeIntervalSince(previous.lastSeenAt)
            guard dt >= 0, dt <= Self.maxGapSeconds else { continue }

            let aspectDiff = abs(candAspect - previous.aspectRatio) / max(0.1, max(candAspect, previous.aspectRatio))
            guard aspectDiff <= Self.maxAspectRatioDelta else { continue }

            let predX = previous.centerX + previous.velocityXPerSec * min(dt, 4.0)
            let predY = previous.centerY + previous.velocityYPerSec * min(dt, 4.0)
            let distance = hypot(candCenterX - predX, candCenterY - predY)
            let refDiag = 0.5 * (candDiag + previous.diagonal)
            let distanceRatio = distance / max(0.01, refDiag)
            guard distanceRatio <= Self.maxPredictedDistanceDiagMultiplier else { continue }

            let cosine = ACTAVectorMath.cosineSimilarity(embedding, previous.embedding)
            guard cosine >= Self.minReIDCosine else { continue }

            let proximityScore = max(0.0, 1.0 - (distanceRatio / Self.maxPredictedDistanceDiagMultiplier))
            let timeScore = max(0.0, 1.0 - (dt / Self.maxGapSeconds))
            let combinedScore = 0.65 * cosine + 0.25 * proximityScore + 0.10 * timeScore

            if bestMatch == nil || combinedScore > bestMatch!.score {
                bestMatch = ACTAStitchMatch(
                    matchedTrackKey: previous.trackKey,
                    score: combinedScore,
                    reidCosine: cosine,
                    predictedDistanceRatio: distanceRatio
                )
            }
        }
        return bestMatch
    }

    public mutating func pruneExpired(now: Date) {
        for (cameraID, list) in lostTrackletsByCamera {
            let filtered = list.filter { now.timeIntervalSince($0.lastSeenAt) <= Self.maxGapSeconds }
            if filtered.isEmpty {
                lostTrackletsByCamera.removeValue(forKey: cameraID)
            } else {
                lostTrackletsByCamera[cameraID] = filtered
            }
        }
    }
}

// MARK: - 2. Vector & Cosine Helpers

public enum ACTAVectorMath {
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            let va = a[i]
            let vb = b[i]
            dot += va * vb
            normA += va * va
            normB += vb * vb
        }
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 1e-8 else { return 0 }
        return Double(max(-1.0, min(1.0, dot / denom)))
    }

    public static func l2Normalize(_ vector: [Float]) -> [Float] {
        guard !vector.isEmpty else { return [] }
        var sumSq: Float = 0
        for v in vector { sumSq += v * v }
        let norm = sqrt(sumSq)
        guard norm > 1e-8 else { return vector }
        return vector.map { $0 / norm }
    }
}

// MARK: - 3. Inter-Camera Topology Graph

public struct ACTACameraTransitionLink: Codable, Sendable, Equatable {
    public var fromCameraID: String
    public var toCameraID: String
    public var transitionCount: Int
    public var meanTransitSec: Double
    public var minTransitSec: Double
    public var maxTransitSec: Double
    public var updatedAt: Date

    public init(
        fromCameraID: String,
        toCameraID: String,
        transitionCount: Int = 1,
        meanTransitSec: Double,
        minTransitSec: Double,
        maxTransitSec: Double,
        updatedAt: Date = Date()
    ) {
        self.fromCameraID = fromCameraID
        self.toCameraID = toCameraID
        self.transitionCount = transitionCount
        self.meanTransitSec = meanTransitSec
        self.minTransitSec = minTransitSec
        self.maxTransitSec = maxTransitSec
        self.updatedAt = updatedAt
    }
}

public struct ACTACameraTopology: Sendable {
    private var links: [String: ACTACameraTransitionLink] = [:]

    public init(links: [ACTACameraTransitionLink] = []) {
        for link in links {
            self.links[Self.key(from: link.fromCameraID, to: link.toCameraID)] = link
        }
    }

    private static func key(from: String, to: String) -> String {
        "\(from)->\(to)"
    }

    public var allLinks: [ACTACameraTransitionLink] {
        Array(links.values)
    }

    public mutating func observeTransition(
        from fromCameraID: String,
        to toCameraID: String,
        transitSec: TimeInterval,
        timestamp: Date = Date()
    ) {
        guard fromCameraID != toCameraID, transitSec >= 0.5, transitSec <= 3600 else { return }
        let k = Self.key(from: fromCameraID, to: toCameraID)
        if var existing = links[k] {
            let n = Double(existing.transitionCount)
            let newCount = existing.transitionCount + 1
            existing.meanTransitSec = (existing.meanTransitSec * n + transitSec) / Double(newCount)
            existing.minTransitSec = min(existing.minTransitSec, max(0.5, transitSec * 0.8))
            existing.maxTransitSec = max(existing.maxTransitSec, transitSec * 1.25)
            existing.transitionCount = newCount
            existing.updatedAt = timestamp
            links[k] = existing
        } else {
            links[k] = ACTACameraTransitionLink(
                fromCameraID: fromCameraID,
                toCameraID: toCameraID,
                transitionCount: 1,
                meanTransitSec: transitSec,
                minTransitSec: max(0.5, transitSec * 0.6),
                maxTransitSec: max(transitSec * 1.6, transitSec + 15.0),
                updatedAt: timestamp
            )
        }
    }

    /// Returns a topology plausibility score in [0, 1] (0.5 is neutral when unlearned).
    public func transitionPrior(
        from fromCameraID: String,
        to toCameraID: String,
        deltaSec: TimeInterval
    ) -> Double {
        if fromCameraID == toCameraID {
            if deltaSec <= 15.0 { return 0.90 }
            if deltaSec <= 120.0 { return 0.70 }
            return 0.55
        }
        let k = Self.key(from: fromCameraID, to: toCameraID)
        guard let link = links[k], link.transitionCount >= 2 else {
            return 0.50
        }
        if deltaSec >= link.minTransitSec && deltaSec <= link.maxTransitSec {
            let spread = max(5.0, (link.maxTransitSec - link.minTransitSec) * 0.5)
            let z = abs(deltaSec - link.meanTransitSec) / spread
            return min(1.0, max(0.65, 1.0 - 0.25 * z))
        } else if deltaSec < link.minTransitSec * 0.5 {
            return 0.15
        } else if deltaSec > link.maxTransitSec * 3.0 {
            return 0.30
        }
        return 0.45
    }
}

// MARK: - 4. Gallery Exemplar Bank & Identity Profile

public struct ACTAExemplar: Codable, Sendable, Equatable {
    public var embedding: [Float]
    public var cropQuality: Double
    public var cameraID: String
    public var capturedAt: Date

    public init(
        embedding: [Float],
        cropQuality: Double,
        cameraID: String,
        capturedAt: Date
    ) {
        self.embedding = ACTAVectorMath.l2Normalize(embedding)
        self.cropQuality = cropQuality
        self.cameraID = cameraID
        self.capturedAt = capturedAt
    }
}

public enum ACTAIdentityMatchState: String, Codable, Sendable, Equatable {
    case confirmed
    case suggested
    case single
}

public enum ACTAResolvedSex: String, Codable, Sendable, Equatable {
    case male
    case female
    case unknown
}

public struct ACTAIdentityGalleryProfile: Codable, Sendable, Equatable {
    public static let maxExemplars: Int = 16
    public static let diversityCosineCeiling: Double = 0.92
    public static let ewmaAlpha: Double = 0.15
    public static let minQualityForCentroidUpdate: Double = 0.45

    public var identityID: String
    public var kind: String // "person" or "vehicle"
    public var displayCode: String
    public var displayName: String?
    public var centroid: [Float]
    public var exemplars: [ACTAExemplar]
    public var chromaPrint: ACTAChromaSignature?
    public var hsvHistogram: [Float]
    public var plateNumber: String?
    public var resolvedSex: ACTAResolvedSex
    public var resolvedSexConfidence: Double
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    public var lastCameraID: String
    public var lastNormalizedRect: NormalizedRect?
    public var velocityXPerSec: Double
    public var velocityYPerSec: Double
    public var memberTrackKeys: Set<String>
    public var activeWindowsByCamera: [String: DateInterval]

    public init(
        identityID: String,
        kind: String,
        displayCode: String,
        displayName: String? = nil,
        centroid: [Float] = [],
        exemplars: [ACTAExemplar] = [],
        chromaPrint: ACTAChromaSignature? = nil,
        hsvHistogram: [Float] = [],
        plateNumber: String? = nil,
        resolvedSex: ACTAResolvedSex = .unknown,
        resolvedSexConfidence: Double = 0,
        firstSeenAt: Date = Date(),
        lastSeenAt: Date = Date(),
        lastCameraID: String = "",
        lastNormalizedRect: NormalizedRect? = nil,
        velocityXPerSec: Double = 0,
        velocityYPerSec: Double = 0,
        memberTrackKeys: Set<String> = [],
        activeWindowsByCamera: [String: DateInterval] = [:]
    ) {
        self.identityID = identityID
        self.kind = kind
        self.displayCode = displayCode
        self.displayName = displayName
        self.centroid = ACTAVectorMath.l2Normalize(centroid)
        self.exemplars = exemplars
        self.chromaPrint = chromaPrint
        self.hsvHistogram = hsvHistogram
        self.plateNumber = plateNumber
        self.resolvedSex = resolvedSex
        self.resolvedSexConfidence = resolvedSexConfidence
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.lastCameraID = lastCameraID
        self.lastNormalizedRect = lastNormalizedRect
        self.velocityXPerSec = velocityXPerSec
        self.velocityYPerSec = velocityYPerSec
        self.memberTrackKeys = memberTrackKeys
        self.activeWindowsByCamera = activeWindowsByCamera
    }

    public mutating func ingestObservation(
        trackKey: String,
        cameraID: String,
        embedding: [Float],
        cropQuality: Double,
        chromaPrint: ACTAChromaSignature?,
        hsvHistogram: [Float]?,
        normalizedRect: NormalizedRect?,
        observedAt: Date
    ) {
        memberTrackKeys.insert(trackKey)
        if observedAt < firstSeenAt { firstSeenAt = observedAt }
        if observedAt >= lastSeenAt {
            if let prevRect = lastNormalizedRect, let newRect = normalizedRect, lastCameraID == cameraID {
                let dt = observedAt.timeIntervalSince(lastSeenAt)
                if dt > 0.05 && dt <= 10.0 {
                    let prevCx = prevRect.x + prevRect.width * 0.5
                    let prevCy = prevRect.y + prevRect.height * 0.5
                    let newCx = newRect.x + newRect.width * 0.5
                    let newCy = newRect.y + newRect.height * 0.5
                    velocityXPerSec = (newCx - prevCx) / dt
                    velocityYPerSec = (newCy - prevCy) / dt
                }
            }
            lastSeenAt = observedAt
            lastCameraID = cameraID
            if let normalizedRect {
                lastNormalizedRect = normalizedRect
            }
        }

        if let existingWindow = activeWindowsByCamera[cameraID] {
            let start = min(existingWindow.start, observedAt)
            let end = max(existingWindow.end, observedAt)
            activeWindowsByCamera[cameraID] = DateInterval(start: start, end: end)
        } else {
            activeWindowsByCamera[cameraID] = DateInterval(start: observedAt, duration: 0.5)
        }

        if let chromaPrint {
            if self.chromaPrint == nil || cropQuality >= Self.minQualityForCentroidUpdate {
                self.chromaPrint = chromaPrint
            }
        }
        if let hsvHistogram, !hsvHistogram.isEmpty {
            if self.hsvHistogram.isEmpty || cropQuality >= Self.minQualityForCentroidUpdate {
                self.hsvHistogram = hsvHistogram
            }
        }

        let normEmb = ACTAVectorMath.l2Normalize(embedding)
        guard !normEmb.isEmpty else { return }

        if centroid.isEmpty {
            centroid = normEmb
        } else if cropQuality >= Self.minQualityForCentroidUpdate && centroid.count == normEmb.count {
            let alpha = Float(Self.ewmaAlpha)
            var blended = [Float](repeating: 0, count: centroid.count)
            for i in 0..<centroid.count {
                blended[i] = (1.0 - alpha) * centroid[i] + alpha * normEmb[i]
            }
            centroid = ACTAVectorMath.l2Normalize(blended)
        }

        let maxSimToExisting = exemplars.map {
            ACTAVectorMath.cosineSimilarity(normEmb, $0.embedding)
        }.max() ?? 0.0

        let candidateExemplar = ACTAExemplar(
            embedding: normEmb,
            cropQuality: cropQuality,
            cameraID: cameraID,
            capturedAt: observedAt
        )

        if exemplars.isEmpty {
            exemplars.append(candidateExemplar)
        } else if maxSimToExisting < Self.diversityCosineCeiling {
            if exemplars.count < Self.maxExemplars {
                exemplars.append(candidateExemplar)
            } else if let worstIdx = exemplars.enumerated().min(by: { $0.element.cropQuality < $1.element.cropQuality })?.offset,
                      cropQuality > exemplars[worstIdx].cropQuality {
                exemplars[worstIdx] = candidateExemplar
            }
        } else if let nearestIdx = exemplars.enumerated().max(by: {
            ACTAVectorMath.cosineSimilarity(normEmb, $0.element.embedding) <
            ACTAVectorMath.cosineSimilarity(normEmb, $1.element.embedding)
        })?.offset, cropQuality > exemplars[nearestIdx].cropQuality {
            exemplars[nearestIdx] = candidateExemplar
        }
    }
}

// MARK: - 5. Multi-Cue Identity Scorer & Resolver

public struct ACTAMultiCueCandidateObservation: Sendable {
    public var trackKey: String
    public var cameraID: String
    public var kind: String // "person" or "vehicle"
    public var embedding: [Float]
    public var cropQuality: Double
    public var chromaPrint: ACTAChromaSignature?
    public var hsvHistogram: [Float]
    public var normalizedRect: NormalizedRect?
    public var velocityXPerSec: Double
    public var velocityYPerSec: Double
    public var plateNumber: String?
    public var resolvedSex: ACTAResolvedSex
    public var observedAt: Date

    public init(
        trackKey: String,
        cameraID: String,
        kind: String,
        embedding: [Float],
        cropQuality: Double,
        chromaPrint: ACTAChromaSignature? = nil,
        hsvHistogram: [Float] = [],
        normalizedRect: NormalizedRect? = nil,
        velocityXPerSec: Double = 0,
        velocityYPerSec: Double = 0,
        plateNumber: String? = nil,
        resolvedSex: ACTAResolvedSex = .unknown,
        observedAt: Date = Date()
    ) {
        self.trackKey = trackKey
        self.cameraID = cameraID
        self.kind = kind
        self.embedding = ACTAVectorMath.l2Normalize(embedding)
        self.cropQuality = cropQuality
        self.chromaPrint = chromaPrint
        self.hsvHistogram = hsvHistogram
        self.normalizedRect = normalizedRect
        self.velocityXPerSec = velocityXPerSec
        self.velocityYPerSec = velocityYPerSec
        self.plateNumber = plateNumber
        self.resolvedSex = resolvedSex
        self.observedAt = observedAt
    }
}

public struct ACTAIdentityScoreBreakdown: Sendable, Equatable {
    public var identityID: String
    public var reidScore: Double
    public var maxExemplarCosine: Double
    public var centroidCosine: Double
    public var agreementFraction: Double
    public var timeScore: Double
    public var topoScore: Double
    public var clothingScore: Double
    public var directionScore: Double
    public var sizeScore: Double
    public var rawPrior: Double
    public var priorMultiplier: Double
    public var chromaSimilarity: Double?
    public var finalScore: Double
    public var vetoReason: String?

    public var isVetoed: Bool { vetoReason != nil }
}

public struct ACTAIdentityResolutionDecision: Sendable, Equatable {
    public var identityID: String
    public var state: ACTAIdentityMatchState
    public var score: Double
    public var secondBestScore: Double
    public var chromaRescued: Bool
    public var chromaGuarded: Bool
    public var echoSuppressed: Bool
    public var createdNewIdentity: Bool
    public var breakdown: ACTAIdentityScoreBreakdown?

    public init(
        identityID: String,
        state: ACTAIdentityMatchState,
        score: Double,
        secondBestScore: Double = 0,
        chromaRescued: Bool = false,
        chromaGuarded: Bool = false,
        echoSuppressed: Bool = false,
        createdNewIdentity: Bool = false,
        breakdown: ACTAIdentityScoreBreakdown? = nil
    ) {
        self.identityID = identityID
        self.state = state
        self.score = score
        self.secondBestScore = secondBestScore
        self.chromaRescued = chromaRescued
        self.chromaGuarded = chromaGuarded
        self.echoSuppressed = echoSuppressed
        self.createdNewIdentity = createdNewIdentity
        self.breakdown = breakdown
    }
}

public struct ACTAMultiCueScorer: Sendable {
    // Cue Weights
    public static let wReid: Double = 0.45
    public static let wTime: Double = 0.20
    public static let wTopo: Double = 0.15
    public static let wCloth: Double = 0.10
    public static let wDir: Double = 0.05
    public static let wSize: Double = 0.05

    // Decision Thresholds
    public static let tAcceptPerson: Double = 0.78
    public static let tAcceptVehicle: Double = 0.75
    public static let tSuggest: Double = 0.62
    public static let tMargin: Double = 0.03
    public static let clusterCosineThreshold: Double = 0.85

    // Time decay
    public static let tauSameCamSec: Double = 60.0
    public static let tauCrossCamSec: Double = 300.0
    public static let simultaneousOverlapSlopSec: Double = 1.0

    // Chroma Rescue & Guard
    public static let chromaRescueMinScore: Double = 0.68
    public static let chromaRescueMinSim: Double = 0.90
    public static let chromaGuardMaxSim: Double = 0.55

    // 30s Echo Suppression
    public static let echoWindowSec: TimeInterval = 30.0
    public static let echoMinCosine: Double = 0.68

    public init() {}

    /// Checks whether the candidate observation overlaps on a different camera within 1.0s.
    public static func isImpossibleSimultaneous(
        observation: ACTAMultiCueCandidateObservation,
        gallery: ACTAIdentityGalleryProfile
    ) -> Bool {
        for (camID, window) in gallery.activeWindowsByCamera where camID != observation.cameraID {
            let expandedStart = window.start.addingTimeInterval(-simultaneousOverlapSlopSec)
            let expandedEnd = window.end.addingTimeInterval(simultaneousOverlapSlopSec)
            if observation.observedAt >= expandedStart && observation.observedAt <= expandedEnd {
                return true
            }
        }
        return false
    }

    public static func scoreCandidate(
        observation: ACTAMultiCueCandidateObservation,
        gallery: ACTAIdentityGalleryProfile,
        topology: ACTACameraTopology,
        cannotLinkIdentityIDs: Set<String> = []
    ) -> ACTAIdentityScoreBreakdown {
        if cannotLinkIdentityIDs.contains(gallery.identityID) {
            return ACTAIdentityScoreBreakdown(
                identityID: gallery.identityID,
                reidScore: 0, maxExemplarCosine: 0, centroidCosine: 0, agreementFraction: 0,
                timeScore: 0, topoScore: 0, clothingScore: 0, directionScore: 0, sizeScore: 0,
                rawPrior: 0, priorMultiplier: 1, chromaSimilarity: nil, finalScore: 0,
                vetoReason: "cannot_link"
            )
        }

        if gallery.kind.caseInsensitiveCompare(observation.kind) != .orderedSame {
            return ACTAIdentityScoreBreakdown(
                identityID: gallery.identityID,
                reidScore: 0, maxExemplarCosine: 0, centroidCosine: 0, agreementFraction: 0,
                timeScore: 0, topoScore: 0, clothingScore: 0, directionScore: 0, sizeScore: 0,
                rawPrior: 0, priorMultiplier: 1, chromaSimilarity: nil, finalScore: 0,
                vetoReason: "kind_mismatch"
            )
        }

        if observation.resolvedSex != .unknown &&
            gallery.resolvedSex != .unknown &&
            observation.resolvedSex != gallery.resolvedSex &&
            gallery.resolvedSexConfidence >= 0.55 {
            return ACTAIdentityScoreBreakdown(
                identityID: gallery.identityID,
                reidScore: 0, maxExemplarCosine: 0, centroidCosine: 0, agreementFraction: 0,
                timeScore: 0, topoScore: 0, clothingScore: 0, directionScore: 0, sizeScore: 0,
                rawPrior: 0, priorMultiplier: 1, chromaSimilarity: nil, finalScore: 0,
                vetoReason: "sex_conflict"
            )
        }

        if isImpossibleSimultaneous(observation: observation, gallery: gallery) {
            return ACTAIdentityScoreBreakdown(
                identityID: gallery.identityID,
                reidScore: 0, maxExemplarCosine: 0, centroidCosine: 0, agreementFraction: 0,
                timeScore: 0, topoScore: 0, clothingScore: 0, directionScore: 0, sizeScore: 0,
                rawPrior: 0, priorMultiplier: 1, chromaSimilarity: nil, finalScore: 0,
                vetoReason: "impossible_simultaneous"
            )
        }

        // Exact license plate match shortcut for vehicles
        if let obsPlate = observation.plateNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
           let galPlate = gallery.plateNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
           obsPlate.count >= 5, obsPlate == galPlate {
            return ACTAIdentityScoreBreakdown(
                identityID: gallery.identityID,
                reidScore: 0.99, maxExemplarCosine: 0.99, centroidCosine: 0.99, agreementFraction: 1.0,
                timeScore: 1.0, topoScore: 1.0, clothingScore: 1.0, directionScore: 1.0, sizeScore: 1.0,
                rawPrior: 1.0, priorMultiplier: 1.0, chromaSimilarity: 1.0, finalScore: 0.99,
                vetoReason: nil
            )
        }

        // 1. ReID Cosine against Exemplar Bank + Centroid
        let exemplarCosines: [Double] = gallery.exemplars.map {
            ACTAVectorMath.cosineSimilarity(observation.embedding, $0.embedding)
        }
        let centroidCos = gallery.centroid.isEmpty
            ? (exemplarCosines.max() ?? 0.0)
            : ACTAVectorMath.cosineSimilarity(observation.embedding, gallery.centroid)
        let maxExemplarCos = exemplarCosines.max() ?? centroidCos
        let sReid = 0.70 * maxExemplarCos + 0.30 * centroidCos

        let agreeingCount = exemplarCosines.filter { $0 >= tSuggest }.count
        let agreementFraction = exemplarCosines.isEmpty
            ? (centroidCos >= tSuggest ? 1.0 : 0.0)
            : Double(agreeingCount) / Double(exemplarCosines.count)

        // 2. Time Decay Cue
        let deltaSec = max(0.0, abs(observation.observedAt.timeIntervalSince(gallery.lastSeenAt)))
        let tau = (observation.cameraID == gallery.lastCameraID) ? tauSameCamSec : tauCrossCamSec
        let sTime = exp(-deltaSec / tau)

        // 3. Topology Cue
        let sTopo = topology.transitionPrior(
            from: gallery.lastCameraID,
            to: observation.cameraID,
            deltaSec: deltaSec
        )

        // 4. Clothing / Chroma / HSV Cue
        var chromaSim: Double?
        if let obsChroma = observation.chromaPrint, let galChroma = gallery.chromaPrint {
            chromaSim = obsChroma.cosineSimilarity(to: galChroma)
        }
        let hsvSim: Double? = (!observation.hsvHistogram.isEmpty && !gallery.hsvHistogram.isEmpty)
            ? ACTAChromaPrint.hsvCosineSimilarity(observation.hsvHistogram, gallery.hsvHistogram)
            : nil
        let sCloth: Double
        if let chromaSim, let hsvSim {
            sCloth = 0.75 * chromaSim + 0.25 * hsvSim
        } else if let chromaSim {
            sCloth = chromaSim
        } else if let hsvSim {
            sCloth = hsvSim
        } else {
            sCloth = 0.50
        }

        // 5. Direction Cue
        let sDir: Double
        let obsSpeed = hypot(observation.velocityXPerSec, observation.velocityYPerSec)
        let galSpeed = hypot(gallery.velocityXPerSec, gallery.velocityYPerSec)
        if obsSpeed > 0.01 && galSpeed > 0.01 {
            let dot = (observation.velocityXPerSec * gallery.velocityXPerSec +
                       observation.velocityYPerSec * gallery.velocityYPerSec) / (obsSpeed * galSpeed)
            sDir = 0.5 * (max(-1.0, min(1.0, dot)) + 1.0)
        } else {
            sDir = 0.50
        }

        // 6. Bounding Box Size / Aspect Consistency Cue
        let sSize: Double
        if let obsRect = observation.normalizedRect, let galRect = gallery.lastNormalizedRect {
            let obsAsp = obsRect.width / max(0.001, obsRect.height)
            let galAsp = galRect.width / max(0.001, galRect.height)
            let ratioDiff = abs(obsAsp - galAsp) / max(0.1, max(obsAsp, galAsp))
            sSize = max(0.0, 1.0 - min(1.0, ratioDiff))
        } else {
            sSize = 0.50
        }

        // Multiplicative Prior Formula:
        // rawPrior = (wTime*S_time + wTopo*S_topo + wCloth*S_cloth + wDir*S_dir + wSize*S_size) / priorWeightSum
        // priorMultiplier = exp((rawPrior - 0.5) * 0.45)
        // S_final = clamp(0, 1, S_reid * priorMultiplier)
        let priorWeightSum = wTime + wTopo + wCloth + wDir + wSize
        let rawPrior = (wTime * sTime + wTopo * sTopo + wCloth * sCloth + wDir * sDir + wSize * sSize) / priorWeightSum
        let priorMultiplier = exp((rawPrior - 0.5) * 0.45)
        let sFinal = max(0.0, min(1.0, sReid * priorMultiplier))

        return ACTAIdentityScoreBreakdown(
            identityID: gallery.identityID,
            reidScore: sReid,
            maxExemplarCosine: maxExemplarCos,
            centroidCosine: centroidCos,
            agreementFraction: agreementFraction,
            timeScore: sTime,
            topoScore: sTopo,
            clothingScore: sCloth,
            directionScore: sDir,
            sizeScore: sSize,
            rawPrior: rawPrior,
            priorMultiplier: priorMultiplier,
            chromaSimilarity: chromaSim,
            finalScore: sFinal,
            vetoReason: nil
        )
    }
}

public final class ACTAIdentityResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var galleries: [String: ACTAIdentityGalleryProfile] = [:]
    private var cannotLinkPairs: Set<String> = []
    private var topology: ACTACameraTopology
    private var nextPersonSequence: Int = 1
    private var nextVehicleSequence: Int = 1

    public init(
        galleries: [ACTAIdentityGalleryProfile] = [],
        topology: ACTACameraTopology = ACTACameraTopology()
    ) {
        self.topology = topology
        for g in galleries {
            self.galleries[g.identityID] = g
        }
    }

    private static func pairKey(_ a: String, _ b: String) -> String {
        a < b ? "\(a)|\(b)" : "\(b)|\(a)"
    }

    public func recordCannotLink(_ idA: String, _ idB: String) {
        guard idA != idB else { return }
        lock.lock()
        defer { lock.unlock() }
        cannotLinkPairs.insert(Self.pairKey(idA, idB))
    }

    public func isCannotLink(_ idA: String, _ idB: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cannotLinkPairs.contains(Self.pairKey(idA, idB))
    }

    public func allGalleries() -> [ACTAIdentityGalleryProfile] {
        lock.lock()
        defer { lock.unlock() }
        return Array(galleries.values)
    }

    public func gallery(for identityID: String) -> ACTAIdentityGalleryProfile? {
        lock.lock()
        defer { lock.unlock() }
        return galleries[identityID]
    }

    public func upsertGallery(_ profile: ACTAIdentityGalleryProfile) {
        lock.lock()
        defer { lock.unlock() }
        galleries[profile.identityID] = profile
    }

    public func currentTopology() -> ACTACameraTopology {
        lock.lock()
        defer { lock.unlock() }
        return topology
    }

    public func replaceTopology(_ newTopology: ACTACameraTopology) {
        lock.lock()
        defer { lock.unlock() }
        topology = newTopology
    }

    public func removeGallery(identityID: String) {
        lock.lock()
        defer { lock.unlock() }
        galleries.removeValue(forKey: identityID)
    }

    public func allCannotLinkPairs() -> [(String, String)] {
        lock.lock()
        defer { lock.unlock() }
        return cannotLinkPairs.compactMap { key in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return (parts[0], parts[1])
        }
    }

    public func resolve(
        observation: ACTAMultiCueCandidateObservation,
        forbiddenIdentityIDs: Set<String> = []
    ) -> ACTAIdentityResolutionDecision {
        lock.lock()
        defer { lock.unlock() }

        let isVehicle = observation.kind.caseInsensitiveCompare("vehicle") == .orderedSame ||
            observation.kind.caseInsensitiveCompare("car") == .orderedSame ||
            observation.kind.caseInsensitiveCompare("truck") == .orderedSame
        let tAccept = isVehicle ? ACTAMultiCueScorer.tAcceptVehicle : ACTAMultiCueScorer.tAcceptPerson

        var breakdowns: [ACTAIdentityScoreBreakdown] = []
        for profile in galleries.values {
            let breakdown = ACTAMultiCueScorer.scoreCandidate(
                observation: observation,
                gallery: profile,
                topology: topology,
                cannotLinkIdentityIDs: forbiddenIdentityIDs
            )
            if !breakdown.isVetoed {
                breakdowns.append(breakdown)
            }
        }
        breakdowns.sort { $0.finalScore > $1.finalScore }

        if let best = breakdowns.first, let bestProfile = galleries[best.identityID] {
            let second = breakdowns.dropFirst().first
            let secondScore = second?.finalScore ?? 0.0

            // Cluster-aware margin: if best and second-best belong to the same visual cluster
            // (cosine(best.centroid, second.centroid) >= 0.85), ignore the margin requirement.
            var sameVisualCluster = false
            if let second, let secondProfile = galleries[second.identityID],
               !bestProfile.centroid.isEmpty, !secondProfile.centroid.isEmpty {
                let clusterCos = ACTAVectorMath.cosineSimilarity(bestProfile.centroid, secondProfile.centroid)
                sameVisualCluster = clusterCos >= ACTAMultiCueScorer.clusterCosineThreshold
            }

            let marginSatisfied = sameVisualCluster || ((best.finalScore - secondScore) >= ACTAMultiCueScorer.tMargin)
            let kOfNSatisfied = best.agreementFraction >= 0.50 || bestProfile.exemplars.count <= 1

            var state: ACTAIdentityMatchState = .single
            var chromaRescued = false
            var chromaGuarded = false
            var echoSuppressed = false

            if best.finalScore >= tAccept && marginSatisfied && kOfNSatisfied {
                // Check Chroma Guard: if S_final >= tAccept but chromaSim < 0.55 -> downgrade to .suggested
                if let chromaSim = best.chromaSimilarity, chromaSim < ACTAMultiCueScorer.chromaGuardMaxSim {
                    state = .suggested
                    chromaGuarded = true
                } else {
                    state = .confirmed
                }
            } else if best.finalScore >= ACTAMultiCueScorer.chromaRescueMinScore,
                      best.finalScore < tAccept,
                      let chromaSim = best.chromaSimilarity,
                      chromaSim >= ACTAMultiCueScorer.chromaRescueMinSim,
                      marginSatisfied {
                // Chroma Rescue: S_final in [0.68, tAccept) and chromaSim >= 0.90 -> rescue to .confirmed
                state = .confirmed
                chromaRescued = true
            } else if best.finalScore >= ACTAMultiCueScorer.tSuggest {
                state = .suggested
            } else {
                // 30s Echo Suppression: if same or adjacent camera within 30s has cosine >= 0.68,
                // attach instead of spawning a duplicate ID.
                let dt = abs(observation.observedAt.timeIntervalSince(bestProfile.lastSeenAt))
                if dt <= ACTAMultiCueScorer.echoWindowSec && best.maxExemplarCosine >= ACTAMultiCueScorer.echoMinCosine {
                    state = .suggested
                    echoSuppressed = true
                }
            }

            if state == .confirmed || state == .suggested {
                var updated = bestProfile
                let previousCam = updated.lastCameraID
                let previousTime = updated.lastSeenAt
                updated.ingestObservation(
                    trackKey: observation.trackKey,
                    cameraID: observation.cameraID,
                    embedding: observation.embedding,
                    cropQuality: observation.cropQuality,
                    chromaPrint: observation.chromaPrint,
                    hsvHistogram: observation.hsvHistogram,
                    normalizedRect: observation.normalizedRect,
                    observedAt: observation.observedAt
                )
                if let plate = observation.plateNumber, !plate.isEmpty {
                    updated.plateNumber = plate
                }
                if previousCam != observation.cameraID && !previousCam.isEmpty {
                    let transit = abs(observation.observedAt.timeIntervalSince(previousTime))
                    topology.observeTransition(
                        from: previousCam,
                        to: observation.cameraID,
                        transitSec: transit,
                        timestamp: observation.observedAt
                    )
                }
                galleries[updated.identityID] = updated

                return ACTAIdentityResolutionDecision(
                    identityID: updated.identityID,
                    state: state,
                    score: best.finalScore,
                    secondBestScore: secondScore,
                    chromaRescued: chromaRescued,
                    chromaGuarded: chromaGuarded,
                    echoSuppressed: echoSuppressed,
                    createdNewIdentity: false,
                    breakdown: best
                )
            }
        }

        // Spawn a new identity gallery profile
        let newID = UUID().uuidString
        let displayCode: String
        if isVehicle {
            displayCode = String(format: "V-%03d", nextVehicleSequence)
            nextVehicleSequence += 1
        } else {
            displayCode = String(format: "P-%03d", nextPersonSequence)
            nextPersonSequence += 1
        }

        var newProfile = ACTAIdentityGalleryProfile(
            identityID: newID,
            kind: isVehicle ? "vehicle" : "person",
            displayCode: displayCode,
            chromaPrint: observation.chromaPrint,
            hsvHistogram: observation.hsvHistogram,
            plateNumber: observation.plateNumber,
            resolvedSex: observation.resolvedSex,
            resolvedSexConfidence: observation.resolvedSex == .unknown ? 0.0 : 0.65,
            firstSeenAt: observation.observedAt,
            lastSeenAt: observation.observedAt,
            lastCameraID: observation.cameraID,
            lastNormalizedRect: observation.normalizedRect,
            velocityXPerSec: observation.velocityXPerSec,
            velocityYPerSec: observation.velocityYPerSec
        )
        newProfile.ingestObservation(
            trackKey: observation.trackKey,
            cameraID: observation.cameraID,
            embedding: observation.embedding,
            cropQuality: observation.cropQuality,
            chromaPrint: observation.chromaPrint,
            hsvHistogram: observation.hsvHistogram,
            normalizedRect: observation.normalizedRect,
            observedAt: observation.observedAt
        )
        galleries[newID] = newProfile

        return ACTAIdentityResolutionDecision(
            identityID: newID,
            state: .single,
            score: 1.0,
            secondBestScore: breakdowns.first?.finalScore ?? 0,
            chromaRescued: false,
            chromaGuarded: false,
            echoSuppressed: false,
            createdNewIdentity: true,
            breakdown: nil
        )
    }
}

// MARK: - 6. Weighted Sex Resolution & Impurity Splitter

public struct ACTASexObservationInput: Sendable, Equatable {
    public var trackKey: String
    public var apparentSex: String?
    public var descriptionText: String?
    public var facialHair: String?
    public var lowerClothingType: String?
    public var cropQuality: Double

    public init(
        trackKey: String,
        apparentSex: String? = nil,
        descriptionText: String? = nil,
        facialHair: String? = nil,
        lowerClothingType: String? = nil,
        cropQuality: Double = 0.70
    ) {
        self.trackKey = trackKey
        self.apparentSex = apparentSex
        self.descriptionText = descriptionText
        self.facialHair = facialHair
        self.lowerClothingType = lowerClothingType
        self.cropQuality = cropQuality
    }
}

public struct ACTASexResolutionResult: Sendable, Equatable {
    public var sex: ACTAResolvedSex
    public var confidence: Double
    public var maleWeight: Double
    public var femaleWeight: Double

    public init(
        sex: ACTAResolvedSex,
        confidence: Double,
        maleWeight: Double,
        femaleWeight: Double
    ) {
        self.sex = sex
        self.confidence = confidence
        self.maleWeight = maleWeight
        self.femaleWeight = femaleWeight
    }
}

public enum ACTASexResolver {
    private static let maleNouns: [String] = [
        "man", "male", "boy", "gentleman", "guy",
        "мужчина", "парень", "мальчик", "мужской",
        "גבר", "בחור", "ילד"
    ]

    private static let femaleNouns: [String] = [
        "woman", "female", "girl", "lady",
        "женщина", "девушка", "девочка", "женский",
        "אישה", "בחורה", "ילדה"
    ]

    public static func resolve(observations: [ACTASexObservationInput]) -> ACTASexResolutionResult {
        var maleDirect: Double = 0
        var femaleDirect: Double = 0
        var maleSecondary: Double = 0
        var femaleSecondary: Double = 0

        for obs in observations {
            let q = max(0.35, min(1.0, obs.cropQuality))

            // 1. Direct structured field `apparent_sex` (weight 1.0 * q)
            if let direct = obs.apparentSex?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                if direct == "male" || direct == "m" || direct == "мужской" || direct == "זכר" {
                    maleDirect += 1.0 * q
                } else if direct == "female" || direct == "f" || direct == "женский" || direct == "נקבה" {
                    femaleDirect += 1.0 * q
                }
            }

            // 2. Gendered nouns in free text (weight 0.35 * q)
            if let text = obs.descriptionText?.lowercased(), !text.isEmpty {
                let hasMale = maleNouns.contains { text.contains($0) }
                let hasFemale = femaleNouns.contains { text.contains($0) }
                if hasMale && !hasFemale {
                    maleDirect += 0.35 * q
                } else if hasFemale && !hasMale {
                    femaleDirect += 0.35 * q
                }
            }

            // 3. Secondary cues (beard/mustache -> +0.25*q male; skirt/dress -> +0.25*q female)
            // Never decide sex alone when direct signals are absent.
            if let hair = obs.facialHair?.lowercased(),
               hair.contains("beard") || hair.contains("mustache") || hair.contains("бород") || hair.contains("ус") || hair.contains("זקן") {
                maleSecondary += 0.25 * q
            }
            if let lower = obs.lowerClothingType?.lowercased(),
               lower.contains("skirt") || lower.contains("dress") || lower.contains("юбк") || lower.contains("плать") || lower.contains("חצאית") || lower.contains("שמלה") {
                femaleSecondary += 0.25 * q
            }
        }

        // Secondary signals can only reinforce existing direct signals
        let totalMale = maleDirect > 0 ? (maleDirect + maleSecondary) : 0
        let totalFemale = femaleDirect > 0 ? (femaleDirect + femaleSecondary) : 0

        let lead = max(totalMale, totalFemale)
        let other = min(totalMale, totalFemale)
        let winningSex: ACTAResolvedSex = totalMale >= totalFemale ? .male : .female

        // Uncontradicted direct signal >= 0.50 OR (lead >= 0.40 AND lead / max(0.01, other) >= 1.6)
        let uncontradictedDirect = (other == 0 && max(maleDirect, femaleDirect) >= 0.50)
        let ratioDominant = (lead >= 0.40 && (lead / max(0.01, other)) >= 1.6)

        guard uncontradictedDirect || ratioDominant else {
            return ACTASexResolutionResult(
                sex: .unknown,
                confidence: 0,
                maleWeight: totalMale,
                femaleWeight: totalFemale
            )
        }

        let total = max(0.01, totalMale + totalFemale)
        let dominanceRatio = lead / total
        let confidence = min(0.99, dominanceRatio * min(1.0, lead / 0.80))
        return ACTASexResolutionResult(
            sex: winningSex,
            confidence: confidence,
            maleWeight: totalMale,
            femaleWeight: totalFemale
        )
    }
}

public struct ACTAImpuritySplitAction: Sendable, Equatable {
    public var originalIdentityID: String
    public var newIdentityID: String
    public var majoritySex: ACTAResolvedSex
    public var minoritySex: ACTAResolvedSex
    public var movedTrackKeys: [String]

    public init(
        originalIdentityID: String,
        newIdentityID: String,
        majoritySex: ACTAResolvedSex,
        minoritySex: ACTAResolvedSex,
        movedTrackKeys: [String]
    ) {
        self.originalIdentityID = originalIdentityID
        self.newIdentityID = newIdentityID
        self.majoritySex = majoritySex
        self.minoritySex = minoritySex
        self.movedTrackKeys = movedTrackKeys
    }
}

public enum ACTAIdentityPuritySplitter {
    public static let minConfidenceForSplit: Double = 0.55

    /// Inspects a person identity's member tracks and splits out conflicting sex tracks into a new identity.
    public static func evaluateIdentity(
        identityID: String,
        trackObservations: [String: [ACTASexObservationInput]]
    ) -> ACTAImpuritySplitAction? {
        var maleTracks: [(trackKey: String, confidence: Double)] = []
        var femaleTracks: [(trackKey: String, confidence: Double)] = []

        for (trackKey, obsList) in trackObservations {
            let res = ACTASexResolver.resolve(observations: obsList)
            guard res.confidence >= minConfidenceForSplit else { continue }
            switch res.sex {
            case .male:
                maleTracks.append((trackKey, res.confidence))
            case .female:
                femaleTracks.append((trackKey, res.confidence))
            case .unknown:
                break
            }
        }

        guard !maleTracks.isEmpty && !femaleTracks.isEmpty else {
            return nil
        }

        let maleWeight = maleTracks.reduce(0.0) { $0 + $1.confidence }
        let femaleWeight = femaleTracks.reduce(0.0) { $0 + $1.confidence }

        let majoritySex: ACTAResolvedSex = maleWeight >= femaleWeight ? .male : .female
        let minoritySex: ACTAResolvedSex = majoritySex == .male ? .female : .male
        let minorityTrackKeys = (minoritySex == .male ? maleTracks : femaleTracks)
            .map(\.trackKey)
            .sorted()

        return ACTAImpuritySplitAction(
            originalIdentityID: identityID,
            newIdentityID: UUID().uuidString,
            majoritySex: majoritySex,
            minoritySex: minoritySex,
            movedTrackKeys: minorityTrackKeys
        )
    }
}

// MARK: - 7. 4-Layer Continuity Deduplication Sweeper

public struct ACTAFacetSummary: Codable, Sendable, Equatable {
    public var identityID: String
    public var kind: String // "person" or "vehicle"
    public var resolvedSex: ACTAResolvedSex
    public var ageGroup: String?
    public var build: String?
    public var hairStyleOrColor: String?
    public var upperClothingType: String?
    public var upperColor: String?
    public var lowerClothingType: String?
    public var lowerColor: String?
    public var accessories: [String]
    public var vehicleType: String?
    public var vehicleColor: String?
    public var makeModel: String?
    public var plateNumber: String?
    public var summaryText: String?

    public init(
        identityID: String,
        kind: String,
        resolvedSex: ACTAResolvedSex = .unknown,
        ageGroup: String? = nil,
        build: String? = nil,
        hairStyleOrColor: String? = nil,
        upperClothingType: String? = nil,
        upperColor: String? = nil,
        lowerClothingType: String? = nil,
        lowerColor: String? = nil,
        accessories: [String] = [],
        vehicleType: String? = nil,
        vehicleColor: String? = nil,
        makeModel: String? = nil,
        plateNumber: String? = nil,
        summaryText: String? = nil
    ) {
        self.identityID = identityID
        self.kind = kind
        self.resolvedSex = resolvedSex
        self.ageGroup = ageGroup
        self.build = build
        self.hairStyleOrColor = hairStyleOrColor
        self.upperClothingType = upperClothingType
        self.upperColor = upperColor
        self.lowerClothingType = lowerClothingType
        self.lowerColor = lowerColor
        self.accessories = accessories
        self.vehicleType = vehicleType
        self.vehicleColor = vehicleColor
        self.makeModel = makeModel
        self.plateNumber = plateNumber
        self.summaryText = summaryText
    }
}

public enum ACTADedupLayer: String, Codable, Sendable, Equatable {
    case operatorReview = "operator_review"
    case layerALocalSignals = "layer_a_local"
    case layerBLocalFacets = "layer_b_facets"
    case layerCTextLLM = "layer_c_text"
    case layerDCollageVision = "layer_d_collage"
}

public typealias ACTASweeperPairDecision = ACTADedupDecision

public struct ACTADedupDecision: Codable, Sendable, Equatable {
    public var idA: String
    public var idB: String
    public var layer: ACTADedupLayer
    public var shouldMerge: Bool
    public var recordCannotLink: Bool
    public var confidence: Double
    public var reason: String

    public init(
        idA: String,
        idB: String,
        layer: ACTADedupLayer,
        shouldMerge: Bool,
        recordCannotLink: Bool = false,
        confidence: Double,
        reason: String
    ) {
        self.idA = idA
        self.idB = idB
        self.layer = layer
        self.shouldMerge = shouldMerge
        self.recordCannotLink = recordCannotLink
        self.confidence = confidence
        self.reason = reason
    }
}

public struct ACTASweepEvaluationBatch: Sendable {
    public var autoMerges: [ACTADedupDecision]
    public var newCannotLinks: [ACTADedupDecision]
    public var layerCTextPairs: [(ACTAIdentityGalleryProfile, ACTAFacetSummary?, ACTAIdentityGalleryProfile, ACTAFacetSummary?)]
    public var layerDCollageCandidates: [ACTAIdentityGalleryProfile]

    public init(
        autoMerges: [ACTADedupDecision] = [],
        newCannotLinks: [ACTADedupDecision] = [],
        layerCTextPairs: [(ACTAIdentityGalleryProfile, ACTAFacetSummary?, ACTAIdentityGalleryProfile, ACTAFacetSummary?)] = [],
        layerDCollageCandidates: [ACTAIdentityGalleryProfile] = []
    ) {
        self.autoMerges = autoMerges
        self.newCannotLinks = newCannotLinks
        self.layerCTextPairs = layerCTextPairs
        self.layerDCollageCandidates = layerDCollageCandidates
    }
}

public enum ACTAContinuitySweeper {
    /// Runs Layers A and B locally and prepares candidate pairs/groups for Layers C (Text LLM) and D (Vision Collage).
    public static func evaluateGalleries(
        galleries: [ACTAIdentityGalleryProfile],
        facetsByIdentity: [String: ACTAFacetSummary],
        existingCannotLinks: Set<String>
    ) -> ACTASweepEvaluationBatch {
        var autoMerges: [ACTADedupDecision] = []
        var newCannotLinks: [ACTADedupDecision] = []
        var layerCTextPairs: [(ACTAIdentityGalleryProfile, ACTAFacetSummary?, ACTAIdentityGalleryProfile, ACTAFacetSummary?)] = []
        var layerDIds: Set<String> = []
        var layerDCandidates: [ACTAIdentityGalleryProfile] = []

        let sorted = galleries.sorted { $0.lastSeenAt > $1.lastSeenAt }
        guard sorted.count >= 2 else {
            return ACTASweepEvaluationBatch()
        }

        for i in 0..<sorted.count {
            for j in (i + 1)..<sorted.count {
                let a = sorted[i]
                let b = sorted[j]
                guard a.kind == b.kind else { continue }

                let pairKey = a.identityID < b.identityID ? "\(a.identityID)|\(b.identityID)" : "\(b.identityID)|\(a.identityID)"
                guard !existingCannotLinks.contains(pairKey) else { continue }

                // Veto if simultaneously active on different cameras
                var simultaneousOverlap = false
                for (camA, winA) in a.activeWindowsByCamera {
                    for (camB, winB) in b.activeWindowsByCamera where camA != camB {
                        let start = max(winA.start, winB.start)
                        let end = min(winA.end, winB.end)
                        if end.timeIntervalSince(start) >= -1.0 {
                            simultaneousOverlap = true
                            break
                        }
                    }
                    if simultaneousOverlap { break }
                }
                if simultaneousOverlap { continue }

                let facetA = facetsByIdentity[a.identityID]
                let facetB = facetsByIdentity[b.identityID]

                // --- LAYER A: Zero-LLM Local Signals ---
                // 1. Exact Plate Match (>= 5 chars)
                if let pA = (a.plateNumber ?? facetA?.plateNumber)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   let pB = (b.plateNumber ?? facetB?.plateNumber)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   pA.count >= 5, pA == pB {
                    autoMerges.append(ACTADedupDecision(
                        idA: a.identityID,
                        idB: b.identityID,
                        layer: .layerALocalSignals,
                        shouldMerge: true,
                        confidence: 0.98,
                        reason: "exact_plate_match:\(pA)"
                    ))
                    continue
                }

                // 2. High ReID + Chroma similarity
                let reidCos = (!a.centroid.isEmpty && !b.centroid.isEmpty)
                    ? ACTAVectorMath.cosineSimilarity(a.centroid, b.centroid)
                    : 0.0
                let chromaSim: Double? = (a.chromaPrint != nil && b.chromaPrint != nil)
                    ? a.chromaPrint!.cosineSimilarity(to: b.chromaPrint!)
                    : nil

                if reidCos >= 0.84, let chromaSim, chromaSim >= 0.82 {
                    autoMerges.append(ACTADedupDecision(
                        idA: a.identityID,
                        idB: b.identityID,
                        layer: .layerALocalSignals,
                        shouldMerge: true,
                        confidence: min(0.97, 0.65 * reidCos + 0.35 * chromaSim),
                        reason: String(format: "reid_chroma_local:%.2f/%.2f", reidCos, chromaSim)
                    ))
                    continue
                }

                // --- LAYER B: Local Structured Facet Comparison ---
                if let facetA, let facetB {
                    let evaluation = compareFacets(a: a, facetA: facetA, b: b, facetB: facetB, reidCos: reidCos, chromaSim: chromaSim)
                    if let decision = evaluation {
                        if decision.shouldMerge {
                            autoMerges.append(decision)
                            continue
                        } else if decision.recordCannotLink {
                            newCannotLinks.append(decision)
                            continue
                        }
                    }
                }

                // --- LAYER C & D Candidate Selection ---
                if reidCos >= 0.56 || (chromaSim ?? 0) >= 0.72 {
                    if layerCTextPairs.count < 8, (facetA?.summaryText != nil || facetB?.summaryText != nil) {
                        layerCTextPairs.append((a, facetA, b, facetB))
                    }
                    if layerDCandidates.count < 6 {
                        if !layerDIds.contains(a.identityID) {
                            layerDIds.insert(a.identityID)
                            layerDCandidates.append(a)
                        }
                        if layerDCandidates.count < 6 && !layerDIds.contains(b.identityID) {
                            layerDIds.insert(b.identityID)
                            layerDCandidates.append(b)
                        }
                    }
                }
            }
        }

        return ACTASweepEvaluationBatch(
            autoMerges: autoMerges,
            newCannotLinks: newCannotLinks,
            layerCTextPairs: layerCTextPairs,
            layerDCollageCandidates: layerDCandidates
        )
    }

    private static func compareFacets(
        a: ACTAIdentityGalleryProfile,
        facetA: ACTAFacetSummary,
        b: ACTAIdentityGalleryProfile,
        facetB: ACTAFacetSummary,
        reidCos: Double,
        chromaSim: Double?
    ) -> ACTADedupDecision? {
        let sexA = a.resolvedSex != .unknown ? a.resolvedSex : facetA.resolvedSex
        let sexB = b.resolvedSex != .unknown ? b.resolvedSex : facetB.resolvedSex
        if sexA != .unknown && sexB != .unknown && sexA != sexB {
            return ACTADedupDecision(
                idA: a.identityID,
                idB: b.identityID,
                layer: .layerBLocalFacets,
                shouldMerge: false,
                recordCannotLink: true,
                confidence: 0.92,
                reason: "sex_conflict:\(sexA.rawValue)_vs_\(sexB.rawValue)"
            )
        }

        if a.kind == "person" {
            var matches = 0
            var conflicts = 0

            if let uTypeA = norm(facetA.upperClothingType), let uTypeB = norm(facetB.upperClothingType) {
                if uTypeA == uTypeB { matches += 1 } else { conflicts += 1 }
            }
            if let uColA = norm(facetA.upperColor), let uColB = norm(facetB.upperColor) {
                if uColA == uColB { matches += 1 } else { conflicts += 1 }
            }
            if let lTypeA = norm(facetA.lowerClothingType), let lTypeB = norm(facetB.lowerClothingType) {
                if lTypeA == lTypeB { matches += 1 } else { conflicts += 1 }
            }
            if let lColA = norm(facetA.lowerColor), let lColB = norm(facetB.lowerColor) {
                if lColA == lColB { matches += 1 } else { conflicts += 1 }
            }
            if let hairA = norm(facetA.hairStyleOrColor), let hairB = norm(facetB.hairStyleOrColor) {
                if hairA == hairB { matches += 1 }
            }

            if conflicts >= 2 && reidCos < 0.72 {
                return ACTADedupDecision(
                    idA: a.identityID,
                    idB: b.identityID,
                    layer: .layerBLocalFacets,
                    shouldMerge: false,
                    recordCannotLink: true,
                    confidence: 0.85,
                    reason: "clothing_conflict:\(conflicts)"
                )
            }
            if matches >= 3 && conflicts == 0 && reidCos >= 0.68 && (chromaSim ?? 0.75) >= 0.72 {
                return ACTADedupDecision(
                    idA: a.identityID,
                    idB: b.identityID,
                    layer: .layerBLocalFacets,
                    shouldMerge: true,
                    recordCannotLink: false,
                    confidence: 0.86,
                    reason: "person_facets_match:\(matches)"
                )
            }
        } else {
            var matches = 0
            var conflicts = 0
            if let vTypeA = norm(facetA.vehicleType), let vTypeB = norm(facetB.vehicleType) {
                if vTypeA == vTypeB { matches += 1 } else { conflicts += 1 }
            }
            if let vColA = norm(facetA.vehicleColor), let vColB = norm(facetB.vehicleColor) {
                if vColA == vColB { matches += 1 } else { conflicts += 1 }
            }
            if let mmA = norm(facetA.makeModel), let mmB = norm(facetB.makeModel) {
                if mmA == mmB { matches += 2 } else { conflicts += 1 }
            }
            if conflicts >= 2 && reidCos < 0.72 {
                return ACTADedupDecision(
                    idA: a.identityID,
                    idB: b.identityID,
                    layer: .layerBLocalFacets,
                    shouldMerge: false,
                    recordCannotLink: true,
                    confidence: 0.85,
                    reason: "vehicle_facets_conflict:\(conflicts)"
                )
            }
            if matches >= 3 && conflicts == 0 && reidCos >= 0.70 {
                return ACTADedupDecision(
                    idA: a.identityID,
                    idB: b.identityID,
                    layer: .layerBLocalFacets,
                    shouldMerge: true,
                    recordCannotLink: false,
                    confidence: 0.87,
                    reason: "vehicle_facets_match:\(matches)"
                )
            }
        }
        return nil
    }

    private static func norm(_ value: String?) -> String? {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !v.isEmpty, v != "unknown", v != "none", v != "n/a" else {
            return nil
        }
        return v
    }
}
