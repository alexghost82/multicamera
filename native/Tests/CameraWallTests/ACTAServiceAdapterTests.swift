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
    }

    func testLocalAgentDiscoversAndExecutesRegisteredActionWithScriptedTransport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WallModel(configURL: directory.appendingPathComponent("cameras.json"),
            trackingStoreURL: directory.appendingPathComponent("model.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: directory.appendingPathComponent("features.json"),
                databaseURL: directory.appendingPathComponent("features.sqlite")),
            analyticsDirectoryURL: directory.appendingPathComponent("analytics"))
        defer { model.stop() }
        await registerAllWallActions(registry: .shared, model: model)
        let store = try LocalTrackingStore(url: directory.appendingPathComponent("agent.sqlite"))
        let script = ActionTransportScript()
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .localVLLM, preferredLanguage: .ru),
            transport: { request in
                let raw = await script.reply(to: String(decoding: request.httpBody ?? Data(), as: UTF8.self))
                let payload: [String: Any] = ["choices": [["message": ["content": raw]]]]
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (try JSONSerialization.data(withJSONObject: payload), response)
            })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        _ = await coordinator.askACTAChatAgent(question: "Установи семь колонок", maxSteps: 3)
        XCTAssertEqual(model.config.columns, 7)
        let requests = await script.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.first?.contains("acta__canvas__set_columns") == true)
        XCTAssertTrue(requests.last?.contains("action_verified") == true)

        let tools = try await ACTAAnalyticsCoordinator.registryTools()
        XCTAssertFalse(tools.contains { $0.name == "acta__watch__create" }, "Disconnected adapters must not be advertised")
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configurationURL = directory.appendingPathComponent("cameras.json")
        let preferencesURL = directory.appendingPathComponent("features.json")
        let model = WallModel(configURL: configurationURL,
            trackingStoreURL: directory.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: preferencesURL,
                databaseURL: directory.appendingPathComponent("features.sqlite")),
            analyticsDirectoryURL: directory.appendingPathComponent("analytics"))
        defer { model.stop() }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)

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
