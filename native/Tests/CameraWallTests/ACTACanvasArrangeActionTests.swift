import CameraCore
import Combine
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTACanvasArrangeActionTests: XCTestCase {
    func testArrangeStillPublishesBeforeItsStateChanges() {
        let state = ACTACanvasFilterState()
        var observed: [String] = []
        let changes = state.objectWillChange.sink { observed.append("will:\(state.arrangeCameras)") }
        state.arrangeCameras = true
        XCTAssertEqual(observed, ["will:false"])
        XCTAssertTrue(state.arrangeCameras)
        withExtendedLifetime(changes) {}
    }

    func testReviewedArrangeCommitsAndRejectsReentrantABA() async throws {
        for invalidate in [false, true] {
            let bridge = ACTACanvasFilterBridge()
            let state = ACTACanvasFilterState()
            bridge.attach(state)
            let action = ACTACanvasSetArrangeModeAction(bridge: bridge)
            let parameters = ["enabled": "true"]
            let context = ACTAActionContext(isConfirmed: true)
            let review = try await action.prepareConfirmation(parameters: parameters, context: context)
            var changed = false
            let changes = state.objectWillChange.sink {
                if invalidate && !changed {
                    changed = true
                    state.arrangeCameras = true
                    state.arrangeCameras = false
                }
            }
            let result = try await action.executeConfirmed(parameters: parameters, context: context, snapshot: review.snapshot)
            XCTAssertEqual(result.success, !invalidate)
            XCTAssertEqual(state.arrangeCameras, !invalidate)
            let verified = try await action.verify(parameters: parameters, context: context)
            XCTAssertEqual(verified, !invalidate)
            withExtendedLifetime(changes) {}
        }
    }

    func testReviewedArrangeRejectsChangedRequestAndReplay() async throws {
        let bridge = ACTACanvasFilterBridge()
        let state = ACTACanvasFilterState()
        bridge.attach(state)
        let action = ACTACanvasSetArrangeModeAction(bridge: bridge)
        let context = ACTAActionContext(threadID: "one", isConfirmed: true)
        let parameters = ["enabled": "true"]
        let review = try await action.prepareConfirmation(parameters: parameters, context: context)
        let changed = try await action.executeConfirmed(parameters: ["enabled": "false"], context: context,
                                                        snapshot: review.snapshot)
        XCTAssertFalse(changed.success)
        let wrongThread = try await action.executeConfirmed(parameters: parameters,
            context: ACTAActionContext(threadID: "two", isConfirmed: true), snapshot: review.snapshot)
        XCTAssertFalse(wrongThread.success)
        XCTAssertFalse(state.arrangeCameras)
        let applied = try await action.executeConfirmed(parameters: parameters, context: context,
                                                        snapshot: review.snapshot)
        XCTAssertTrue(applied.success)
        let replayed = try await action.executeConfirmed(parameters: parameters, context: context,
                                                         snapshot: review.snapshot)
        XCTAssertFalse(replayed.success)
        XCTAssertTrue(state.arrangeCameras)
        let verified = try await action.verify(parameters: parameters, context: context)
        XCTAssertFalse(verified)
    }

    func testTypedActionUpdatesGUIStateWithoutChangingFilters() async throws {
        let bridge = ACTACanvasFilterBridge()
        let state = ACTACanvasFilterState()
        state.searchText = "lobby"
        let selected = UUID()
        state.selectedCameraIDs = [selected]
        bridge.attach(state)
        let registry = ACTAActionRegistry()
        await registry.register(ACTACanvasSetArrangeModeAction(bridge: bridge))
        let tools = try await ACTAAnalyticsCoordinator.registryTools(registry: registry)
        let tool = try XCTUnwrap(tools.first { $0.name == "acta__canvas__set_arrange_mode" })
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(tool.parametersSchemaJSON.utf8)) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        XCTAssertEqual(properties["enabled"]?["type"] as? String, "boolean")

        let enabled = try await registry.executeJSON(actionID: "canvas.set_arrange_mode", argumentsJSON: #"{"enabled":true}"#)
        XCTAssertTrue(enabled.success && enabled.verified, enabled.summary)
        XCTAssertTrue(state.arrangeCameras)
        XCTAssertEqual(state.searchText, "lobby")
        XCTAssertEqual(state.selectedCameraIDs, [selected])
        let disabled = try await registry.executeJSON(actionID: "canvas.set_arrange_mode", argumentsJSON: #"{"enabled":false}"#)
        XCTAssertTrue(disabled.success && disabled.verified, disabled.summary)
        XCTAssertFalse(state.arrangeCameras)
    }

    func testInvalidArgumentsAndAmbiguousWindowDoNotMutate() async throws {
        let bridge = ACTACanvasFilterBridge()
        let state = ACTACanvasFilterState()
        bridge.attach(state)
        let registry = ACTAActionRegistry()
        await registry.register(ACTACanvasSetArrangeModeAction(bridge: bridge))
        for json in ["{}", #"{"enabled":"true"}"#, #"{"enabled":1}"#,
                     #"{"enabled":true,"other":false}"#] {
            let result = try await registry.executeJSON(actionID: "canvas.set_arrange_mode", argumentsJSON: json)
            XCTAssertFalse(result.success, json)
            XCTAssertFalse(state.arrangeCameras, json)
        }
        let other = ACTACanvasFilterState()
        bridge.attach(other)
        let ambiguous = try await registry.executeJSON(actionID: "canvas.set_arrange_mode", argumentsJSON: #"{"enabled":true}"#)
        XCTAssertFalse(ambiguous.success)
        XCTAssertFalse(state.arrangeCameras)
        XCTAssertFalse(other.arrangeCameras)
        bridge.detach(other)
        bridge.detach(state)
        let missing = try await registry.executeJSON(actionID: "canvas.set_arrange_mode", argumentsJSON: #"{"enabled":true}"#)
        XCTAssertFalse(missing.success)
    }

    func testVerificationRejectsGUIEditsAndWindowReplacement() async throws {
        let bridge = ACTACanvasFilterBridge()
        let state = ACTACanvasFilterState()
        let other = ACTACanvasFilterState()
        let action = ACTACanvasSetArrangeModeAction(bridge: bridge)
        let params = ["enabled": "true"]
        let context = ACTAActionContext()
        bridge.attach(state)
        let applied = try await action.execute(parameters: params, context: context)
        XCTAssertTrue(applied.success)
        let verified = try await action.verify(parameters: params, context: context)
        XCTAssertTrue(verified)
        state.arrangeCameras = false
        let edited = try await action.verify(parameters: params, context: context)
        XCTAssertFalse(edited)
        state.arrangeCameras = true
        bridge.attach(other)
        let ambiguous = try await action.verify(parameters: params, context: context)
        XCTAssertFalse(ambiguous)
        bridge.detach(state)
        other.arrangeCameras = true
        let replaced = try await action.verify(parameters: params, context: context)
        XCTAssertFalse(replaced)
    }
}
