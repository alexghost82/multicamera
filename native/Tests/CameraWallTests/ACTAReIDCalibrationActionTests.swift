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

    func testPrecisionActionTargetsOnlyUniqueAttachedView() async throws {
        let bridge = ACTAReIDCalibrationViewBridge()
        let first = ACTAReIDCalibrationViewState()
        let second = ACTAReIDCalibrationViewState()
        let action = ACTAUpdateReIDCalibrationAction(bridge: bridge)
        let registry = ACTAActionRegistry()
        await registry.register(action)
        let parameters = ["target_precision": "0.95"]

        let absent = try await registry.execute(actionID: action.id, parameters: parameters)
        XCTAssertFalse(absent.success)
        bridge.attach(first)
        let result = try await registry.execute(actionID: action.id, parameters: parameters)
        XCTAssertTrue(result.success, result.summary)
        XCTAssertTrue(result.verified)
        XCTAssertEqual(first.targetPrecision, 0.95)
        XCTAssertEqual(second.targetPrecision, ReIDThresholdCalibrator.defaultTargetPrecision)

        bridge.attach(second)
        let ambiguous = try await registry.execute(actionID: action.id, parameters: ["target_precision": "1"])
        XCTAssertFalse(ambiguous.success)
        XCTAssertEqual(first.targetPrecision, 0.95)
        XCTAssertEqual(second.targetPrecision, ReIDThresholdCalibrator.defaultTargetPrecision)
        let ambiguousVerified = try await action.verify(parameters: parameters, context: ACTAActionContext())
        XCTAssertFalse(ambiguousVerified)
        bridge.detach(first)
        let secondResult = try await registry.execute(actionID: action.id, parameters: ["target_precision": "1"])
        XCTAssertTrue(secondResult.success)
        XCTAssertEqual(second.targetPrecision, 1)
        XCTAssertEqual(first.targetPrecision, 0.95)
        bridge.detach(second)
        let detachedVerified = try await action.verify(parameters: ["target_precision": "1"], context: ACTAActionContext())
        XCTAssertFalse(detachedVerified)
    }

    func testPrecisionActionRejectsInvalidValuesWithoutMutation() async throws {
        let bridge = ACTAReIDCalibrationViewBridge()
        let state = ACTAReIDCalibrationViewState()
        bridge.attach(state)
        let action = ACTAUpdateReIDCalibrationAction(bridge: bridge)
        let registry = ACTAActionRegistry()
        await registry.register(action)
        for parameters in [[:], ["target_precision": "0.8999"], ["target_precision": "1.001"],
                           ["target_precision": "NaN"], ["target_precision": "inf"],
                           ["target_precision": "0.95", "other": "x"]] {
            let result = try await registry.execute(actionID: action.id, parameters: parameters)
            XCTAssertFalse(result.success)
            XCTAssertThrowsError(try action.validate(parameters: parameters))
            XCTAssertEqual(state.targetPrecision, ReIDThresholdCalibrator.defaultTargetPrecision)
        }
        let boundary = try await registry.execute(actionID: action.id, parameters: ["target_precision": "0.9"])
        XCTAssertTrue(boundary.success)
        XCTAssertEqual(state.targetPrecision, 0.9)
    }

    func testPrecisionActionEnforcesSliderStepsAndFloatingPointBoundaries() async throws {
        let bridge = ACTAReIDCalibrationViewBridge()
        let state = ACTAReIDCalibrationViewState()
        bridge.attach(state)
        let action = ACTAUpdateReIDCalibrationAction(bridge: bridge)
        let registry = ACTAActionRegistry()
        await registry.register(action)

        for tick in 180...200 {
            let value = Double(tick) / 200
            let result = try await registry.execute(actionID: action.id, parameters: ["target_precision": String(value)])
            XCTAssertTrue(result.success, "\(value): \(result.summary)")
            XCTAssertTrue(result.verified)
            XCTAssertEqual(state.targetPrecision, value)
        }
        for (input, expected) in [(Double(0.9).nextUp, 0.9), (Double(0.955).nextUp, 0.955), (Double(1.0).nextDown, 1.0)] {
            let result = try await registry.execute(actionID: action.id, parameters: ["target_precision": String(input)])
            XCTAssertTrue(result.success, result.summary)
            XCTAssertTrue(result.verified)
            XCTAssertEqual(state.targetPrecision, expected)
        }
        for value in [Double(0.9).nextDown, Double(1.0).nextUp, 0.9025, 0.954, 0.955 + 1e-12] {
            let previous = state.targetPrecision
            let result = try await registry.execute(actionID: action.id, parameters: ["target_precision": String(value)])
            XCTAssertFalse(result.success, "\(value) must be rejected")
            XCTAssertEqual(state.targetPrecision, previous)
        }
    }

    func testPrecisionViewStateReportsInvalidInputWithoutPublishingOrChangingRevision() {
        let state = ACTAReIDCalibrationViewState()
        var observed: [Double] = []
        let subscription = state.$targetPrecision.sink { observed.append($0) }
        let revision = state.revision
        for value in [0.9025, Double.nan, Double(0.9).nextDown, Double(1.0).nextUp] {
            XCTAssertFalse(state.setTargetPrecision(value))
            XCTAssertEqual(state.revision, revision)
        }
        XCTAssertEqual(observed, [ReIDThresholdCalibrator.defaultTargetPrecision])
        XCTAssertTrue(state.setTargetPrecision(Double(0.955).nextUp))
        XCTAssertEqual(state.targetPrecision, 0.955)
        XCTAssertNotEqual(state.revision, revision)
        withExtendedLifetime(subscription) {}
    }

    func testPrecisionVerificationRejectsInterveningChangesAndReattachment() async throws {
        let bridge = ACTAReIDCalibrationViewBridge()
        let state = ACTAReIDCalibrationViewState()
        let action = ACTAUpdateReIDCalibrationAction(bridge: bridge)
        let parameters = ["target_precision": "0.95"]
        let context = ACTAActionContext()
        bridge.attach(state)
        let result = try await action.execute(parameters: parameters, context: context)
        XCTAssertTrue(result.success)
        XCTAssertTrue(state.setTargetPrecision(0.96))
        XCTAssertTrue(state.setTargetPrecision(0.95))
        let changedVerified = try await action.verify(parameters: parameters, context: context)
        XCTAssertFalse(changedVerified)

        _ = try await action.execute(parameters: parameters, context: context)
        bridge.detach(state)
        bridge.attach(state)
        let reattachedVerified = try await action.verify(parameters: parameters, context: context)
        XCTAssertFalse(reattachedVerified)
    }

    func testPrecisionStatePublishesAgentAndGUIChangesAndRejectsCancellation() async throws {
        let bridge = ACTAReIDCalibrationViewBridge()
        let state = ACTAReIDCalibrationViewState()
        bridge.attach(state)
        var observed: [Double] = []
        let subscription = state.$targetPrecision.sink { observed.append($0) }
        let action = ACTAUpdateReIDCalibrationAction(bridge: bridge)
        let parameters = ["target_precision": "0.91"]
        let result = try await action.execute(parameters: parameters, context: ACTAActionContext())
        XCTAssertTrue(result.success)
        XCTAssertTrue(state.setTargetPrecision(0.92))
        XCTAssertEqual(observed, [ReIDThresholdCalibrator.defaultTargetPrecision, 0.91, 0.92])

        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await action.execute(parameters: parameters, context: ACTAActionContext())
        }
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled action must not mutate view state")
        } catch is CancellationError {
            XCTAssertEqual(state.targetPrecision, 0.92)
        }
        withExtendedLifetime(subscription) {}
    }
}
