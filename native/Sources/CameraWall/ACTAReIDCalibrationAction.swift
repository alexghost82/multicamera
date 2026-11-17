import CameraCore
import Foundation

enum ReIDCalibrationActionError: LocalizedError {
    case invalidArgument
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidArgument: return "INVALID_ARGUMENT: target_precision must be a finite number in 0.90...1.0."
        case .unavailable: return "UNAVAILABLE: ReID validation data is unavailable."
        }
    }
}

@MainActor
protocol ACTAReIDCalibrationProvider: Sendable {
    func calibrate(targetPrecision: Double) async throws -> ReIDCalibrationResult
}

@MainActor
final class ACTAWallReIDCalibrationProvider: ACTAReIDCalibrationProvider {
    private weak var model: WallModel?

    init(model: WallModel) { self.model = model }

    func calibrate(targetPrecision: Double) async throws -> ReIDCalibrationResult {
        guard let model else { throw ReIDCalibrationActionError.unavailable }
        return try await model.calculateReIDCalibration(targetPrecision: targetPrecision)
    }
}

struct ACTAReIDCalibrationAction: ACTAActionProtocol {
    let provider: any ACTAReIDCalibrationProvider
    let id = "reid.calibrate"
    let title = "Calculate ReID recommendation"
    let description = "Calculate aggregate ReID validation metrics from locally labeled pairs. Does not apply or save a threshold."
    let classification = ACTAActionClassification.inspect
    let parameters = [
        ACTAActionParameterSchema(name: "target_precision", type: "number",
                                  description: "Target precision between 0.90 and 1.0 inclusive", isRequired: true)
    ]

    private func target(_ parameters: [String: String]) throws -> Double {
        guard Set(parameters.keys) == ["target_precision"],
              let raw = parameters["target_precision"], let value = Double(raw),
              value.isFinite, (0.90...1.0).contains(value) else {
            throw ReIDCalibrationActionError.invalidArgument
        }
        return value
    }

    func validate(parameters: [String: String]) throws { _ = try target(parameters) }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        let value = try target(parameters)
        try Task.checkCancellation()
        let result: ReIDCalibrationResult
        do {
            result = try await provider.calibrate(targetPrecision: value)
        } catch is CancellationError {
            throw CancellationError()
        } catch ReIDCalibrationActionError.unavailable {
            return .failed(actionID: id, error: "UNAVAILABLE: ReID validation data is unavailable.")
        } catch {
            return .failed(actionID: id, error: "SOURCE_ERROR: ReID calibration failed.")
        }
        try Task.checkCancellation()
        let output = Aggregate(result)
        let json = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
        return ACTAActionResult(actionID: id, success: true,
                                summary: "Calculated ReID validation metrics; no settings were changed.",
                                outputJSON: json)
    }

    private struct Aggregate: Encodable {
        let positive_pairs: Int
        let negative_pairs: Int
        let target_precision: Double
        let ready: Bool
        let recommended_distance: Double?
        let precision: Double?
        let recall: Double?
        let false_positives: Int?
        let true_positives: Int?

        init(_ result: ReIDCalibrationResult) {
            positive_pairs = result.positivePairs
            negative_pairs = result.negativePairs
            target_precision = result.targetPrecision
            ready = result.isReady
            recommended_distance = result.recommendedDistance
            precision = result.precision
            recall = result.recall
            false_positives = result.falsePositives
            true_positives = result.truePositives
        }
    }
}
