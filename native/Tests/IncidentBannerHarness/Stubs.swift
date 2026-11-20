import CameraCore
import CoreVideo
import Foundation

// Inference dependencies in this harness never load models or devices.
struct PoseKeypoint: Equatable, Sendable {
    let x: Double
    let y: Double
    let confidence: Double
}
struct PoseBoundingBox: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}
struct PosePerson: Equatable, Sendable {
    let confidence: Double
    let box: PoseBoundingBox
    let keypoints: [PoseKeypoint]
}
struct PoseInferenceResult: Sendable {
    let people: [PosePerson]
    let inferenceMilliseconds: Double
}
final class YOLO26PoseDetector: @unchecked Sendable {
    static var defaultModelURL: URL? { nil }
    private let modelURL: URL
    init(modelURL: URL) { self.modelURL = modelURL }
    func prepare() async throws { await SyntheticPoseLoads.shared.wait(for: modelURL) }
    func detect(pixel: CVPixelBuffer, threshold: Double) throws -> PoseInferenceResult {
        throw HarnessError.unavailable
    }
}
enum HarnessError: Error { case unavailable }
enum YOLO26Detector { static var defaultModelURL: URL? { nil } }
enum ONNXSegmentationEncoder { static var modelURL: URL? { nil } }
enum ONNXReIDEncoder {
    enum Kind { case person, vehicle }
    static func modelURL(for kind: Kind) -> URL? { nil }
}
enum ModelSelectionRegistry {
    enum Service { case pose }
    static var poseEnabled = false
    static func isEnabled(_ service: Service) -> Bool { poseEnabled }
}
actor SyntheticPoseLoads {
    static let shared = SyntheticPoseLoads()
    private var waiting: [URL: CheckedContinuation<Void, Never>] = [:]
    private var startCounts: [URL: Int] = [:]

    func wait(for url: URL) async {
        startCounts[url, default: 0] += 1
        await withCheckedContinuation { waiting[url] = $0 }
    }

    func isWaiting(for url: URL) -> Bool { waiting[url] != nil }
    func starts(for url: URL) -> Int { startCounts[url, default: 0] }

    func release(_ url: URL) {
        waiting.removeValue(forKey: url)?.resume()
    }
}
struct IdentityPixelBuffer: @unchecked Sendable { let value: CVPixelBuffer }
enum VLMFrameEncoder {
    static func jpegData(from buffer: CVPixelBuffer, maxDimension: Int, quality: Double) async throws -> Data {
        throw HarnessError.unavailable
    }
}
struct ACTAAnalyticsSettingsObservation: Sendable, Equatable {
    let revision: UUID
    let memory: VideoAnalyticsSettings
    let persisted: VideoAnalyticsSettings
}
