import CameraCore
import Foundation
import XCTest
@testable import CameraWall

private final class WallSettingsAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let failAt: Int?

    init(failAt: Int? = nil) { self.failAt = failAt }

    func record(_ event: ACTABrokerAuditEvent) throws {
        try lock.withLock {
            count += 1
            if count == failAt { throw CocoaError(.fileWriteUnknown) }
        }
    }
}

private actor SettingsModelScript {
    private(set) var prompts: [String] = []
    func reply(_ prompt: String) -> String {
        prompts.append(prompt)
        if prompts.count == 1 {
            return #"{"tool_calls":[{"name":"acta__settings__get_section","arguments":{"section":"general"}}]}"#
        }
        return #"{"answerMarkdown":"Reviewed settings.","confidence":0.5}"#
    }
}

@MainActor
final class ACTAWallModelSettingsReadProviderTests: XCTestCase {
    private func fixture(corruptConfiguration: Bool = false) throws -> (URL, WallModel) {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".wall-settings-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let configURL = root.appendingPathComponent("cameras.json")
        var saved = WallConfiguration()
        saved.columns = 2
        saved.staleAfterMilliseconds = 700
        try ConfigurationStore.save(saved, to: configURL)
        if corruptConfiguration {
            try Data("synthetic corrupt configuration".utf8).write(to: configURL)
        }
        try ModelSelectionPreferences(enabled: []).save(to: root.appendingPathComponent("model-preferences.json"))
        try CameraFeaturePreferencesStore.save(CameraFeaturePreferences(enabledFeatures: []),
                                               to: root.appendingPathComponent("features.json"))
        let poseURL = root.appendingPathComponent("unused-pose.mlmodel")
        let model = WallModel(
            configURL: configURL, workerMode: false, poseModelURL: poseURL,
            trackingStoreURL: root.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: root.appendingPathComponent("features.json"),
                                                         databaseURL: root.appendingPathComponent("features.sqlite")),
            analyticsDirectoryURL: root.appendingPathComponent("analytics"),
            agentClient: IsolatedWallFixtureSupport.client(),
            cameraMemoryStore: CameraMemoryStore(url: root.appendingPathComponent("frames")),
            operationsWatchURL: root.appendingPathComponent("watches.json"),
            missionStoreURL: root.appendingPathComponent("missions.json"),
            cameraCredentialStore: ACTAIsolatedCredentials(),
            operationsPreferencesURL: root.appendingPathComponent("operations.json"),
            alertClipStore: CriticalAlertClipStore(url: root.appendingPathComponent("clips")),
            languageSettings: LanguageSettings(storage: InMemoryLanguageStorage()),
            monitorHistoryURL: root.appendingPathComponent("monitor.json"),
            analyticsModelDiscovery: IsolatedWallFixtureSupport.modelDiscovery)
        IsolatedWallFixtureSupport.assertSafe(model)
        return (root, model)
    }

    private func broker(_ provider: ACTAWallModelSettingsReadProvider, audit: WallSettingsAudit,
                        chatScopes: Bool = false) async throws
        -> (ACTALocalActionBroker, ACTABrokerOperator, ACTABrokerSession) {
        let action = ACTAScopedSettingsReadAction(provider: provider)
        let scopes = chatScopes ? ACTAAnalyticsCoordinator.localInspectionIDs : []
        let creation = await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], allowedInspectionIDs: scopes,
            audit: { try audit.record($0) })
        let host = try XCTUnwrap(creation)
        let issued = await host.broker.openSession(
            operatorKey: host.operatorKey, input: .chat, threadID: "fixture",
            actionIDs: [action.id], inspectionIDs: scopes)
        let session = try XCTUnwrap(issued)
        return (host.broker, host.operatorKey, session)
    }

    func testChatLoopReceivesCurrentLimitedSettings() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.config.columns = 7
        model.config.staleAfterMilliseconds = 2400
        model.config.detectionThreshold = 0.6
        model.config.detectionFPS = 4
        model.config.go2rtcPath = "/synthetic-secret-path"
        let provider = ACTAWallModelSettingsReadProvider(model: model)
        let (broker, key, session) = try await broker(provider, audit: WallSettingsAudit(), chatScopes: true)
        let script = SettingsModelScript()
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .mlxInProcess), transport: { _ in
            XCTFail("Unexpected network request")
            throw URLError(.notConnectedToInternet)
        }, keyProvider: { _ in XCTFail("Unexpected Keychain access"); return nil },
            localAgentInference: { prompt, _ in await script.reply(prompt) })
        let store = try LocalTrackingStore(url: root.appendingPathComponent("chat.sqlite"))
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        _ = await coordinator.askACTAChatAgent(question: "Show grid settings", threadID: "fixture",
                                              broker: broker, brokerSession: session)
        let prompts = await script.prompts
        XCTAssertTrue(prompts.first?.contains("acta__settings__get_section") == true)
        XCTAssertTrue(prompts.dropFirst().contains {
            $0.contains("action_output") && $0.contains("staleAfterMilliseconds") && $0.contains("2400")
                && $0.contains("detectionThreshold") && $0.contains("detectionFPS")
        })
        XCTAssertTrue(prompts.allSatisfy { !$0.contains("synthetic-secret") })
        await broker.closeSession(session, operatorKey: key)
    }

    func testModelRouteDoesNotReleaseSettingsOnAuditFailure() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let provider = ACTAWallModelSettingsReadProvider(model: model)
        let (broker, key, session) = try await broker(provider, audit: WallSettingsAudit(failAt: 3))
        let store = try LocalTrackingStore(url: root.appendingPathComponent("chat.sqlite"))
        let coordinator = ACTAAnalyticsCoordinator(aiClient: IsolatedWallFixtureSupport.client(), trackingStore: store)
        let name = "acta__settings__get_section"
        let call = ACTAAgentFunctionCall(callID: "settings", name: name,
                                         argumentsJSON: #"{"section":"general"}"#)
        let result = await coordinator.executeModelGeneratedAgentTool(call, threadID: "fixture",
            requestToolNames: [name], broker: broker, brokerSession: session)
        XCTAssertTrue(result.outputJSON.contains("AUDIT_FAILED"))
        XCTAssertFalse(result.outputJSON.contains("action_output"))
        XCTAssertFalse(result.outputJSON.contains("columns"))
        await broker.closeSession(session, operatorKey: key)
    }

    func testReadsCurrentGUIStateAndOnlyWhitelistedFields() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(model.error)
        model.config.columns = 7
        model.config.staleAfterMilliseconds = 2400
        model.config.detectionThreshold = 0.6
        model.config.detectionFPS = 4
        model.config.go2rtcPath = "/synthetic-secret-path"
        model.config.cameras = [Camera(name: "synthetic-secret-name",
                                       substream: "rtsp://synthetic-secret-host/path", enabled: false)]

        let provider = ACTAWallModelSettingsReadProvider(model: model)
        let (broker, key, session) = try await broker(provider, audit: WallSettingsAudit())
        for section in ["general", "system"] {
            let result = await broker.request(session: session, actionID: "settings.get_section",
                argumentsJSON: #"{"section":"\#(section)"}"#, expectedThreadID: "fixture")
            XCTAssertTrue(result.success, result.summary)
            let output = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
            XCTAssertEqual(Set(output.keys), ["columns", "staleAfterMilliseconds", "detectionThreshold", "detectionFPS"])
            XCTAssertEqual(output["columns"] as? Int, 7)
            XCTAssertEqual(output["staleAfterMilliseconds"] as? Int, 2400)
            XCTAssertEqual(output["detectionThreshold"] as? Double, 0.6)
            XCTAssertEqual(output["detectionFPS"] as? Double, 4)
            let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
            XCTAssertFalse(encoded.contains("synthetic-secret"))
            XCTAssertFalse(encoded.contains("rtsp"))
        }
        model.config.columns = 11
        let changed = await broker.request(session: session, actionID: "settings.get_section",
            argumentsJSON: #"{"section":"general"}"#, expectedThreadID: "fixture")
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(changed.outputJSON.utf8)) as? [String: Any])
        XCTAssertEqual(output["columns"] as? Int, 11)
        let saved = try ConfigurationStore.load(from: model.configURL)
        XCTAssertEqual(saved.columns, 2)
        XCTAssertEqual(saved.staleAfterMilliseconds, 700)
        await broker.closeSession(session, operatorKey: key)
    }

    func testModelErrorsAndInvalidValuesFailClosed() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model) = try fixture(corruptConfiguration: true)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        XCTAssertNotNil(model.error)
        let action = ACTAScopedSettingsReadAction(provider: ACTAWallModelSettingsReadProvider(model: model))
        let loadFailure = try await action.execute(parameters: ["section": "general"], context: ACTAActionContext())
        XCTAssertFalse(loadFailure.success)
        XCTAssertTrue(loadFailure.error?.hasPrefix("STORAGE_ERROR:") == true)
        XCTAssertFalse(loadFailure.outputJSON.contains("columns"))
        XCTAssertFalse(loadFailure.summary.contains("synthetic"))

        model.error = "synthetic-secret-model-error"
        let modelFailure = try await action.execute(parameters: ["section": "system"], context: ACTAActionContext())
        XCTAssertFalse(modelFailure.success)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(modelFailure), as: UTF8.self).contains("synthetic-secret"))
        model.error = nil
        for (columns, stale) in [(0, 1000), (17, 1000), (4, 199), (4, 30001)] {
            model.config.columns = columns
            model.config.staleAfterMilliseconds = stale
            let invalid = try await action.execute(parameters: ["section": "general"], context: ACTAActionContext())
            XCTAssertFalse(invalid.success)
            XCTAssertTrue(invalid.error?.hasPrefix("STORAGE_ERROR:") == true)
            XCTAssertFalse(invalid.outputJSON.contains("columns"))
        }
    }

    func testInvalidRequestAndAuditFailureReleaseNoSettings() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.config.columns = 9
        let provider = ACTAWallModelSettingsReadProvider(model: model)
        let action = ACTAScopedSettingsReadAction(provider: provider)
        for parameters in [["section": "ai"], ["section": "general", "extra": "synthetic-secret"]] {
            let result = try await action.execute(parameters: parameters, context: ACTAActionContext())
            XCTAssertFalse(result.success)
            XCTAssertTrue(result.error?.hasPrefix("INVALID_ARGUMENT:") == true)
            XCTAssertFalse(result.outputJSON.contains("columns"))
        }
        for failAt in 1...3 {
            let (broker, key, session) = try await broker(provider, audit: WallSettingsAudit(failAt: failAt))
            let result = await broker.request(session: session, actionID: action.id,
                argumentsJSON: #"{"section":"general"}"#, expectedThreadID: "fixture")
            XCTAssertFalse(result.success)
            XCTAssertTrue(result.error?.hasPrefix("AUDIT_FAILED:") == true)
            XCTAssertFalse(result.outputJSON.contains("columns"))
            await broker.closeSession(session, operatorKey: key)
        }
    }
}
