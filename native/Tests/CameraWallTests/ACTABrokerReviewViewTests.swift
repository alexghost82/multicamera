import CameraCore
import Foundation
import XCTest
@testable import CameraWall

private actor BrokerReviewCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private actor BrokerModelScript {
    private(set) var prompts: [String] = []
    func reply(_ prompt: String) -> String {
        prompts.append(prompt)
        if prompts.count == 1 {
            return #"{"tool_calls":[{"name":"acta__canvas__set_filter","arguments":{"favorites_only":true}}]}"#
        }
        return #"{"answerMarkdown":"Review requested.","confidence":0.5}"#
    }
}

private struct BrokerReviewProbeAction: ACTAActionProtocol {
    let id = "test.review"
    let title = "Review"
    let description = "Fake review action"
    let classification = ACTAActionClassification.reversible
    let parameters = [ACTAActionParameterSchema(name: "value", type: "string", description: "Value", isRequired: true)]
    let counter: BrokerReviewCounter
    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        await counter.increment()
        return ACTAActionResult(actionID: id, success: true, summary: "done")
    }
    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool { true }
}

@MainActor
private final class BrokerFilterInventory {
    private(set) var revision = UUID()
    var groups: Set<String> = ["Entrance"] { willSet { revision = UUID() } }
    var cameraIDs: [UUID] = [] { willSet { revision = UUID() } }
}

