import CameraCore
import Foundation
import XCTest
@testable import CameraWall

private actor CalibrationChatScript {
    private(set) var prompts: [String] = []
    func reply(_ prompt: String) -> String {
        prompts.append(prompt)
        if prompts.count == 1 {
            return #"{"tool_calls":[{"name":"acta__reid__calibrate","arguments":{"target_precision":0.95}}]}"#
        }
        return #"{"answerMarkdown":"Calibration complete.","confidence":0.5}"#
    }
}

private actor CalibrationUpdateChatScript {
    private(set) var prompts: [String] = []
    func reply(_ prompt: String) -> String {
        prompts.append(prompt)
        if prompts.count == 1 {
            return #"{"tool_calls":[{"name":"acta__settings__update_reid_calibration","arguments":{"target_precision":0.95}}]}"#
        }
        return #"{"answerMarkdown":"Review requested.","confidence":0.5}"#
    }
}

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

    func testAuditedChatLoopReturnsOnlyAggregateCalibration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acta-calibration-chat-\(UUID().uuidString)", isDirectory: true)
        let store = try LocalTrackingStore(url: root.appendingPathComponent("tracking.sqlite"))
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = Provider()
        provider.pairs = [LabeledReIDPair(distance: 0.1, sameObject: true)]
        let action = ACTAReIDCalibrationAction(provider: provider)
        let scopes = ACTAAnalyticsCoordinator.localInspectionIDs
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id],
                                                     allowedInspectionIDs: scopes, audit: { _ in })
        let host = try XCTUnwrap(made)
        let issued = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
            threadID: "fixture", actionIDs: [action.id], inspectionIDs: scopes)
        let session = try XCTUnwrap(issued)
        let script = CalibrationChatScript()
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .mlxInProcess), transport: { _ in
            XCTFail("Unexpected network request")
            throw URLError(.notConnectedToInternet)
        }, keyProvider: { _ in XCTFail("Unexpected Keychain access"); return nil },
            localAgentInference: { prompt, _ in await script.reply(prompt) })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        _ = await coordinator.askACTAChatAgent(question: "Calculate calibration", threadID: "fixture",
                                              broker: host.broker, brokerSession: session)
        let prompts = await script.prompts
        XCTAssertTrue(prompts.first?.contains("acta__reid__calibrate") == true)
        XCTAssertTrue(prompts.dropFirst().contains { $0.contains("positive_pairs") && $0.contains("action_output") })
        XCTAssertEqual(provider.calls, 1)
        await host.broker.closeSession(session, operatorKey: host.operatorKey)
    }

    func testBrokerAuditFailureDoesNotReleaseCalibration() async throws {
        let provider = Provider()
        provider.pairs = [LabeledReIDPair(distance: 0.1, sameObject: true)]
        let action = ACTAReIDCalibrationAction(provider: provider)
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id], audit: { event in
            if event.phase == .result && event.outcome == "success" { throw CocoaError(.fileWriteUnknown) }
        })
        let host = try XCTUnwrap(made)
        let issued = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
            threadID: "fixture", actionIDs: [action.id])
        let session = try XCTUnwrap(issued)
        let result = await host.broker.request(session: session, actionID: action.id,
                                               argumentsJSON: #"{"target_precision":0.95}"#)
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.hasPrefix("AUDIT_FAILED:") == true)
        XCTAssertFalse(result.outputJSON.contains("positive_pairs"))
        await host.broker.closeSession(session, operatorKey: host.operatorKey)
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

    func testPrecisionViewStateNotifiesGUIBeforeAndValueSubscribersAfterCommit() {
        let state = ACTAReIDCalibrationViewState()
        var observed: [String] = []
        let changes = state.objectWillChange.sink {
            observed.append("will:\(state.targetPrecision)")
        }
        let values = state.$targetPrecision.sink { value in
            observed.append("value:\(value):state:\(state.targetPrecision)")
        }
        let initial = state.targetPrecision
        XCTAssertFalse(state.setTargetPrecision(0.9025))
        XCTAssertTrue(state.setTargetPrecision(0.95))
        XCTAssertEqual(observed, ["value:\(initial):state:\(initial)",
                                  "will:\(initial)", "value:0.95:state:0.95"])
        withExtendedLifetime((changes, values)) {}
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

    func testReviewedCalibrationBrokerChatAndApproval() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".acta-reid-chat-\(UUID().uuidString)", isDirectory: true)
        let store = try LocalTrackingStore(url: root.appendingPathComponent("tracking.sqlite"))
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ACTAReIDCalibrationViewBridge()
        let state = ACTAReIDCalibrationViewState()
        bridge.attach(state)
        let action = ACTAReviewedReIDCalibrationAction(bridge: bridge)
        let scopes = ACTAAnalyticsCoordinator.localInspectionIDs
        let made = await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], allowedInspectionIDs: scopes, audit: { _ in })
        let host = try XCTUnwrap(made)
        let opened = await host.broker.openSession(operatorKey: host.operatorKey,
            input: .chat, threadID: "fixture", actionIDs: [action.id], inspectionIDs: scopes)
        let session = try XCTUnwrap(opened)
        let script = CalibrationUpdateChatScript()
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .mlxInProcess), transport: { _ in
            XCTFail("Unexpected network request")
            throw URLError(.notConnectedToInternet)
        }, keyProvider: { _ in XCTFail("Unexpected Keychain access"); return nil },
            localAgentInference: { prompt, _ in await script.reply(prompt) })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        _ = await coordinator.askACTAChatAgent(question: "Change calibration", threadID: "fixture",
                                               broker: host.broker, brokerSession: session)
        let prompts = await script.prompts
        XCTAssertTrue(prompts.first?.contains("acta__settings__update_reid_calibration") == true)
        XCTAssertTrue(prompts.dropFirst().contains { $0.contains("requires_operator_confirmation") })
        XCTAssertFalse(prompts.dropFirst().contains { $0.contains("recommended_distance") || $0.contains("positive_pairs") })
        XCTAssertEqual(state.targetPrecision, ReIDThresholdCalibrator.defaultTargetPrecision)
        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let review = try XCTUnwrap(reviews.first)
        XCTAssertEqual(reviews.count, 1)
        XCTAssertTrue(review.title.contains("0.95"))
        XCTAssertTrue(review.title.contains("asynchronous validation metric recalculation"))
        let result = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                               reviewed: review, approved: true)
        XCTAssertTrue(result.success && result.verified, result.summary)
        XCTAssertTrue(result.summary.contains("asynchronous validation metric recalculation"))
        XCTAssertTrue(action.description.contains("asynchronous validation metric recalculation"))
        XCTAssertEqual(state.targetPrecision, 0.95)
        XCTAssertFalse(result.outputJSON.contains("recommended_distance"))
        XCTAssertFalse(result.outputJSON.contains("positive_pairs"))
        let replay = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                               reviewed: review, approved: true)
        XCTAssertFalse(replay.success)
        await host.broker.closeSession(session, operatorKey: host.operatorKey)
    }

    func testReviewedCalibrationRejectsStaleABAAndLifecycleChanges() async throws {
        for scenario in 0..<4 {
            let bridge = ACTAReIDCalibrationViewBridge()
            let state = ACTAReIDCalibrationViewState()
            let other = ACTAReIDCalibrationViewState()
            bridge.attach(state)
            let action = ACTAReviewedReIDCalibrationAction(bridge: bridge)
            let parameters = ["target_precision": "0.95"]
            let context = ACTAActionContext(threadID: "fixture")
            let confirmedContext = ACTAActionContext(threadID: "fixture", isConfirmed: true)
            let prepared = try await action.prepareConfirmation(parameters: parameters, context: context)
            switch scenario {
            case 0:
                let old = state.targetPrecision
                XCTAssertTrue(state.setTargetPrecision(0.9))
                XCTAssertTrue(state.setTargetPrecision(old))
            case 1:
                bridge.detach(state)
                bridge.attach(state)
            case 2:
                bridge.attach(other)
            default:
                bridge.detach(state)
            }
            let before = state.targetPrecision
            let result = try await action.executeConfirmed(parameters: parameters, context: confirmedContext,
                                                            snapshot: prepared.snapshot)
            XCTAssertFalse(result.success)
            XCTAssertTrue(result.error?.hasPrefix("STALE_REVIEW:") == true)
            XCTAssertEqual(state.targetPrecision, before)
        }
    }

    func testReviewedCalibrationRejectsReentrancyAndModelScopeConfusion() async throws {
        let bridge = ACTAReIDCalibrationViewBridge()
        let otherModelBridge = ACTAReIDCalibrationViewBridge()
        let state = ACTAReIDCalibrationViewState()
        let other = ACTAReIDCalibrationViewState()
        bridge.attach(state)
        otherModelBridge.attach(other)
        let action = ACTAReviewedReIDCalibrationAction(bridge: bridge)
        let parameters = ["target_precision": "0.95"]
        let context = ACTAActionContext(threadID: "fixture")
        let confirmedContext = ACTAActionContext(threadID: "fixture", isConfirmed: true)
        var prepared = try await action.prepareConfirmation(parameters: parameters, context: context)
        let subscription = state.objectWillChange.sink {
            bridge.detach(state)
            bridge.attach(state)
        }
        let before = state.targetPrecision
        var result = try await action.executeConfirmed(parameters: parameters, context: confirmedContext, snapshot: prepared.snapshot)
        XCTAssertFalse(result.success)
        XCTAssertEqual(state.targetPrecision, before)
        subscription.cancel()
        prepared = try await action.prepareConfirmation(parameters: parameters, context: context)
        var nestedResult = true
        let nested = state.$targetPrecision.dropFirst().sink { _ in
            nestedResult = state.setTargetPrecision(0.9)
        }
        result = try await action.executeConfirmed(parameters: parameters, context: confirmedContext, snapshot: prepared.snapshot)
        XCTAssertFalse(result.success)
        XCTAssertFalse(nestedResult)
        XCTAssertEqual(state.targetPrecision, 0.95)
        XCTAssertEqual(other.targetPrecision, ReIDThresholdCalibrator.defaultTargetPrecision)
        nested.cancel()
        prepared = try await action.prepareConfirmation(parameters: ["target_precision": "0.96"], context: context)
        result = try await action.executeConfirmed(parameters: ["target_precision": "0.96"],
                                                   context: confirmedContext, snapshot: prepared.snapshot)
        XCTAssertTrue(result.success)
        let verified = try await action.verify(parameters: ["target_precision": "0.96"], context: confirmedContext)
        XCTAssertTrue(verified)
        XCTAssertEqual(other.targetPrecision, ReIDThresholdCalibrator.defaultTargetPrecision)
    }

    func testReviewedCalibrationRejectionAndAuditFailureDoNotWrite() async throws {
        for failAudit in [false, true] {
            let bridge = ACTAReIDCalibrationViewBridge()
            let state = ACTAReIDCalibrationViewState()
            bridge.attach(state)
            let action = ACTAReviewedReIDCalibrationAction(bridge: bridge)
            let made = await ACTALocalActionBroker.make(actions: [action],
                allowedActionIDs: [action.id], audit: { event in
                    if failAudit && event.phase == .review { throw CocoaError(.fileWriteUnknown) }
                })
            let host = try XCTUnwrap(made)
            let opened = await host.broker.openSession(operatorKey: host.operatorKey,
                input: .chat, threadID: "fixture", actionIDs: [action.id])
            let session = try XCTUnwrap(opened)
            let pending = await host.broker.request(session: session, actionID: action.id,
                                                     argumentsJSON: #"{"target_precision":0.95}"#)
            XCTAssertTrue(pending.requiresOperatorConfirmation)
            let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
            let review = try XCTUnwrap(reviews.first)
            let result = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                   reviewed: review, approved: failAudit)
            XCTAssertFalse(result.success)
            if failAudit { XCTAssertTrue(result.error?.hasPrefix("AUDIT_FAILED:") == true) }
            XCTAssertEqual(state.targetPrecision, ReIDThresholdCalibrator.defaultTargetPrecision)
            await host.broker.closeSession(session, operatorKey: host.operatorKey)
        }
    }

    func testReviewedCalibrationRequiresUniqueViewAndVerifiesRevision() async throws {
        let bridge = ACTAReIDCalibrationViewBridge()
        let first = ACTAReIDCalibrationViewState()
        let second = ACTAReIDCalibrationViewState()
        let action = ACTAReviewedReIDCalibrationAction(bridge: bridge)
        let parameters = ["target_precision": "0.95"]
        let context = ACTAActionContext(threadID: "fixture")
        let confirmedContext = ACTAActionContext(threadID: "fixture", isConfirmed: true)
        do {
            _ = try await action.prepareConfirmation(parameters: parameters, context: context)
            XCTFail("No attached view must be unavailable")
        } catch {}
        bridge.attach(first)
        bridge.attach(second)
        do {
            _ = try await action.prepareConfirmation(parameters: parameters, context: context)
            XCTFail("Multiple attached views must be unavailable")
        } catch {}
        bridge.detach(second)
        let prepared = try await action.prepareConfirmation(parameters: parameters, context: context)
        let result = try await action.executeConfirmed(parameters: parameters, context: confirmedContext,
                                                        snapshot: prepared.snapshot)
        XCTAssertTrue(result.success)
        XCTAssertTrue(first.setTargetPrecision(0.9))
        XCTAssertTrue(first.setTargetPrecision(0.95))
        let verified = try await action.verify(parameters: parameters, context: confirmedContext)
        XCTAssertFalse(verified)
        XCTAssertEqual(second.targetPrecision, ReIDThresholdCalibrator.defaultTargetPrecision)
    }

    func testReviewedCalibrationRejectsUnconfirmedContextAndConsumesSnapshot() async throws {
        let bridge = ACTAReIDCalibrationViewBridge()
        let state = ACTAReIDCalibrationViewState()
        bridge.attach(state)
        let action = ACTAReviewedReIDCalibrationAction(bridge: bridge)
        let parameters = ["target_precision": "0.95"]
        let context = ACTAActionContext(threadID: "fixture")
        let prepared = try await action.prepareConfirmation(parameters: parameters, context: context)
        let revision = state.revision
        let result = try await action.executeConfirmed(parameters: parameters, context: context,
                                                       snapshot: prepared.snapshot)
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.hasPrefix("CONFIRMATION_REQUIRED:") == true)
        XCTAssertEqual(state.revision, revision)
        XCTAssertEqual(state.targetPrecision, ReIDThresholdCalibrator.defaultTargetPrecision)
        let confirmed = ACTAActionContext(threadID: "fixture", isConfirmed: true)
        let replay = try await action.executeConfirmed(parameters: parameters, context: confirmed,
                                                       snapshot: prepared.snapshot)
        XCTAssertTrue(replay.error?.hasPrefix("CONFIRMATION_CONSUMED:") == true)
    }

    func testReviewedCalibrationBrokerRejectsStaleAndWithholdsUnauditedResult() async throws {
        for stale in [true, false] {
            let bridge = ACTAReIDCalibrationViewBridge()
            let state = ACTAReIDCalibrationViewState()
            bridge.attach(state)
            let action = ACTAReviewedReIDCalibrationAction(bridge: bridge)
            let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id],
                audit: { event in
                    if !stale && event.phase == .result && event.outcome == "success" {
                        throw CocoaError(.fileWriteUnknown)
                    }
                })
            let host = try XCTUnwrap(made)
            let opened = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
                                                        threadID: "fixture", actionIDs: [action.id])
            let session = try XCTUnwrap(opened)
            let request = await host.broker.request(session: session, actionID: action.id,
                                                     argumentsJSON: #"{"target_precision":0.95}"#)
            XCTAssertTrue(request.requiresOperatorConfirmation)
            let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
            let review = try XCTUnwrap(reviews.first)
            if stale {
                bridge.detach(state)
                bridge.attach(state)
            }
            let result = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                   reviewed: review, approved: true)
            XCTAssertFalse(result.success)
            if stale {
                XCTAssertTrue(result.error?.hasPrefix("STALE_REVIEW:") == true)
                XCTAssertEqual(state.targetPrecision, ReIDThresholdCalibrator.defaultTargetPrecision)
            } else {
                XCTAssertTrue(result.error?.hasPrefix("AUDIT_FAILED:") == true)
                XCTAssertEqual(state.targetPrecision, 0.95)
                XCTAssertFalse(result.outputJSON.contains("target_precision"))
            }
            await host.broker.closeSession(session, operatorKey: host.operatorKey)
        }
    }
}
