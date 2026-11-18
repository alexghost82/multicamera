import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTAServiceAdapterTests: XCTestCase {
    func testStreamCredentialsNeverEnterAgentOutput() {
        XCTAssertEqual(actaRedactedStreamURL("rtsp://operator:secret@example.test:554/live?token=private#secret"),
            "rtsp://example.test:554/live")
        XCTAssertEqual(actaRedactedStreamURL("invalid private value"), "[redacted stream]")
        let text = String(repeating: "Reviewed observation ", count: 100)
        let review = actaAuditArguments(["text": text, "password": "private", "url": "rtsp://user:secret@example.test/live?token=private"])
        XCTAssertEqual(review["text"], text, "The operator must be able to read the complete annotation before approval")
        XCTAssertEqual(review["password"], "[redacted]")
        XCTAssertEqual(review["url"], "rtsp://example.test/live")
    }

    func testLocalAgentDiscoversAndExecutesRegisteredActionWithScriptedTransport() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(".service-fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previousModels = actaTestModelPreferences()
        defer { ModelSelectionRegistry.update(previousModels) }
        try prepareOfflineWallFixture(at: directory)
        let poseURL = directory.appendingPathComponent("fake-pose.mlmodel")
        let model = WallModel(configURL: directory.appendingPathComponent("cameras.json"), workerMode: false, poseModelURL: poseURL,
            trackingStoreURL: directory.appendingPathComponent("model.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: directory.appendingPathComponent("features.json"),
                databaseURL: directory.appendingPathComponent("features.sqlite")),
            analyticsDirectoryURL: directory.appendingPathComponent("analytics"),
            agentClient: offlineWallClient(),
            cameraMemoryStore: CameraMemoryStore(url: directory.appendingPathComponent("frames")),
            operationsWatchURL: directory.appendingPathComponent("watches.json"),
            missionStoreURL: directory.appendingPathComponent("missions.json"),
            cameraCredentialStore: ACTAIsolatedCredentials(),
            operationsPreferencesURL: directory.appendingPathComponent("operations.json"),
            alertClipStore: CriticalAlertClipStore(url: directory.appendingPathComponent("clips")),
            languageSettings: LanguageSettings(storage: ACTAIsolatedLanguageStorage()),
            monitorHistoryURL: directory.appendingPathComponent("monitor.json"),
            analyticsModelDiscovery: AnalyticsModelDiscovery(modelURL: { _ in nil }, integrity: { url in
                XCTAssertEqual(url, poseURL)
                return (hash: "synthetic", sizeBytes: 0)
            }))
        defer { model.shutdown() }
        IsolatedWallFixtureSupport.assertSafe(model)
        XCTAssertTrue(model.featurePreferences.enabledFeatures.isEmpty)
        XCTAssertFalse(model.running)
        await registerAllWallActions(registry: .shared, model: model)
        let store = try LocalTrackingStore(url: directory.appendingPathComponent("agent.sqlite"))
        let script = ActionTransportScript()
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .mlxInProcess, preferredLanguage: .ru),
            transport: { _ in
                XCTFail("Unexpected network request")
                throw URLError(.notConnectedToInternet)
            }, keyProvider: { _ in
                XCTFail("Unexpected AI credential access")
                return nil
            }, localAgentInference: { prompt, _ in await script.reply(to: prompt) })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        _ = await coordinator.askACTAChatAgent(question: "Установи семь колонок", maxSteps: 3)
        XCTAssertEqual(model.config.columns, 7)
        let requests = await script.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.first?.contains("acta__canvas__set_columns") == true)
        XCTAssertTrue(requests.last?.contains("action_verified") == true)

        let tools = try await ACTAAnalyticsCoordinator.registryTools()
        XCTAssertFalse(tools.contains { $0.name == "acta__memory__clear_all_frames" }, "Disconnected adapters must not be advertised")
        XCTAssertTrue(tools.allSatisfy { !$0.name.contains(".") })

        let pending = await coordinator.executeAgentTool(toolName: "acta__settings__update_permissions",
            arguments: ["allow_voice_input": "true"])
        XCTAssertTrue(pending.outputJSON.contains("confirmation_required"))
        let proposals = try store.listACTAChatActions(threadID: "default", status: "proposed")
        XCTAssertEqual(proposals.count, 1)
        XCTAssertTrue(proposals.first?.actionID.hasPrefix("CONFIRM-") == true)
        XCTAssertFalse(model.featurePreferences.allowVoiceInput)
    }

    func testActionsApplyToLiveModelAndPersistThroughGUIService() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(".service-fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previousModels = actaTestModelPreferences()
        defer { ModelSelectionRegistry.update(previousModels) }
        try prepareOfflineWallFixture(at: directory)
        let configurationURL = directory.appendingPathComponent("cameras.json")
        let preferencesURL = directory.appendingPathComponent("features.json")
        let poseURL = directory.appendingPathComponent("fake-pose.mlmodel")
        let model = WallModel(configURL: configurationURL, workerMode: false, poseModelURL: poseURL,
            trackingStoreURL: directory.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: preferencesURL,
                databaseURL: directory.appendingPathComponent("features.sqlite")),
            analyticsDirectoryURL: directory.appendingPathComponent("analytics"),
            agentClient: offlineWallClient(),
            cameraMemoryStore: CameraMemoryStore(url: directory.appendingPathComponent("frames")),
            operationsWatchURL: directory.appendingPathComponent("watches.json"),
            missionStoreURL: directory.appendingPathComponent("missions.json"),
            cameraCredentialStore: ACTAIsolatedCredentials(),
            operationsPreferencesURL: directory.appendingPathComponent("operations.json"),
            alertClipStore: CriticalAlertClipStore(url: directory.appendingPathComponent("clips")),
            languageSettings: LanguageSettings(storage: ACTAIsolatedLanguageStorage()),
            monitorHistoryURL: directory.appendingPathComponent("monitor.json"),
            analyticsModelDiscovery: AnalyticsModelDiscovery(modelURL: { _ in nil }, integrity: { url in
                XCTAssertEqual(url, poseURL)
                return (hash: "synthetic", sizeBytes: 0)
            }))
        defer { model.shutdown() }
        IsolatedWallFixtureSupport.assertSafe(model)
        XCTAssertTrue(model.featurePreferences.enabledFeatures.isEmpty)
        XCTAssertFalse(model.running)
        let registry = ACTAActionRegistry()
        let reconnectAction = CameraReconnectAction(model: model)
        let directReconnect = try await reconnectAction.execute(parameters: ["camera_id": UUID().uuidString], context: ACTAActionContext())
        XCTAssertFalse(directReconnect.success)
        XCTAssertTrue(directReconnect.error?.hasPrefix("UNSUPPORTED:") == true)
        await registry.register(reconnectAction)
        await registerAllWallActions(registry: registry, model: model)

        let reconnect = try await registry.execute(actionID: "camera.reconnect", parameters: ["camera_id": UUID().uuidString])
        XCTAssertFalse(reconnect.success)
        XCTAssertTrue(reconnect.error?.hasPrefix("UNSUPPORTED:") == true)

        let settings = try await registry.execute(actionID: "settings.update_system",
            parameters: ["columns": "7", "detection_fps": "3"])
        XCTAssertTrue(settings.success)
        XCTAssertTrue(settings.verified)
        XCTAssertEqual(model.config.columns, 7)
        XCTAssertEqual(try ConfigurationStore.load(from: configurationURL).columns, 7)

        let original = model.localAnalyticsEngine.settings
        let enabled = !original.enableFallDetection
        let analytics = try await registry.execute(actionID: "analytics.set_global_toggle",
            parameters: ["feature": "fall", "enabled": String(enabled)])
        XCTAssertTrue(analytics.success)
        XCTAssertTrue(analytics.verified)
        XCTAssertEqual(model.localAnalyticsEngine.settings.enableFallDetection, enabled)
        let stored = try VideoAnalyticsSettingsStore.load(from: model.localAnalyticsEngine.settingsURL)
        XCTAssertEqual(stored.enableFallDetection, enabled)
        let read = try await registry.execute(actionID: "analytics.get_settings", parameters: [:])
        let decoded = try JSONDecoder().decode(VideoAnalyticsSettings.self, from: Data(read.outputJSON.utf8))
        XCTAssertEqual(decoded.enableFallDetection, enabled)

        let permission = try await registry.execute(actionID: "settings.update_permissions",
            parameters: ["allow_voice_input": "true"])
        XCTAssertTrue(permission.requiresOperatorConfirmation)
        let before = model.featurePreferences
        XCTAssertEqual(try CameraFeaturePreferencesStore.load(from: preferencesURL), before)
        let token = try XCTUnwrap(permission.confirmationToken)
        let approved = try await registry.confirmAndExecute(token: token, confirmed: true)
        XCTAssertTrue(approved.success)
        XCTAssertTrue(model.featurePreferences.allowVoiceInput)
        XCTAssertTrue(try CameraFeaturePreferencesStore.load(from: preferencesURL).allowVoiceInput)
    }
}

