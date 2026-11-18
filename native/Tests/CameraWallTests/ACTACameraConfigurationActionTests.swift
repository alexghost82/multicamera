import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTACameraConfigurationActionTests: XCTestCase {
    private func fixture() throws -> (URL, WallModel, TestCameraCredentials, Camera) {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".camera-action-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let camera = Camera(name: "Entrance", location: "Old location", substream: "rtsp://127.0.0.1/original?channel=1", enabled: false)
        var config = WallConfiguration()
        config.cameras = [camera]
        try ConfigurationStore.save(config, to: root.appendingPathComponent("cameras.json"))
        try ModelSelectionPreferences(enabled: []).save(to: root.appendingPathComponent("model-preferences.json"))
        try CameraFeaturePreferencesStore.save(CameraFeaturePreferences(), to: root.appendingPathComponent("features.json"))
        let credentials = TestCameraCredentials()
        credentials.values[camera.id] = Credentials(username: "fixture", password: "fixture-secret")
        let poseURL = root.appendingPathComponent("unused-pose.mlmodel")
        let model = WallModel(configURL: root.appendingPathComponent("cameras.json"),
            workerMode: false, poseModelURL: poseURL,
            trackingStoreURL: root.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: root.appendingPathComponent("features.json"), databaseURL: root.appendingPathComponent("features.sqlite")),
            analyticsDirectoryURL: root.appendingPathComponent("analytics"),
            agentClient: IsolatedWallFixtureSupport.client(),
            cameraMemoryStore: CameraMemoryStore(url: root.appendingPathComponent("frames")),
            operationsWatchURL: root.appendingPathComponent("watches.json"), missionStoreURL: root.appendingPathComponent("missions.json"),
            cameraCredentialStore: credentials,
            operationsPreferencesURL: root.appendingPathComponent("operations.json"),
            alertClipStore: CriticalAlertClipStore(url: root.appendingPathComponent("clips")),
            languageSettings: LanguageSettings(storage: InMemoryLanguageStorage()),
            monitorHistoryURL: root.appendingPathComponent("monitor.json"),
            analyticsModelDiscovery: AnalyticsModelDiscovery(modelURL: { _ in nil }, integrity: { url in
                XCTAssertEqual(url, poseURL)
                return (hash: "synthetic", sizeBytes: 0)
            }))
        XCTAssertFalse(model.running)
        XCTAssertNil(model.tiles[camera.id]?.session)
        XCTAssertFalse(model.featurePreferences.enabledFeatures.contains(.independentWatcher))
        XCTAssertTrue(LocalModelService.allCases.allSatisfy { !ModelSelectionRegistry.isEnabled($0) })
        return (root, model, credentials, camera)
    }

    func testDisabledSourceRegistrationAndInspectionDoNotStartCaptureOrWriteCredentials() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, credentials, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let file = root.appendingPathComponent("fixture.mp4")
        try Data([1,2,3]).write(to: file)
        for (id, arguments) in [
            ("camera.add_network", ["name": "Anonymous", "url": "rtsp://127.0.0.1/other"]),
            ("camera.add_local", ["name": "Local", "device_id": "fixture-device"]),
            ("camera.add_screen", ["name": "Display", "display_id": "42"]),
            ("camera.add_file", ["file_path": file.path, "name": "Video"])
        ] {
            let result = try await registry.execute(actionID: id, parameters: arguments)
            XCTAssertTrue(result.success, result.summary)
            let output = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
            XCTAssertEqual(output["configured"] as? Bool, true)
            XCTAssertEqual(output["enabled"] as? Bool, false)
            XCTAssertEqual(output["connection_verified"] as? Bool, false)
            XCTAssertFalse(model.running)
        }
        let saved = try ConfigurationStore.load(from: model.configURL)
        XCTAssertEqual(saved.cameras.count, 5)
        XCTAssertTrue(saved.cameras.allSatisfy { !$0.enabled })
        XCTAssertEqual(credentials.saveCount, 0)
        XCTAssertEqual(credentials.removeCount, 0)
        let list = try await registry.execute(actionID: "camera.list", parameters: [:])
        XCTAssertTrue(list.success)
        XCTAssertTrue(list.outputJSON.contains("local_usb"))
        XCTAssertFalse(list.outputJSON.contains("fixture-secret"))
        XCTAssertFalse(list.outputJSON.contains("channel=1"))
        let disabledFiltered = try await registry.execute(actionID: "camera.list", parameters: ["include_disabled": "false"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(disabledFiltered.outputJSON.utf8)) as? [String: Any])
        XCTAssertEqual((object["cameras"] as? [Any])?.count, 0)
        let local = try XCTUnwrap(saved.cameras.first { $0.localDeviceID != nil })
        let details = try await registry.execute(actionID: "camera.get", parameters: ["camera_id": local.id.uuidString])
        XCTAssertTrue(details.outputJSON.contains("fixture-device"))
    }

    func testMetadataProcessingAndURLChangesPreserveCredentialAndSourceIdentity() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, credentials, camera) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let renamed = try await registry.execute(actionID: "camera.edit", parameters: ["camera_id": camera.id.uuidString, "name": "Renamed", "clear_location": "true"])
        XCTAssertTrue(renamed.success, renamed.summary)
        var saved = try XCTUnwrap(ConfigurationStore.load(from: model.configURL).cameras.first)
        XCTAssertEqual(saved.id, camera.id)
        XCTAssertEqual(saved.name, "Renamed")
        XCTAssertNil(saved.location)
        XCTAssertEqual(saved.substream, camera.substream)
        let yolo = try await registry.execute(actionID: "camera.set_processing", parameters: ["camera_id": camera.id.uuidString, "feature": "yolo", "enabled": "true"])
        XCTAssertTrue(yolo.success)
        XCTAssertTrue(try ConfigurationStore.load(from: model.configURL).cameras[0].yoloEnabled)
        let ai = try await registry.execute(actionID: "camera.set_processing", parameters: ["camera_id": camera.id.uuidString, "feature": "ai_chat", "enabled": "false"])
        XCTAssertTrue(ai.requiresOperatorConfirmation)
        let approved = try await registry.confirmAndExecute(token: XCTUnwrap(ai.confirmationToken), confirmed: true)
        XCTAssertTrue(approved.success)
        let url = try await registry.execute(actionID: "camera.edit", parameters: ["camera_id": camera.id.uuidString, "url": "rtsp://127.0.0.1/new"])
        XCTAssertTrue(url.requiresOperatorConfirmation)
        XCTAssertEqual(model.config.cameras[0].substream, camera.substream)
        let changed = try await registry.confirmAndExecute(token: XCTUnwrap(url.confirmationToken), confirmed: true)
        XCTAssertTrue(changed.success, changed.summary)
        saved = try XCTUnwrap(ConfigurationStore.load(from: model.configURL).cameras.first)
        XCTAssertEqual(saved.substream, "rtsp://127.0.0.1/new")
        XCTAssertFalse(saved.aiChatEnabled)
        try model.setCameraEnabledChecked(camera, enabled: false)
        XCTAssertEqual(model.config.cameras[0].name, "Renamed", "A stale GUI camera value must not overwrite newer metadata")
        XCTAssertEqual(model.config.cameras[0].substream, "rtsp://127.0.0.1/new")
        let crossHost = try await registry.execute(actionID: "camera.edit", parameters: ["camera_id": camera.id.uuidString, "url": "rtsp://example.test/new"])
        XCTAssertTrue(crossHost.requiresOperatorConfirmation)
        let denied = try await registry.confirmAndExecute(token: XCTUnwrap(crossHost.confirmationToken), confirmed: true)
        XCTAssertFalse(denied.success)
        XCTAssertEqual(model.config.cameras[0].substream, "rtsp://127.0.0.1/new")
        XCTAssertEqual(credentials.values[camera.id]?.password, "fixture-secret")
        XCTAssertEqual(credentials.saveCount, 0)
        XCTAssertEqual(credentials.removeCount, 0)
        let enable = try await registry.execute(actionID: "camera.set_enabled", parameters: ["camera_id": camera.id.uuidString, "enabled": "true"])
        XCTAssertTrue(enable.requiresOperatorConfirmation)
        XCTAssertFalse(model.config.cameras[0].enabled)
        let enabled = try await registry.confirmAndExecute(token: XCTUnwrap(enable.confirmationToken), confirmed: true)
        XCTAssertTrue(enabled.success)
        XCTAssertTrue(try ConfigurationStore.load(from: model.configURL).cameras[0].enabled)
        XCTAssertFalse(model.running, "Config enable is not a verified stream connection")
        XCTAssertNil(model.tiles[camera.id]?.session)
    }

    func testInvalidURLsAreRejectedBeforeConfirmationAndInvalidSourcesDoNotWrite() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, credentials, camera) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let bytes = try Data(contentsOf: model.configURL)
        for url in ["rtsp://user:private@example.test/live", "rtsp://example.test/live?token=private", "rtsp://example.test:70000/live", "https://example.test/live"] {
            let result = try await registry.execute(actionID: "camera.edit", parameters: ["camera_id": camera.id.uuidString, "url": url])
            XCTAssertFalse(result.success)
            XCTAssertFalse(result.requiresOperatorConfirmation)
            XCTAssertNil(result.confirmationToken)
        }
        let cases = [
            ("camera.add_screen", ["name": "Bad", "display_id": "0"]),
            ("camera.add_file", ["file_path": root.path]),
            ("camera.add_file", ["file_path": "relative.mp4"]),
            ("camera.add_local", ["name": "Bad", "device_id": " "]),
            ("camera.add_network", ["name": "Bad", "url": "rtsp://example.test/live", "password": "private"]),
            ("camera.edit", ["camera_id": camera.id.uuidString, "location": "X", "clear_location": "true"])
        ]
        for (id, arguments) in cases {
            let result = try await registry.execute(actionID: id, parameters: arguments)
            XCTAssertFalse(result.success)
            XCTAssertEqual(try Data(contentsOf: model.configURL), bytes)
        }
        XCTAssertEqual(credentials.saveCount, 0)
        XCTAssertEqual(credentials.removeCount, 0)
    }

    func testEditDisabledSourceIDsThroughRegisteredTypedActionsAndAudit() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, credentials, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        var local = Camera(name: "Local", location: "Room", substream: "", enabled: false,
                           localDeviceID: "device-old", yoloEnabled: true, aiChatEnabled: false)
        var screen = Camera(name: "Screen", substream: "", enabled: false, screenDisplayID: "10")
        try model.saveLocalCamera(local, startAfterSave: false)
        try model.saveScreenCamera(screen, startAfterSave: false)
        credentials.values[local.id] = Credentials(username: "fixture-local", password: "fixture-secret")
        credentials.readCount = 0
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let store = try LocalTrackingStore(url: root.appendingPathComponent("action-audit.sqlite"))
        let coordinator = ACTAAnalyticsCoordinator(aiClient: IsolatedWallFixtureSupport.client(), trackingStore: store)
        let call = ACTAAgentFunctionCall(callID: "edit", name: "acta__camera__edit",
            argumentsJSON: #"{"camera_id":"\#(local.id.uuidString)","device_id":"device-new","name":"Updated"}"#)
        let output = await coordinator.executeModelGeneratedAgentTool(call, threadID: "source-edit",
            requestToolNames: [call.name], registry: registry)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.outputJSON.utf8)) as? [String: Any])
        XCTAssertEqual(result["action_success"] as? Bool, true)
        XCTAssertEqual(result["action_verified"] as? Bool, true)
        XCTAssertEqual(result["connection_verified"] as? Bool, false)
        local.localDeviceID = "device-new"
        local.name = "Updated"
        XCTAssertEqual(try ConfigurationStore.load(from: model.configURL).cameras.first { $0.id == local.id }, local)
        let screenResult = try await registry.executeJSON(actionID: "camera.edit",
            argumentsJSON: #"{"camera_id":"\#(screen.id.uuidString)","display_id":42}"#)
        XCTAssertTrue(screenResult.success, screenResult.summary)
        XCTAssertTrue(screenResult.verified)
        screen.screenDisplayID = "42"
        XCTAssertEqual(try ConfigurationStore.load(from: model.configURL).cameras.first { $0.id == screen.id }, screen)
        XCTAssertEqual(credentials.values[local.id]?.password, "fixture-secret")
        XCTAssertEqual(credentials.readCount, 0)
        XCTAssertEqual(credentials.saveCount, 0)
        XCTAssertEqual(credentials.removeCount, 0)
        XCTAssertFalse(model.running)
        XCTAssertTrue(model.tiles.values.allSatisfy { $0.session == nil })
        let audit = try store.executeReadOnlyACTASQL("SELECT tool_name, args_json FROM ghost_chat_tool_calls")
        XCTAssertTrue(audit.contains { $0["tool_name"] == "camera.edit" && ($0["args_json"] ?? "").contains("device-new") })
        XCTAssertFalse(audit.contains { ($0["args_json"] ?? "").contains("fixture-secret") })
        let unaudited = ACTAAnalyticsCoordinator(aiClient: IsolatedWallFixtureSupport.client())
        let rejected = await unaudited.executeModelGeneratedAgentTool(
            ACTAAgentFunctionCall(callID: "no-audit", name: "acta__camera__edit",
                argumentsJSON: #"{"camera_id":"\#(local.id.uuidString)","device_id":"not-saved"}"#),
            threadID: "source-edit", requestToolNames: ["acta__camera__edit"], registry: registry)
        let failure = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rejected.outputJSON.utf8)) as? [String: Any])
        XCTAssertEqual(failure["action_success"] as? Bool, false)
        XCTAssertEqual(try ConfigurationStore.load(from: model.configURL).cameras.first { $0.id == local.id }, local)
    }

    func testSourceIDEditsRejectInvalidTypesDuplicatesAndActiveWallWithoutWriting() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, credentials, network) = try fixture()
        defer { model.running = false; model.connecting = false; model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let local = Camera(name: "Local", substream: "", enabled: false, localDeviceID: "device-a")
        let duplicate = Camera(name: "Other", substream: "", enabled: false, localDeviceID: "device-b")
        let screen = Camera(name: "Screen", substream: "", enabled: false, screenDisplayID: "10")
        let enabled = Camera(name: "Enabled", substream: "", enabled: true, screenDisplayID: "20")
        for camera in [local, duplicate, screen, enabled] {
            try model.saveCameraConfigurationChecked(camera)
        }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let bytes = try Data(contentsOf: model.configURL)
        let cases: [[String: String]] = [
            ["camera_id": local.id.uuidString, "device_id": " "],
            ["camera_id": local.id.uuidString, "device_id": "device-b"],
            ["camera_id": screen.id.uuidString, "display_id": "0"],
            ["camera_id": screen.id.uuidString, "display_id": "4294967296"],
            ["camera_id": screen.id.uuidString, "display_id": "20"],
            ["camera_id": enabled.id.uuidString, "display_id": "21"],
            ["camera_id": local.id.uuidString, "display_id": "21"],
            ["camera_id": screen.id.uuidString, "device_id": "device-c"],
            ["camera_id": network.id.uuidString, "device_id": "device-c"],
            ["camera_id": local.id.uuidString, "device_id": "device-c", "display_id": "21"],
            ["camera_id": local.id.uuidString, "device_id": "device-c", "url": "rtsp://example.test/live"]
        ]
        for arguments in cases {
            let result = try await registry.execute(actionID: "camera.edit", parameters: arguments)
            XCTAssertFalse(result.success, "\(arguments): \(result.summary)")
            XCTAssertFalse(result.requiresOperatorConfirmation)
            XCTAssertEqual(try Data(contentsOf: model.configURL), bytes)
        }
        for raw in [
            #"{"camera_id":"\#(screen.id.uuidString)","display_id":"42"}"#,
            #"{"camera_id":"\#(screen.id.uuidString)","display_id":true}"#,
            #"{"camera_id":"\#(local.id.uuidString)","device_id":42}"#
        ] {
            let result = try await registry.executeJSON(actionID: "camera.edit", argumentsJSON: raw)
            XCTAssertFalse(result.success)
            XCTAssertEqual(try Data(contentsOf: model.configURL), bytes)
        }
        for state in 0...1 {
            model.running = state == 0
            model.connecting = state == 1
            let result = try await registry.execute(actionID: "camera.edit",
                parameters: ["camera_id": local.id.uuidString, "device_id": "device-c"])
            XCTAssertFalse(result.success)
            XCTAssertEqual(try Data(contentsOf: model.configURL), bytes)
        }
        model.running = false
        model.connecting = false
        model.vlmBusy = true
        let busy = try await registry.execute(actionID: "camera.edit",
            parameters: ["camera_id": local.id.uuidString, "device_id": "device-c"])
        XCTAssertFalse(busy.success)
        XCTAssertEqual(try Data(contentsOf: model.configURL), bytes)
        model.vlmBusy = false
        var changed = try ConfigurationStore.load(from: model.configURL)
        changed.cameras[0].name = "External change"
        try ConfigurationStore.save(changed, to: model.configURL)
        let externalBytes = try Data(contentsOf: model.configURL)
        let stale = try await registry.execute(actionID: "camera.edit",
            parameters: ["camera_id": local.id.uuidString, "device_id": "device-c"])
        XCTAssertFalse(stale.success)
        XCTAssertEqual(try Data(contentsOf: model.configURL), externalBytes)
        XCTAssertEqual(credentials.saveCount, 0)
        XCTAssertEqual(credentials.removeCount, 0)
    }

    func testRemovalRequiresReviewAndChecksCredentialDeletion() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, credentials, camera) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let pending = try await registry.execute(actionID: "camera.remove", parameters: ["camera_id": camera.id.uuidString])
        XCTAssertTrue(pending.requiresOperatorConfirmation)
        XCTAssertEqual(credentials.removeCount, 0)
        credentials.failRemove = true
        let failed = try await registry.confirmAndExecute(token: XCTUnwrap(pending.confirmationToken), confirmed: true)
        XCTAssertFalse(failed.success)
        XCTAssertEqual(try ConfigurationStore.load(from: model.configURL).cameras.count, 1)
        XCTAssertNotNil(credentials.values[camera.id])
        credentials.failRemove = false
        let again = try await registry.execute(actionID: "camera.remove", parameters: ["camera_id": camera.id.uuidString])
        let removed = try await registry.confirmAndExecute(token: XCTUnwrap(again.confirmationToken), confirmed: true)
        XCTAssertTrue(removed.success, removed.summary)
        XCTAssertTrue(try ConfigurationStore.load(from: model.configURL).cameras.isEmpty)
        XCTAssertTrue(model.config.cameras.isEmpty)
        XCTAssertNil(credentials.values[camera.id])
    }

    func testCredentialRollbackOnFailedConfigurationSaveAndCorruptFileProtection() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, credentials, camera) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let configURL = model.configURL
        credentials.onRemove = {
            try FileManager.default.removeItem(at: configURL)
            try FileManager.default.createDirectory(at: configURL, withIntermediateDirectories: true)
        }
        let pending = try await registry.execute(actionID: "camera.remove", parameters: ["camera_id": camera.id.uuidString])
        let failed = try await registry.confirmAndExecute(token: XCTUnwrap(pending.confirmationToken), confirmed: true)
        XCTAssertFalse(failed.success)
        XCTAssertNotNil(credentials.values[camera.id], "Credential must be restored when configuration commit fails")
        XCTAssertEqual(model.config.cameras, [camera])
        try FileManager.default.removeItem(at: model.configURL)
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: model.configURL)
        let edit = try await registry.execute(actionID: "camera.edit", parameters: ["camera_id": camera.id.uuidString, "name": "Not saved"])
        XCTAssertFalse(edit.success)
        XCTAssertEqual(try Data(contentsOf: model.configURL), corrupt)
    }
}

private final class TestCameraCredentials: CameraCredentialStore, @unchecked Sendable {
    var values: [UUID: Credentials] = [:]
    var readCount = 0
    var saveCount = 0
    var removeCount = 0
    var failRemove = false
    var onRemove: (() throws -> Void)?
    func read(_ id: UUID) throws -> Credentials? { readCount += 1; return values[id] }
    func save(_ credentials: Credentials, for id: UUID) throws { saveCount += 1; values[id] = credentials }
    func remove(_ id: UUID) throws {
        removeCount += 1
        if failRemove { throw ConfigurationError.invalid("Fixture credential deletion failure") }
        values.removeValue(forKey: id)
        try onRemove?()
    }
}
