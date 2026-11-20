import CameraCore
import Combine
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTACanvasPresentationActionTests: XCTestCase {
    func testPresentationStillPublishesBeforeItsStateChanges() {
        let state = ACTACanvasFilterState()
        var observed: [String] = []
        let changes = state.objectWillChange.sink { observed.append("will:\(state.presentation.rawValue)") }
        state.presentation = .list
        XCTAssertEqual(observed, ["will:grid"])
        XCTAssertEqual(state.presentation, .list)
        withExtendedLifetime(changes) {}
    }

    func testReviewedPresentationCommitsAndRejectsReentrantInvalidation() async throws {
        for invalidate in [false, true] {
            let bridge = ACTACanvasFilterBridge()
            let state = ACTACanvasFilterState()
            bridge.attach(state)
            let action = ACTACanvasSetPresentationAction(bridge: bridge)
            let parameters = ["mode": "list"]
            let context = ACTAActionContext(isConfirmed: true)
            let review = try await action.prepareConfirmation(parameters: parameters, context: context)
            var observed: [ACTACameraPresentation] = []
            let changes = state.objectWillChange.sink {
                observed.append(state.presentation)
                if invalidate { bridge.detach(state); bridge.attach(state) }
            }
            let result = try await action.executeConfirmed(parameters: parameters, context: context, snapshot: review.snapshot)
            XCTAssertEqual(result.success, !invalidate)
            XCTAssertEqual(state.presentation, invalidate ? .grid : .list)
            XCTAssertEqual(observed, [.grid])
            let verified = try await action.verify(parameters: parameters, context: context)
            XCTAssertEqual(verified, !invalidate)
            withExtendedLifetime(changes) {}
        }
    }

    func testPublishedFilterStillNotifiesObjectWillChange() {
        let state = ACTACanvasFilterState()
        var changes = 0
        let subscription = state.objectWillChange.sink { changes += 1 }
        state.searchText = "lobby"
        XCTAssertEqual(changes, 1)
        withExtendedLifetime(subscription) {}
    }

    func testInventoryActionsCannotPrepareWithoutRevision() async {
        let bridge = ACTACanvasFilterBridge()
        let state = ACTACanvasFilterState()
        bridge.attach(state)
        let context = ACTAActionContext(isConfirmed: true)
        let filter = ACTACanvasSetFilterAction(bridge: bridge, locationGroups: { [] })
        let selection = ACTACanvasSelectCamerasAction(bridge: bridge, enabledCameraIDs: { [] })
        do {
            _ = try await filter.prepareConfirmation(parameters: ["search": "gate"], context: context)
            XCTFail("Unversioned inventory must not be approved")
        } catch { XCTAssertTrue(error.localizedDescription.contains("UNAVAILABLE")) }
        do {
            _ = try await selection.prepareConfirmation(parameters: ["mode": "all"], context: context)
            XCTFail("Unversioned inventory must not be approved")
        } catch { XCTAssertTrue(error.localizedDescription.contains("UNAVAILABLE")) }
        XCTAssertEqual(state.searchText, "")
        XCTAssertNil(state.selectedCameraIDs)
    }

    func testBrokerRejectsReviewedPresentationAfterABAChange() async throws {
        let bridge = ACTACanvasFilterBridge()
        let state = ACTACanvasFilterState()
        bridge.attach(state)
        let action = ACTACanvasSetPresentationAction(bridge: bridge)
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let host = try XCTUnwrap(made)
        let issued = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
            threadID: "fixture", actionIDs: [action.id])
        let session = try XCTUnwrap(issued)
        let request = await host.broker.request(session: session, actionID: action.id, argumentsJSON: #"{"mode":"list"}"#)
        XCTAssertTrue(request.requiresOperatorConfirmation)
        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let review = try XCTUnwrap(reviews.first)
        state.presentation = .list
        state.presentation = .grid
        let result = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                               reviewed: review, approved: true)
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.hasPrefix("STALE_REVIEW:") == true)
        XCTAssertEqual(state.presentation, .grid)
        await host.broker.closeSession(session, operatorKey: host.operatorKey)
    }

    func testReviewedWindowActionsRejectInterveningABAEdits() async throws {
        let bridge = ACTACanvasFilterBridge()
        let state = ACTACanvasFilterState()
        let cameraID = UUID()
        bridge.attach(state)
        let context = ACTAActionContext(isConfirmed: true)

        let presentation = ACTACanvasSetPresentationAction(bridge: bridge)
        let presentationReview = try await presentation.prepareConfirmation(parameters: ["mode": "list"], context: context)
        state.presentation = .list
        state.presentation = .grid
        let presentationResult = try await presentation.executeConfirmed(parameters: ["mode": "list"], context: context,
                                                                           snapshot: presentationReview.snapshot)
        XCTAssertFalse(presentationResult.success)
        XCTAssertEqual(state.presentation, .grid)

        let arrange = ACTACanvasSetArrangeModeAction(bridge: bridge)
        let arrangeReview = try await arrange.prepareConfirmation(parameters: ["enabled": "true"], context: context)
        state.arrangeCameras = true
        state.arrangeCameras = false
        let arrangeResult = try await arrange.executeConfirmed(parameters: ["enabled": "true"], context: context,
                                                               snapshot: arrangeReview.snapshot)
        XCTAssertFalse(arrangeResult.success)
        XCTAssertFalse(state.arrangeCameras)

        let analysis = ACTAAnalysisSetSectionAction(bridge: bridge)
        let analysisReview = try await analysis.prepareConfirmation(parameters: ["section": "alerts"], context: context)
        state.analysisSection = .alerts
        state.analysisSection = .ask
        let analysisResult = try await analysis.executeConfirmed(parameters: ["section": "alerts"], context: context,
                                                                 snapshot: analysisReview.snapshot)
        XCTAssertFalse(analysisResult.success)
        XCTAssertEqual(state.analysisSection, .ask)

        let inventoryRevision = UUID()
        let filter = ACTACanvasSetFilterAction(bridge: bridge, locationGroups: { [] },
                                               inventoryRevision: { inventoryRevision })
        let filterReview = try await filter.prepareConfirmation(parameters: ["search": "gate"], context: context)
        state.searchText = "intervening"
        state.searchText = ""
        let filterResult = try await filter.executeConfirmed(parameters: ["search": "gate"], context: context,
                                                             snapshot: filterReview.snapshot)
        XCTAssertFalse(filterResult.success)
        XCTAssertEqual(state.searchText, "")

        let selection = ACTACanvasSelectCamerasAction(bridge: bridge, enabledCameraIDs: { [cameraID] },
                                                       inventoryRevision: { inventoryRevision })
        let selectionReview = try await selection.prepareConfirmation(parameters: ["mode": "all"], context: context)
        state.selectedCameraIDs = [cameraID]
        state.selectedCameraIDs = nil
        let selectionResult = try await selection.executeConfirmed(parameters: ["mode": "all"], context: context,
                                                                   snapshot: selectionReview.snapshot)
        XCTAssertFalse(selectionResult.success)
        XCTAssertNil(state.selectedCameraIDs)
    }

    func testTypedActionAndCataloguePreserveOtherState() async throws {
        let bridge = ACTACanvasFilterBridge()
        let state = ACTACanvasFilterState()
        let selected = UUID()
        state.searchText = "lobby"
        state.locationFilter = "Lobby"
        state.cameraScope = .offline
        state.favoritesOnly = true
        state.alertsOnly = true
        state.selectedCameraIDs = [selected]
        state.arrangeCameras = true
        bridge.attach(state)
        let registry = ACTAActionRegistry()
        await registry.register(ACTACanvasSetPresentationAction(bridge: bridge))
        let tools = try await ACTAAnalyticsCoordinator.registryTools(registry: registry)
        let tool = try XCTUnwrap(tools.first { $0.name == "acta__canvas__set_presentation" })
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(tool.parametersSchemaJSON.utf8)) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        XCTAssertEqual(properties["mode"]?["type"] as? String, "string")
        XCTAssertEqual(properties["mode"]?["enum"] as? [String], ["grid", "list"])
        XCTAssertEqual(schema["required"] as? [String], ["mode"])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)

        for mode in ["list", "list", "grid"] {
            let result = try await registry.executeJSON(actionID: "canvas.set_presentation", argumentsJSON: #"{"mode":"\#(mode)"}"#)
            XCTAssertTrue(result.success && result.verified, result.summary)
            XCTAssertEqual(state.presentation.rawValue, mode)
            XCTAssertEqual(state.searchText, "lobby")
            XCTAssertEqual(state.locationFilter, "Lobby")
            XCTAssertEqual(state.cameraScope, .offline)
            XCTAssertTrue(state.favoritesOnly)
            XCTAssertTrue(state.alertsOnly)
            XCTAssertEqual(state.selectedCameraIDs, [selected])
            XCTAssertTrue(state.arrangeCameras)
        }
    }

    func testInvalidArgumentsAndWindowAvailability() async throws {
        let bridge = ACTACanvasFilterBridge()
        let state = ACTACanvasFilterState(), other = ACTACanvasFilterState()
        let registry = ACTAActionRegistry()
        await registry.register(ACTACanvasSetPresentationAction(bridge: bridge))
        let missing = try await registry.executeJSON(actionID: "canvas.set_presentation", argumentsJSON: #"{"mode":"list"}"#)
        XCTAssertFalse(missing.success)
        bridge.attach(state)
        for json in ["{}", #"{"mode":"fullscreen"}"#, #"{"mode":"List"}"#, #"{"mode":true}"#,
                     #"{"mode":1}"#, #"{"mode":null}"#, #"{"mode":["list"]}"#,
                     #"{"mode":"list","other":true}"#] {
            let result = try await registry.executeJSON(actionID: "canvas.set_presentation", argumentsJSON: json)
            XCTAssertFalse(result.success, json)
            XCTAssertFalse(result.verified, json)
            XCTAssertEqual(state.presentation, .grid, json)
        }
        bridge.attach(other)
        let ambiguous = try await registry.executeJSON(actionID: "canvas.set_presentation", argumentsJSON: #"{"mode":"list"}"#)
        XCTAssertFalse(ambiguous.success)
        XCTAssertEqual(state.presentation, .grid)
        XCTAssertEqual(other.presentation, .grid)
    }

    func testVerificationDetectsEditsAndWindowReplacement() async throws {
        let bridge = ACTACanvasFilterBridge()
        let state = ACTACanvasFilterState(), other = ACTACanvasFilterState()
        let action = ACTACanvasSetPresentationAction(bridge: bridge)
        let parameters = ["mode": "list"]
        let context = ACTAActionContext()
        bridge.attach(state)
        let applied = try await action.execute(parameters: parameters, context: context)
        XCTAssertTrue(applied.success)
        let verified = try await action.verify(parameters: parameters, context: context)
        XCTAssertTrue(verified)
        state.presentation = .grid
        let edited = try await action.verify(parameters: parameters, context: context)
        XCTAssertFalse(edited)
        state.presentation = .list
        bridge.attach(other)
        let ambiguous = try await action.verify(parameters: parameters, context: context)
        XCTAssertFalse(ambiguous)
        bridge.detach(state)
        other.presentation = .list
        let replaced = try await action.verify(parameters: parameters, context: context)
        XCTAssertFalse(replaced)
        bridge.detach(other)
        bridge.attach(state)
        let reattached = try await action.verify(parameters: parameters, context: context)
        XCTAssertFalse(reattached)
    }
}
