import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTACanvasArrangeActionTests: XCTestCase {
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
