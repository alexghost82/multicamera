import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTACanvasSelectCamerasActionTests: XCTestCase {
    private struct CredentialsFake: CameraCredentialStore {
        func read(_ id: UUID) throws -> Credentials? { XCTFail("Unexpected credential access"); return nil }
        func save(_ credentials: Credentials, for id: UUID) throws { XCTFail("Unexpected credential access") }
        func remove(_ id: UUID) throws { XCTFail("Unexpected credential access") }
    }

    private final class Inventory {
        var ids: [UUID]?
        init(_ ids: [UUID]?) { self.ids = ids }
    }

    func testTypedActionsUpdateTheActualCanvasSelection() async throws {
        let a = UUID(), b = UUID(), disabled = UUID()
        let inventory = Inventory([a, b])
        let bridge = ACTACanvasFilterBridge()
        let state = ACTACanvasFilterState()
        state.searchText = "unchanged"
        state.locationFilter = "Lobby"
        bridge.attach(state)
        let registry = ACTAActionRegistry()
        await registry.register(ACTACanvasSelectCamerasAction(bridge: bridge, enabledCameraIDs: { inventory.ids }))
        let tools = try await ACTAAnalyticsCoordinator.registryTools(registry: registry)
        let tool = try XCTUnwrap(tools.first { $0.name == "acta__canvas__select_cameras" })
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(tool.parametersSchemaJSON.utf8)) as? [String: Any])
        let fields = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        XCTAssertEqual(fields["mode"]?["type"] as? String, "string")
        XCTAssertEqual(fields["camera_ids"]?["type"] as? String, "string")

        let all = try await registry.executeJSON(actionID: "canvas.select_cameras", argumentsJSON: #"{"mode":"all"}"#)
        XCTAssertTrue(all.success && all.verified, all.summary)
        XCTAssertEqual(state.selectedCameraIDs, [a, b])
        XCTAssertTrue(state.includesCamera(id: a))
        XCTAssertFalse(state.includesCamera(id: disabled))

        let subset = try await registry.executeJSON(actionID: "canvas.select_cameras",
            argumentsJSON: #"{"mode":"subset","camera_ids":"\#(b.uuidString)"}"#)
        XCTAssertTrue(subset.success && subset.verified, subset.summary)
        XCTAssertEqual(state.selectedCameraIDs, [b])
        XCTAssertFalse(state.includesCamera(id: a))
        XCTAssertTrue(state.includesCamera(id: b))
        XCTAssertEqual(state.searchText, "unchanged")
        XCTAssertEqual(state.locationFilter, "Lobby")

        let none = try await registry.executeJSON(actionID: "canvas.select_cameras", argumentsJSON: #"{"mode":"none"}"#)
        XCTAssertTrue(none.success && none.verified, none.summary)
        XCTAssertEqual(state.selectedCameraIDs, [])
        XCTAssertFalse(state.includesCamera(id: b))
        inventory.ids = []
        let emptyAll = try await registry.executeJSON(actionID: "canvas.select_cameras", argumentsJSON: #"{"mode":"all"}"#)
        XCTAssertTrue(emptyAll.success && emptyAll.verified, emptyAll.summary)
        XCTAssertEqual(state.selectedCameraIDs, [])
        inventory.ids = [a]
        XCTAssertFalse(state.includesCamera(id: a), "Select all is a snapshot, as in the GUI")
    }

    func testInvalidOrStaleIDsNeverChangeSelection() async throws {
        let a = UUID(), b = UUID()
        let inventory = Inventory([a])
        let bridge = ACTACanvasFilterBridge()
        let state = ACTACanvasFilterState()
        state.selectedCameraIDs = [a]
        bridge.attach(state)
        let registry = ACTAActionRegistry()
        await registry.register(ACTACanvasSelectCamerasAction(bridge: bridge, enabledCameraIDs: { inventory.ids }))
        let invalid = [
            "{}", #"{"mode":"all","camera_ids":"\#(a.uuidString)"}"#,
            #"{"mode":"none","camera_ids":""}"#, #"{"mode":"subset"}"#,
            #"{"mode":"subset","camera_ids":"\#(b.uuidString)"}"#,
            #"{"mode":"subset","camera_ids":"\#(a.uuidString),\#(a.uuidString)"}"#,
            #"{"mode":"subset","camera_ids":"\#(a.uuidString),"}"#,
            #"{"mode":"subset","camera_ids":["\#(a.uuidString)"]}"#,
            #"{"mode":"unknown"}"#
        ]
        for json in invalid {
            let result = try await registry.executeJSON(actionID: "canvas.select_cameras", argumentsJSON: json)
            XCTAssertFalse(result.success, json)
            XCTAssertFalse(result.verified, json)
            XCTAssertEqual(state.selectedCameraIDs, [a], json)
        }
        inventory.ids = [a, a]
        let duplicateInventory = try await registry.executeJSON(actionID: "canvas.select_cameras", argumentsJSON: #"{"mode":"all"}"#)
        XCTAssertFalse(duplicateInventory.success)
        XCTAssertEqual(state.selectedCameraIDs, [a])
    }

    func testVerificationDetectsInventoryAndWindowChangesAndGUIEdits() async throws {
        let a = UUID(), b = UUID()
        let inventory = Inventory([a, b])
        let bridge = ACTACanvasFilterBridge()
        let state = ACTACanvasFilterState(), other = ACTACanvasFilterState()
        let action = ACTACanvasSelectCamerasAction(bridge: bridge, enabledCameraIDs: { inventory.ids })
        let context = ACTAActionContext()
        let params = ["mode": "subset", "camera_ids": a.uuidString]
        let missing = try await action.execute(parameters: params, context: context)
        XCTAssertFalse(missing.success)
        bridge.attach(state)
        bridge.attach(other)
        let ambiguous = try await action.execute(parameters: params, context: context)
        XCTAssertFalse(ambiguous.success)
        XCTAssertNil(state.selectedCameraIDs)
        bridge.detach(other)
        let applied = try await action.execute(parameters: params, context: context)
        XCTAssertTrue(applied.success)
        let verified = try await action.verify(parameters: params, context: context)
        XCTAssertTrue(verified)
        bridge.attach(other)
        let secondWindow = try await action.verify(parameters: params, context: context)
        XCTAssertFalse(secondWindow)
        bridge.detach(other)
        let appliedAgain = try await action.execute(parameters: params, context: context)
        XCTAssertTrue(appliedAgain.success)
        state.selectedCameraIDs = [b]
        let edited = try await action.verify(parameters: params, context: context)
        XCTAssertFalse(edited)
        state.selectedCameraIDs = [a]
        inventory.ids = [a]
        let stale = try await action.verify(parameters: params, context: context)
        XCTAssertFalse(stale)
        inventory.ids = [a, b]
        bridge.detach(state)
        bridge.attach(other)
        other.selectedCameraIDs = [a]
        let replaced = try await action.verify(parameters: params, context: context)
        XCTAssertFalse(replaced)
        inventory.ids = nil
        let unavailable = try await action.execute(parameters: params, context: context)
        XCTAssertFalse(unavailable.success)
    }

    func testRegisteredActionUsesLiveModelEnabledIDs() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".canvas-selection-fixture-\(UUID().uuidString)", isDirectory: true)
        try IsolatedWallFixtureSupport.prepare(root)
        let model = WallModel(configURL: root.appendingPathComponent("cameras.json"),
            poseModelURL: root.appendingPathComponent("fake-pose.mlmodel"),
            trackingStoreURL: root.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: root.appendingPathComponent("features.json"),
                databaseURL: root.appendingPathComponent("features.sqlite")),
            analyticsDirectoryURL: root.appendingPathComponent("analytics"),
            agentClient: IsolatedWallFixtureSupport.client(),
            cameraMemoryStore: CameraMemoryStore(url: root.appendingPathComponent("frames")),
            operationsWatchURL: root.appendingPathComponent("watches.json"),
            missionStoreURL: root.appendingPathComponent("missions.json"),
            cameraCredentialStore: CredentialsFake(),
            operationsPreferencesURL: root.appendingPathComponent("operations.json"),
            alertClipStore: CriticalAlertClipStore(url: root.appendingPathComponent("clips")),
            languageSettings: LanguageSettings(storage: InMemoryLanguageStorage()),
            monitorHistoryURL: root.appendingPathComponent("monitor.json"),
            analyticsModelDiscovery: AnalyticsModelDiscovery(modelURL: { _ in nil },
                integrity: { _ in (hash: "synthetic", sizeBytes: 0) }))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        IsolatedWallFixtureSupport.assertSafe(model)
        let enabled = Camera(name: "synthetic enabled", location: " Lobby ", substream: "", enabled: true)
        let disabled = Camera(name: "synthetic disabled", location: "Disabled", substream: "", enabled: false)
        model.config.cameras = [enabled, disabled]
        let state = ACTACanvasFilterState()
        model.canvasFilterBridge.attach(state)
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)

        let tools = try await ACTAAnalyticsCoordinator.registryTools(registry: registry)
        XCTAssertTrue(tools.contains { $0.name == "acta__canvas__set_presentation" })
        let presentation = try await registry.executeJSON(actionID: "canvas.set_presentation", argumentsJSON: #"{"mode":"list"}"#)
        XCTAssertTrue(presentation.success && presentation.verified, presentation.summary)
        XCTAssertEqual(state.presentation, .list)

        let all = try await registry.executeJSON(actionID: "canvas.select_cameras", argumentsJSON: #"{"mode":"all"}"#)
        XCTAssertTrue(all.success && all.verified, all.summary)
        XCTAssertEqual(state.selectedCameraIDs, [enabled.id])
        let filter = try await registry.executeJSON(actionID: "canvas.set_filter", argumentsJSON: #"{"location":"Lobby"}"#)
        XCTAssertTrue(filter.success && filter.verified, filter.summary)
        XCTAssertEqual(state.locationFilter, "Lobby")
        let disabledLocation = try await registry.executeJSON(actionID: "canvas.set_filter", argumentsJSON: #"{"location":"Disabled"}"#)
        XCTAssertFalse(disabledLocation.success)
        XCTAssertEqual(state.locationFilter, "Lobby")
        let reject = try await registry.executeJSON(actionID: "canvas.select_cameras",
            argumentsJSON: #"{"mode":"subset","camera_ids":"\#(disabled.id.uuidString)"}"#)
        XCTAssertFalse(reject.success)
        XCTAssertEqual(state.selectedCameraIDs, [enabled.id])
        model.config.cameras[1].enabled = true
        let updated = try await registry.executeJSON(actionID: "canvas.select_cameras",
            argumentsJSON: #"{"mode":"subset","camera_ids":"\#(disabled.id.uuidString)"}"#)
        XCTAssertTrue(updated.success && updated.verified, updated.summary)
        XCTAssertEqual(state.selectedCameraIDs, [disabled.id])
    }
}