@MainActor
final class ACTABrokerReviewViewTests: XCTestCase {
    func testChatLoopAdvertisesScopedActionAndCreatesReview() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acta-broker-catalogue-\(UUID().uuidString)", isDirectory: true)
        let store = try LocalTrackingStore(url: root.appendingPathComponent("tracking.sqlite"))
        defer { try? FileManager.default.removeItem(at: root) }
        let state = ACTACanvasFilterState()
        let bridge = ACTACanvasFilterBridge()
        bridge.attach(state)
        let revision = UUID()
        let action = ACTACanvasSetFilterAction(bridge: bridge, locationGroups: { [] },
                                               inventoryRevision: { revision })
        let scopes = ACTAAnalyticsCoordinator.localInspectionIDs
        let creation = await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], allowedInspectionIDs: scopes, audit: { _ in })
        let host = try XCTUnwrap(creation)
        let issued = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
            threadID: "test", actionIDs: [action.id], inspectionIDs: scopes)
        let session = try XCTUnwrap(issued)
        let script = BrokerModelScript()
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .mlxInProcess), transport: { _ in
            XCTFail("Unexpected network request")
            throw URLError(.notConnectedToInternet)
        }, keyProvider: { _ in XCTFail("Unexpected Keychain access"); return nil },
            localAgentInference: { prompt, _ in await script.reply(prompt) })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        _ = await coordinator.askACTAChatAgent(question: "Show favorites", threadID: "test",
                                               broker: host.broker, brokerSession: session)
        let prompts = await script.prompts
        let first = try XCTUnwrap(prompts.first)
        XCTAssertTrue(first.contains("acta__canvas__set_filter"))
        XCTAssertFalse(first.contains("acta__canvas__set_presentation"))
        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        XCTAssertEqual(reviews.count, 1)
        XCTAssertFalse(state.favoritesOnly)
        let review = try XCTUnwrap(reviews.first)
        let approved = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                 reviewed: review, approved: true)
        XCTAssertTrue(approved.success)
        XCTAssertTrue(approved.verified)
        XCTAssertTrue(state.favoritesOnly)
    }

    func testAnalysisSectionReviewShowsScheduleEffectAndRejectsChangedState() async throws {
        let state = ACTACanvasFilterState()
        let bridge = ACTACanvasFilterBridge()
        bridge.attach(state)
        let action = ACTAAnalysisSetSectionAction(bridge: bridge)
        let creation = await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let host = try XCTUnwrap(creation)
        let issued = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
                                                    threadID: "test", actionIDs: [action.id])
        let session = try XCTUnwrap(issued)
        let coordinator = ACTAAnalyticsCoordinator(aiClient: ACTAAIClient(
            config: ACTAAIConfiguration(mode: .dryRun), transport: { _ in
                XCTFail("Unexpected network request")
                throw URLError(.notConnectedToInternet)
            }))
        let name = "acta__analysis__set_section"
        let call = ACTAAgentFunctionCall(callID: "tab", name: name, argumentsJSON: #"{"section":"schedule"}"#)
        let pending = await coordinator.executeModelGeneratedAgentTool(call, threadID: "test",
            requestToolNames: [name], broker: host.broker, brokerSession: session)
        XCTAssertTrue(pending.outputJSON.contains("requires_operator_confirmation"))
        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let review = try XCTUnwrap(reviews.first)
        XCTAssertTrue(review.title.contains("Schedule refresh on appearance will be disabled"))
        state.analysisScheduleRefreshOnAppear = false
        let stale = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                              reviewed: review, approved: true)
        XCTAssertFalse(stale.success)
        XCTAssertEqual(state.analysisSection, .ask)
        state.analysisScheduleRefreshOnAppear = true
        _ = await coordinator.executeModelGeneratedAgentTool(call, threadID: "test",
            requestToolNames: [name], broker: host.broker, brokerSession: session)
        let nextReviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let next = try XCTUnwrap(nextReviews.first)
        let approved = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                 reviewed: next, approved: true)
        XCTAssertTrue(approved.success)
        XCTAssertTrue(approved.verified)
        XCTAssertEqual(state.analysisSection, .schedule)
        XCTAssertFalse(state.analysisScheduleRefreshOnAppear)
    }

    func testCameraSelectionReviewsResolvedIDsAndRejectsInventoryChanges() async throws {
        let state = ACTACanvasFilterState()
        let bridge = ACTACanvasFilterBridge()
        bridge.attach(state)
        let inventory = BrokerFilterInventory()
        let cameraID = UUID()
        inventory.cameraIDs = [cameraID]
        let action = ACTACanvasSelectCamerasAction(bridge: bridge, enabledCameraIDs: { inventory.cameraIDs },
                                                   inventoryRevision: { inventory.revision })
        let creation = await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let host = try XCTUnwrap(creation)
        let issued = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
                                                    threadID: "test", actionIDs: [action.id])
        let session = try XCTUnwrap(issued)
        let coordinator = ACTAAnalyticsCoordinator(aiClient: ACTAAIClient(
            config: ACTAAIConfiguration(mode: .dryRun), transport: { _ in
                XCTFail("Unexpected network request")
                throw URLError(.notConnectedToInternet)
            }))
        let name = "acta__canvas__select_cameras"
        let call = ACTAAgentFunctionCall(callID: "select", name: name, argumentsJSON: #"{"mode":"all"}"#)
        let result = await coordinator.executeModelGeneratedAgentTool(call, threadID: "test",
            requestToolNames: [name], broker: host.broker, brokerSession: session)
        XCTAssertTrue(result.outputJSON.contains("requires_operator_confirmation"))
        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let review = try XCTUnwrap(reviews.first)
        XCTAssertTrue(review.title.contains(cameraID.uuidString))
        inventory.cameraIDs.append(UUID())
        inventory.cameraIDs.removeLast()
        let stale = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                              reviewed: review, approved: true)
        XCTAssertFalse(stale.success)
        XCTAssertNil(state.selectedCameraIDs)
        _ = await coordinator.executeModelGeneratedAgentTool(call, threadID: "test",
            requestToolNames: [name], broker: host.broker, brokerSession: session)
        let nextReviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let next = try XCTUnwrap(nextReviews.first)
        let approved = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                 reviewed: next, approved: true)
        XCTAssertTrue(approved.success)
        XCTAssertTrue(approved.verified)
        XCTAssertEqual(state.selectedCameraIDs, Set(inventory.cameraIDs))
    }

    func testArrangeModelReviewRejectsChangedWindowAndFreshRequest() async throws {
        let state = ACTACanvasFilterState()
        let bridge = ACTACanvasFilterBridge()
        bridge.attach(state)
        let action = ACTACanvasSetArrangeModeAction(bridge: bridge)
        let creation = await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let host = try XCTUnwrap(creation)
        let issued = await host.broker.openSession(operatorKey: host.operatorKey, input: .voice,
                                                    threadID: "test", actionIDs: [action.id])
        let session = try XCTUnwrap(issued)
        let coordinator = ACTAAnalyticsCoordinator(aiClient: ACTAAIClient(
            config: ACTAAIConfiguration(mode: .dryRun), transport: { _ in
                XCTFail("Unexpected network request")
                throw URLError(.notConnectedToInternet)
            }))
        let name = "acta__canvas__set_arrange_mode"
        let call = ACTAAgentFunctionCall(callID: "arrange", name: name, argumentsJSON: #"{"enabled":true}"#)
        let pending = await coordinator.executeModelGeneratedAgentTool(call, threadID: "test",
            requestToolNames: [name], broker: host.broker, brokerSession: session)
        XCTAssertTrue(pending.outputJSON.contains("requires_operator_confirmation"))
        XCTAssertFalse(state.arrangeCameras)
        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let review = try XCTUnwrap(reviews.first)
        bridge.detach(state)
        bridge.attach(state)
        let stale = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                              reviewed: review, approved: true)
        XCTAssertFalse(stale.success)
        XCTAssertFalse(state.arrangeCameras)
        _ = await coordinator.executeModelGeneratedAgentTool(call, threadID: "test",
            requestToolNames: [name], broker: host.broker, brokerSession: session)
        let nextReviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let next = try XCTUnwrap(nextReviews.first)
        let approved = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                 reviewed: next, approved: true)
        XCTAssertTrue(approved.success)
        XCTAssertTrue(approved.verified)
        XCTAssertTrue(state.arrangeCameras)
    }

    func testFilterModelReviewBindsPreviousStateAndInventory() async throws {
        let state = ACTACanvasFilterState()
        state.searchText = "previous"
        let bridge = ACTACanvasFilterBridge()
        bridge.attach(state)
        let inventory = BrokerFilterInventory()
        let action = ACTACanvasSetFilterAction(bridge: bridge, locationGroups: { inventory.groups },
                                               inventoryRevision: { inventory.revision })
        let creation = await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let host = try XCTUnwrap(creation)
        let issued = await host.broker.openSession(
            operatorKey: host.operatorKey, input: .chat, threadID: "test", actionIDs: [action.id])
        let session = try XCTUnwrap(issued)
        let coordinator = ACTAAnalyticsCoordinator(aiClient: ACTAAIClient(
            config: ACTAAIConfiguration(mode: .dryRun), transport: { _ in
                XCTFail("Unexpected network request")
                throw URLError(.notConnectedToInternet)
            }))
        let name = "acta__canvas__set_filter"
        let call = ACTAAgentFunctionCall(callID: "filter", name: name,
            argumentsJSON: #"{"location":"Entrance","favorites_only":true}"#)
        let output = await coordinator.executeModelGeneratedAgentTool(call, threadID: "test",
            requestToolNames: [name], broker: host.broker, brokerSession: session)
        XCTAssertTrue(output.outputJSON.contains("requires_operator_confirmation"))
        XCTAssertFalse(output.outputJSON.contains("previous"))
        XCTAssertFalse(state.favoritesOnly)
        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let review = try XCTUnwrap(reviews.first)
        XCTAssertTrue(review.title.contains("previous"))
        inventory.groups.insert("Other")
        inventory.groups.remove("Other")
        let stale = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                              reviewed: review, approved: true)
        XCTAssertFalse(stale.success)
        XCTAssertFalse(state.favoritesOnly)
        XCTAssertNil(state.locationFilter)

        _ = await coordinator.executeModelGeneratedAgentTool(call, threadID: "test",
            requestToolNames: [name], broker: host.broker, brokerSession: session)
        let changedReviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let changed = try XCTUnwrap(changedReviews.first)
        state.searchText = "operator update"
        let staleState = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                   reviewed: changed, approved: true)
        XCTAssertFalse(staleState.success)
        XCTAssertFalse(state.favoritesOnly)
        XCTAssertNil(state.locationFilter)
        XCTAssertEqual(state.searchText, "operator update")

        _ = await coordinator.executeModelGeneratedAgentTool(call, threadID: "test",
            requestToolNames: [name], broker: host.broker, brokerSession: session)
        let freshReviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let fresh = try XCTUnwrap(freshReviews.first)
        let approved = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                 reviewed: fresh, approved: true)
        XCTAssertTrue(approved.success)
        XCTAssertTrue(approved.verified)
        XCTAssertTrue(state.favoritesOnly)
        XCTAssertEqual(state.locationFilter, "Entrance")
        XCTAssertEqual(state.searchText, "operator update")
    }

    func testProductionModelRouteRequiresExactReviewAndRejectsStaleWindow() async throws {
        let state = ACTACanvasFilterState()
        let bridge = ACTACanvasFilterBridge()
        bridge.attach(state)
        let action = ACTACanvasSetPresentationAction(bridge: bridge)
        let creation = await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let created = try XCTUnwrap(creation)
        let issued = await created.broker.openSession(
            operatorKey: created.operatorKey, input: .chat, threadID: "test", actionIDs: [action.id])
        let session = try XCTUnwrap(issued)
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .dryRun), transport: { _ in
            XCTFail("Unexpected network request")
            throw URLError(.notConnectedToInternet)
        })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client)
        let name = "acta__canvas__set_presentation"
        let call = ACTAAgentFunctionCall(callID: "one", name: name, argumentsJSON: #"{"mode":"list"}"#)
        let wrongThread = await coordinator.executeModelGeneratedAgentTool(call, threadID: "other",
            requestToolNames: [name], broker: created.broker, brokerSession: session)
        XCTAssertTrue(wrongThread.outputJSON.contains("UNAUTHORIZED:"))
        XCTAssertEqual(state.presentation, .grid)
        let output = await coordinator.executeModelGeneratedAgentTool(call, threadID: "test",
            requestToolNames: [name], broker: created.broker, brokerSession: session)
        XCTAssertTrue(output.outputJSON.contains("requires_operator_confirmation"))
        XCTAssertFalse(output.outputJSON.contains("CONFIRM-"))
        XCTAssertFalse(output.outputJSON.contains("Unique active security center"))
        XCTAssertEqual(state.presentation, .grid)
        let pending = await created.broker.reviews(operatorKey: created.operatorKey, session: session)
        let review = try XCTUnwrap(pending.first)
        let controller = ACTABrokerReviewController(broker: created.broker, operatorKey: created.operatorKey,
                                                    session: session, review: review)
        let premature = await controller.resolve(true)
        XCTAssertNil(premature)
        controller.reviewedAll = true
        let approved = await controller.resolve(true)
        XCTAssertEqual(approved?.success, true)
        XCTAssertEqual(approved?.verified, true)
        XCTAssertEqual(state.presentation, .list)
        let replay = await controller.resolve(true)
        XCTAssertEqual(replay?.success, false)

        let second = ACTAAgentFunctionCall(callID: "two", name: name, argumentsJSON: #"{"mode":"grid"}"#)
        _ = await coordinator.executeModelGeneratedAgentTool(second, threadID: "test",
            requestToolNames: [name], broker: created.broker, brokerSession: session)
        let secondReviews = await created.broker.reviews(operatorKey: created.operatorKey, session: session)
        let secondReview = try XCTUnwrap(secondReviews.first)
        bridge.detach(state)
        bridge.attach(state)
        let stale = await created.broker.resolve(operatorKey: created.operatorKey, session: session,
                                                 reviewed: secondReview, approved: true)
        XCTAssertFalse(stale.success)
        XCTAssertEqual(state.presentation, .list)
    }

    func testProductionRouteFailsClosedWhenApprovalAuditFails() async throws {
        let state = ACTACanvasFilterState()
        let bridge = ACTACanvasFilterBridge()
        bridge.attach(state)
        let action = ACTACanvasSetPresentationAction(bridge: bridge)
        let creation = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id]) { event in
            if case .review = event.phase { throw URLError(.cannotWriteToFile) }
        }
        let created = try XCTUnwrap(creation)
        let issued = await created.broker.openSession(operatorKey: created.operatorKey, input: .chat,
                                                       threadID: "test", actionIDs: [action.id])
        let session = try XCTUnwrap(issued)
        let coordinator = ACTAAnalyticsCoordinator(aiClient: ACTAAIClient(
            config: ACTAAIConfiguration(mode: .dryRun), transport: { _ in
                XCTFail("Unexpected network request")
                throw URLError(.notConnectedToInternet)
            }))
        let name = "acta__canvas__set_presentation"
        let call = ACTAAgentFunctionCall(callID: "audit", name: name, argumentsJSON: #"{"mode":"list"}"#)
        let result = await coordinator.executeModelGeneratedAgentTool(call, threadID: "test",
            requestToolNames: [name], broker: created.broker, brokerSession: session)
        XCTAssertTrue(result.outputJSON.contains("requires_operator_confirmation"))
        let reviews = await created.broker.reviews(operatorKey: created.operatorKey, session: session)
        let review = try XCTUnwrap(reviews.first)
        let rejected = await created.broker.resolve(operatorKey: created.operatorKey, session: session,
                                                    reviewed: review, approved: true)
        XCTAssertTrue(rejected.error?.hasPrefix("AUDIT_FAILED:") == true)
        XCTAssertEqual(state.presentation, .grid)
    }

    func testExactRenderingEscapesInvisibleAndDirectionalCharacters() {
        let value = "A\n\"\u{202e}Ж\\"
        XCTAssertEqual(ACTABrokerReviewRendering.exact(value), #""A\u{A}\"\u{202E}\u{416}\\""#)
        XCTAssertNotEqual(ACTABrokerReviewRendering.exact("é"),
                          ACTABrokerReviewRendering.exact("e\u{301}"))
    }

    func testControllerRequiresAcknowledgementAndResolvesOnce() async throws {
        let counter = BrokerReviewCounter()
        let action = BrokerReviewProbeAction(counter: counter)
        let creation = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let created = try XCTUnwrap(creation)
        let issued = await created.broker.openSession(operatorKey: created.operatorKey, input: .chat,
                                                       threadID: "test", actionIDs: [action.id])
        let session = try XCTUnwrap(issued)
        let request = await created.broker.request(session: session, actionID: action.id,
                                                   argumentsJSON: #"{"value":"full\u000atext"}"#)
        XCTAssertTrue(request.requiresOperatorConfirmation)
        XCTAssertNil(request.confirmationToken)
        let reviews = await created.broker.reviews(operatorKey: created.operatorKey, session: session)
        let review = try XCTUnwrap(reviews.first)
        let fields = ACTABrokerReviewRendering.parameters(review)
        XCTAssertEqual(fields.first?.0, #""value""#)
        XCTAssertEqual(fields.first?.1, #""full\u{A}text""#)
        let controller = ACTABrokerReviewController(broker: created.broker, operatorKey: created.operatorKey,
                                                    session: session, review: review)
        let premature = await controller.resolve(true)
        XCTAssertNil(premature)
        let before = await counter.count
        XCTAssertEqual(before, 0)
        controller.reviewedAll = true
        let approved = await controller.resolve(true)
        XCTAssertEqual(approved?.success, true)
        let replay = await controller.resolve(true)
        XCTAssertEqual(replay?.success, false)
        let after = await counter.count
        XCTAssertEqual(after, 1)

        _ = await created.broker.request(session: session, actionID: action.id,
                                         argumentsJSON: #"{"value":"reject"}"#)
        let pending = await created.broker.reviews(operatorKey: created.operatorKey, session: session)
        let rejectedController = ACTABrokerReviewController(broker: created.broker, operatorKey: created.operatorKey,
                                                            session: session, review: try XCTUnwrap(pending.first))
        let rejected = await rejectedController.resolve(false)
        XCTAssertEqual(rejected?.success, false)
        let finalCount = await counter.count
        XCTAssertEqual(finalCount, 1)
    }
}
