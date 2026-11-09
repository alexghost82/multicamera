import Foundation
import Vision
import CameraCore
import CryptoKit

enum VehicleTextReader {
    static let maximumImageBytes = 1_000_000

    static func shouldPersist(startedOptedIn: Bool, stillOptedIn: Bool, generationMatches: Bool) -> Bool {
        startedOptedIn && stillOptedIn && generationMatches
    }

    static func evidence(
        candidates: [VehicleTextCandidate], imageData: Data, trackID: UUID, readAt: Date = Date()
    ) throws -> VehicleTextEvidence {
        guard !imageData.isEmpty, imageData.count <= maximumImageBytes else { throw LocalVLMError.invalidImage }
        let digest = SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined()
        return VehicleTextEvidence(trackID: trackID, candidates: candidates, readAt: readAt, cropSHA256: digest)
    }

    static func readCandidates(from imageData: Data) throws -> [VehicleTextCandidate] {
        guard !imageData.isEmpty, imageData.count <= maximumImageBytes else { throw LocalVLMError.invalidImage }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = false
        try VNImageRequestHandler(data: imageData).perform([request])
        let candidates = (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map {
                VehicleTextCandidate(text: $0.string, confidence: $0.confidence)
            }
        }
        return VehicleTextCandidate.normalize(candidates)
    }
}