@MainActor
private func actaTestModelPreferences() -> ModelSelectionPreferences {
    ModelSelectionPreferences(
        enabled: Set(LocalModelService.allCases.filter { ModelSelectionRegistry.isEnabled($0) }),
        paths: Dictionary(uniqueKeysWithValues: LocalModelService.allCases.compactMap { service in
            ModelSelectionRegistry.path(service).map { (service, $0.path) }
        }))
}

@MainActor
private func prepareOfflineWallFixture(at root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try ConfigurationStore.save(WallConfiguration(), to: root.appendingPathComponent("cameras.json"))
    try CameraFeaturePreferencesStore.save(CameraFeaturePreferences(enabledFeatures: []),
        to: root.appendingPathComponent("features.json"))
    var models = ModelSelectionPreferences()
    models.enabled = []
    try models.save(to: root.appendingPathComponent("model-preferences.json"))
    var ai = VLMPreferences()
    ai.actaBackendMode = .dryRun
    try VLMStore.save(ai, to: root.appendingPathComponent("vlm.json"))
}

private func offlineWallClient() -> ACTAAIClient {
    ACTAAIClient(config: ACTAAIConfiguration(mode: .dryRun), transport: { _ in
        XCTFail("Unexpected network request")
        throw URLError(.notConnectedToInternet)
    }, keyProvider: { _ in
        XCTFail("Unexpected AI credential access")
        return nil
    })
}

@MainActor
private final class ACTAIsolatedLanguageStorage: LanguageSettingsStorage {
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String, forKey key: String) { values[key] = value }
}

private actor ActionTransportScript {
    private(set) var requests: [String] = []
    func reply(to request: String) -> String {
        requests.append(request)
        if requests.count == 1 {
            return "{\"tool_calls\":[{\"name\":\"acta__canvas__set_columns\",\"arguments\":{\"columns\":7}}]}"
        }

        return "{\"answerMarkdown\":\"Установлено семь колонок.\",\"citedRecordIDs\":[],\"confidence\":1}"
    }
}

struct ACTAIsolatedCredentials: CameraCredentialStore {
    private struct UnexpectedAccess: Error {}
    func read(_ id: UUID) throws -> Credentials? { XCTFail("Unexpected credential read"); throw UnexpectedAccess() }
    func save(_ credentials: Credentials, for id: UUID) throws { XCTFail("Unexpected credential save"); throw UnexpectedAccess() }
    func remove(_ id: UUID) throws { XCTFail("Unexpected credential removal"); throw UnexpectedAccess() }
}
