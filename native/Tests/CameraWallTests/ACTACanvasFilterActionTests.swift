import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
private final class CanvasLocationInventory {
    var groups: Set<String>? = ["Entrance", "Other"]
}

@MainActor
final class ACTACanvasFilterActionTests: XCTestCase {
    func testSharedStatePatchAndTypedTransport() async throws {
        let bridge = ACTACanvasFilterBridge()
        let state = ACTACanvasFilterState()
        state.locationFilter = "Entrance"
        state.searchText = "previous"
        bridge.attach(state)
        let registry = ACTAActionRegistry()
        await registry.register(ACTACanvasSetFilterAction(bridge: bridge, locationGroups: { ["Entrance", "Other"] }))
        let tools = try await ACTAAnalyticsCoordinator.registryTools(registry: registry)
        let tool = try XCTUnwrap(tools.first { $0.name == "acta__canvas__set_filter" })
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(tool.parametersSchemaJSON.utf8)) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        XCTAssertEqual(properties["favorites_only"]?["type"] as? String, "boolean")
        XCTAssertEqual(properties["location"]?["type"] as? String, "string")

        let result = try await registry.executeJSON(actionID: "canvas.set_filter",
            argumentsJSON: #"{"search":"","status":"offline","favorites_only":true,"events_only":true}"#)
        XCTAssertTrue(result.success, result.summary)
        XCTAssertTrue(result.verified)
        XCTAssertEqual(state.searchText, "")
        XCTAssertEqual(state.cameraScope, .offline)
        XCTAssertTrue(state.favoritesOnly)
        XCTAssertTrue(state.alertsOnly)
        XCTAssertEqual(state.locationFilter, "Entrance")

        state.searchText = "GUI edit"
        state.favoritesOnly = false
        let partial = try await registry.executeJSON(actionID: "canvas.set_filter", argumentsJSON: #"{"status":"live"}"#)
        XCTAssertTrue(partial.success, partial.summary)
        XCTAssertEqual(state.searchText, "GUI edit")
        XCTAssertFalse(state.favoritesOnly)
        XCTAssertTrue(state.alertsOnly)
        XCTAssertEqual(state.cameraScope, .live)
    }

    func testInvalidRequestsNeverMutate() async throws {
        let bridge = ACTACanvasFilterBridge()
        let state = ACTACanvasFilterState()
        bridge.attach(state)
        let registry = ACTAActionRegistry()
        await registry.register(ACTACanvasSetFilterAction(bridge: bridge, locationGroups: { ["Entrance"] }))
        for json in ["{}", #"{"status":"unknown"}"#, #"{"favorites_only":"true"}"#,
                     #"{"events_only":1}"#, #"{"location":"Unknown"}"#, #"{"location":"All Locations"}"#,
                     #"{"search":"ok","events_only":null}"#] {
            let result = try await registry.executeJSON(actionID: "canvas.set_filter", argumentsJSON: json)
            XCTAssertFalse(result.success, json)
            XCTAssertFalse(result.verified, json)
        }
        let tooLong = try await registry.execute(actionID: "canvas.set_filter",
            parameters: ["search": String(repeating: "a", count: 4097), "status": "live"])
        XCTAssertFalse(tooLong.success)
        XCTAssertEqual(state.searchText, "")
        XCTAssertEqual(state.cameraScope, .all)
        XCTAssertFalse(state.favoritesOnly)
        XCTAssertFalse(state.alertsOnly)
    }

    func testUnavailableViewsAndVerificationAfterGUIChanges() async throws {
        let bridge = ACTACanvasFilterBridge()
        let action = ACTACanvasSetFilterAction(bridge: bridge, locationGroups: { ["Entrance"] })
        let context = ACTAActionContext()
        let params = ["search": "gate"]
        let missing = try await action.execute(parameters: params, context: context)
        XCTAssertFalse(missing.success)
        let first = ACTACanvasFilterState()
        let second = ACTACanvasFilterState()
        bridge.attach(first)
        bridge.attach(second)
        let ambiguous = try await action.execute(parameters: params, context: context)
        XCTAssertFalse(ambiguous.success)
        XCTAssertEqual(first.searchText, "")
        XCTAssertEqual(second.searchText, "")
        bridge.detach(second)
        let applied = try await action.execute(parameters: params, context: context)
        XCTAssertTrue(applied.success)
        let verified = try await action.verify(parameters: params, context: context)
        XCTAssertTrue(verified)
        first.searchText = "changed by GUI"
        let changed = try await action.verify(parameters: params, context: context)
        XCTAssertFalse(changed)
        first.searchText = "gate"
        bridge.detach(first)
        bridge.attach(second)
        second.searchText = "gate"
        let replaced = try await action.verify(parameters: params, context: context)
        XCTAssertFalse(replaced)
    }

    func testLocationUpdatesAndRejectsStaleInventoryBeforeMutating() async throws {
        let bridge = ACTACanvasFilterBridge()
        let state = ACTACanvasFilterState()
        let inventory = CanvasLocationInventory()
        bridge.attach(state)
        let action = ACTACanvasSetFilterAction(bridge: bridge, locationGroups: { inventory.groups })
        let context = ACTAActionContext()
        let selected = ["location": "Other"]
        let applied = try await action.execute(parameters: selected, context: context)
        XCTAssertTrue(applied.success)
        XCTAssertTrue(state.includes(name: "Entrance", location: nil, stale: false, favorite: false, hasEvents: false))
        XCTAssertTrue(state.includes(name: "Entrance", location: "Other", stale: false, favorite: false, hasEvents: false))
        XCTAssertFalse(state.includes(name: "Entrance", location: "Entrance", stale: false, favorite: false, hasEvents: false))
        let verified = try await action.verify(parameters: selected, context: context)
        XCTAssertTrue(verified)
        inventory.groups = ["Entrance"]
        let stale = try await action.verify(parameters: selected, context: context)
        XCTAssertFalse(stale)
        let rejected = try await action.execute(parameters: ["location": "Other", "search": "changed"], context: context)
        XCTAssertFalse(rejected.success)
        XCTAssertEqual(state.searchText, "")
        XCTAssertEqual(state.locationFilter, "Other")
        inventory.groups = nil
        let unavailable = try await action.execute(parameters: ["location": "Entrance"], context: context)
        XCTAssertFalse(unavailable.success)
        let cleared = try await action.execute(parameters: ["location": ""], context: context)
        XCTAssertTrue(cleared.success)
        XCTAssertNil(state.locationFilter)
        let clearVerified = try await action.verify(parameters: ["location": ""], context: context)
        XCTAssertTrue(clearVerified)
    }

    func testAppliedFiltersDriveSamePredicateAsCanvas() async throws {
        let bridge = ACTACanvasFilterBridge()
        let state = ACTACanvasFilterState()
        bridge.attach(state)
        let action = ACTACanvasSetFilterAction(bridge: bridge, locationGroups: { ["Other", "GATE"] })
        let applied = try await action.execute(parameters: [
            "search": "gate", "status": "live", "favorites_only": "true", "events_only": "true"
        ], context: ACTAActionContext())
        XCTAssertTrue(applied.success)
        XCTAssertTrue(state.includes(name: "Entrance", location: "GATE", stale: false, favorite: true, hasEvents: true))
        XCTAssertFalse(state.includes(name: "Entrance", location: "GATE", stale: nil, favorite: true, hasEvents: true))
        XCTAssertFalse(state.includes(name: "Entrance", location: "GATE", stale: false, favorite: false, hasEvents: true))
        XCTAssertFalse(state.includes(name: "Entrance", location: "GATE", stale: false, favorite: true, hasEvents: false))
        XCTAssertFalse(state.includes(name: "Entrance", location: "Lobby", stale: false, favorite: true, hasEvents: true))
        state.locationFilter = "Other"
        state.searchText = ""
        XCTAssertTrue(state.includes(name: "Entrance", location: " ", stale: false, favorite: true, hasEvents: true))
        XCTAssertFalse(state.includes(name: "Entrance", location: "GATE", stale: false, favorite: true, hasEvents: true))
        state.cameraScope = .offline
        XCTAssertTrue(state.includes(name: "Entrance", location: nil, stale: nil, favorite: true, hasEvents: true))
    }
}
