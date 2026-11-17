import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTAReIDCalibrationActionTests: XCTestCase {
    private final class Provider: ACTAReIDCalibrationProvider {
        var pairs: [LabeledReIDPair] = []
        var calls = 0
        var failure: Error?

        func calibrate(targetPrecision: Double) async throws -> ReIDCalibrationResult {
            calls += 1
            if let failure { throw failure }
            return ReIDThresholdCalibrator.calibrate(pairs, targetPrecision: targetPrecision)
        }
    }

    private struct SensitiveError: LocalizedError {
        var errorDescription: String? { "/private/synthetic-track" }
    }

    func testAggregateUsesRequestedPrecisionAndDoesNotApplySettings() async throws {
        let provider = Provider()
        provider.pairs = Array(repeating: LabeledReIDPair(distance: 0.1, sameObject: true), count: 20)
            + [LabeledReIDPair(distance: 0.1, sameObject: false)]
            + Array(repeating: LabeledReIDPair(distance: 0.8, sameObject: false), count: 99)
        let registry = ACTAActionRegistry()
        await registry.register(ACTAReIDCalibrationAction(provider: provider))
        let lower = try await registry.execute(actionID: "reid.calibrate", parameters: ["target_precision": "0.90"])
        XCTAssertTrue(lower.success, lower.summary)
        XCTAssertTrue(lower.verified)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lower.outputJSON.utf8)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["positive_pairs", "negative_pairs", "target_precision", "ready",
                                      "recommended_distance", "precision", "recall", "false_positives", "true_positives"])
        XCTAssertEqual(json["positive_pairs"] as? Int, 20)
        XCTAssertEqual(json["negative_pairs"] as? Int, 100)
        XCTAssertEqual(json["recommended_distance"] as? Double, 0.1)
        XCTAssertEqual(json["false_positives"] as? Int, 1)
        XCTAssertEqual(json["ready"] as? Bool, true)
        let strict = try await registry.execute(actionID: "reid.calibrate", parameters: ["target_precision": "1"])
        let strictJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(strict.outputJSON.utf8)) as? [String: Any])
        XCTAssertEqual(strictJSON["ready"] as? Bool, false)
        XCTAssertNil(strictJSON["recommended_distance"])
        XCTAssertFalse(lower.summary.localizedCaseInsensitiveContains("saved"))
    }

    func testInsufficientLabelsAndInvalidInputs() async throws {
        let provider = Provider()
        provider.pairs = [LabeledReIDPair(distance: 0.1, sameObject: true)]
        let registry = ACTAActionRegistry()
        let action = ACTAReIDCalibrationAction(provider: provider)
        await registry.register(action)
        let result = try await registry.execute(actionID: action.id, parameters: ["target_precision": "0.995"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        XCTAssertTrue(result.success)
        XCTAssertEqual(json["positive_pairs"] as? Int, 1)
        XCTAssertEqual(json["negative_pairs"] as? Int, 0)
        XCTAssertEqual(json["ready"] as? Bool, false)
        for parameters in [[:], ["target_precision": "0.8999"], ["target_precision": "1.001"],
                           ["target_precision": "NaN"], ["target_precision": "inf"],
                           ["target_precision": "0.95", "other": "x"]] {
            let invalid = try await registry.execute(actionID: action.id, parameters: parameters)
            XCTAssertFalse(invalid.success)
            XCTAssertThrowsError(try action.validate(parameters: parameters))
        }
        XCTAssertEqual(provider.calls, 1)
    }

    func testSourceFailureDoesNotLeakDetails() async throws {
        let provider = Provider()
        provider.failure = SensitiveError()
        let registry = ACTAActionRegistry()
        await registry.register(ACTAReIDCalibrationAction(provider: provider))
        let result = try await registry.execute(actionID: "reid.calibrate", parameters: ["target_precision": "0.95"])
        XCTAssertFalse(result.success)
        XCTAssertFalse(result.verified)
        XCTAssertEqual(result.error, "SOURCE_ERROR: ReID calibration failed.")
        XCTAssertFalse(result.outputJSON.contains("synthetic-track"))
    }
}
