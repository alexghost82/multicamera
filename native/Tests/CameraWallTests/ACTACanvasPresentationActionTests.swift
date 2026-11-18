import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTACanvasPresentationActionTests: XCTestCase {
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
