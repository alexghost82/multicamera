import Foundation
import Vision

struct VisionFeatureInput: Sendable {
    let trackID: UUID
    let cameraID: UUID
    let cameraName: String
    let label: String
    let lastSeen: Date
    let imageData: Data?
}

struct VisionFeatureMatch: Equatable, Identifiable, Sendable {
    let trackID: UUID
    let cameraID: UUID
    let cameraName: String
    let label: String
    let lastSeen: Date
    let distance: Float
    let metric: String

    var id: UUID { trackID }
}

enum VisionFeatureMatcherError: LocalizedError {
    case invalidSourceImage

    var errorDescription: String? {
        switch self {
        case .invalidSourceImage: return "Could not create a local visual descriptor for this crop."
        }
    }
}

enum VisionFeatureMatcher {
    static let maximumComparisons = 40

    static func nearest(
        sourceTrackID: UUID,
        sourceCameraID: UUID,
        sourceLabel: String,
        sourceImage: Data?,
        candidates: [VisionFeatureInput],
        sourceEmbedding: [Float]? = nil,
        candidateEmbeddings: [UUID: [Float]] = [:],
        limit: Int = 5
    ) throws -> [VisionFeatureMatch] {
        guard let sourceCategory = category(sourceLabel),
              let kind = ReIDModelKind.forLabel(sourceLabel) else {
            throw VisionFeatureMatcherError.invalidSourceImage
        }
        if ONNXReIDEncoder.modelURL(for: kind) != nil {
            guard let encoder = ONNXReIDEncoder.shared else { throw ONNXReIDError.coreMLUnavailable }
            return try nearestReID(sourceTrackID: sourceTrackID, sourceCameraID: sourceCameraID,
                                   sourceLabel: sourceLabel, sourceCategory: sourceCategory,
                                   sourceImage: sourceImage, candidates: candidates,
                                   sourceEmbedding: sourceEmbedding,
                                   candidateEmbeddings: candidateEmbeddings,
                                   limit: limit, encoder: encoder)
        }
        guard let sourceImage, let sourcePrint = featurePrint(for: sourceImage) else {
            throw VisionFeatureMatcherError.invalidSourceImage
        }

        var matches: [VisionFeatureMatch] = []
        for candidate in candidates.prefix(maximumComparisons) {
            guard candidate.trackID != sourceTrackID,
                  candidate.cameraID != sourceCameraID,
                  category(candidate.label) == sourceCategory,
                  let candidateImage = candidate.imageData,
                  let candidatePrint = featurePrint(for: candidateImage) else { continue }
            var distance: Float = 0
            guard (try? sourcePrint.computeDistance(&distance, to: candidatePrint)) != nil,
                distance.isFinite else { continue }
            matches.append(VisionFeatureMatch(
                trackID: candidate.trackID,
                cameraID: candidate.cameraID,
                cameraName: candidate.cameraName,
                label: candidate.label,
                lastSeen: candidate.lastSeen,
                distance: distance,
                metric: "Vision feature-print distance"
            ))
        }
        return matches.sorted { $0.distance < $1.distance }
            .prefix(max(1, min(20, limit)))
            .map { $0 }
    }

    private static func nearestReID(
        sourceTrackID: UUID,
        sourceCameraID: UUID,
        sourceLabel: String,
        sourceCategory: String,
        sourceImage: Data?,
        candidates: [VisionFeatureInput],
        sourceEmbedding: [Float]?,
        candidateEmbeddings: [UUID: [Float]],
        limit: Int,
        encoder: ONNXReIDEncoder
    ) throws -> [VisionFeatureMatch] {
        let sourceVector: [Float]
        if let sourceEmbedding, sourceEmbedding.count == 512, sourceEmbedding.allSatisfy(\.isFinite) {
            sourceVector = sourceEmbedding
        } else {
            guard let sourceImage else { throw VisionFeatureMatcherError.invalidSourceImage }
            sourceVector = try encoder.embedding(jpeg: sourceImage, trackID: sourceTrackID, label: sourceLabel)
        }
        var matches: [VisionFeatureMatch] = []
        for candidate in candidates.prefix(maximumComparisons) {
            guard candidate.trackID != sourceTrackID,
                  candidate.cameraID != sourceCameraID,
                  category(candidate.label) == sourceCategory,
                  let kind = ReIDModelKind.forLabel(candidate.label),
                  kind == ReIDModelKind.forLabel(sourceLabel) else { continue }
            let vector: [Float]
            if let cached = candidateEmbeddings[candidate.trackID], cached.count == 512,
               cached.allSatisfy(\.isFinite) {
                vector = cached
            } else {
                guard let imageData = candidate.imageData else { continue }
                vector = try encoder.embedding(jpeg: imageData,
                                               trackID: candidate.trackID, label: candidate.label)
            }
            let cosine = zip(sourceVector, vector).reduce(Float.zero) { $0 + $1.0 * $1.1 }
            matches.append(VisionFeatureMatch(
                trackID: candidate.trackID,
                cameraID: candidate.cameraID,
                cameraName: candidate.cameraName,
                label: candidate.label,
                lastSeen: candidate.lastSeen,
                distance: max(0, min(2, 1 - cosine)),
                metric: "ReID cosine distance"
            ))
        }
        return matches.sorted { $0.distance < $1.distance }
            .prefix(max(1, min(20, limit)))
            .map { $0 }
    }

    private static func featurePrint(for image: Data) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        do {
            try VNImageRequestHandler(data: image).perform([request])
            return request.results?.first
        } catch {
            return nil
        }
    }

    private static func category(_ label: String) -> String? {
        if label == "person" { return "person" }
        if ["bicycle", "car", "motorcycle", "bus", "train", "truck", "boat"].contains(label) {
            return "vehicle"
        }
        return nil
    }
}