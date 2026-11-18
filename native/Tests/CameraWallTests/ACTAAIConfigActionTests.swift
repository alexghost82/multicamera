import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTAAIConfigActionTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let model: WallModel
        let registry: ACTAActionRegistry
        let previousModels: ModelSelectionPreferences
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-config-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let previousModels = ModelSelectionPreferences(
            enabled: Set(LocalModelService.allCases.filter { ModelSelectionRegistry.isEnabled($0) }),
            paths: Dictionary(uniqueKeysWithValues: LocalModelService.allCases.compactMap { service in
                ModelSelectionRegistry.path(service).map { (service, $0.path) }
            }))
        var config = WallConfiguration()
        config.cameras = [Camera(name: "disabled", substream: "rtsp://127.0.0.1/fixture", enabled: false)]
        try ConfigurationStore.save(config, to: root.appendingPathComponent("cameras.json"))
        let policy = CameraFeaturePreferences(enabledFeatures: [])
        try CameraFeaturePreferencesStore.save(policy, to: root.appendingPathComponent("features.json"))
        var models = ModelSelectionPreferences()
        models.enabled = []
        try models.save(to: root.appendingPathComponent("model-preferences.json"))
        var preferences = VLMPreferences()
        preferences.actaBackendMode = .dryRun
        preferences.cloudNanoModel = "private-fixture-model"
        try VLMStore.save(preferences, to: root.appendingPathComponent("vlm.json"))
        let client = ACTAAIClient(config: WallModel.makeACTAAIConfiguration(from: preferences, featurePreferences: policy),
            transport: { _ in XCTFail("Unexpected network request"); throw URLError(.notConnectedToInternet) },
            keyProvider: { _ in XCTFail("Unexpected key access"); return nil })
        let model = WallModel(configURL: root.appendingPathComponent("cameras.json"),
            poseModelURL: root.appendingPathComponent("fake-pose.mlmodel"),
            trackingStoreURL: root.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: root.appendingPathComponent("features.json"),
                databaseURL: root.appendingPathComponent("features.sqlite")),
            analyticsDirectoryURL: root.appendingPathComponent("analytics"), agentClient: client,
            cameraMemoryStore: CameraMemoryStore(url: root.appendingPathComponent("frames")),
            operationsWatchURL: root.appendingPathComponent("watches.json"),
            missionStoreURL: root.appendingPathComponent("missions.json"),
            cameraCredentialStore: ACTAIsolatedCredentials(),
            operationsPreferencesURL: root.appendingPathComponent("operations.json"),
            alertClipStore: CriticalAlertClipStore(url: root.appendingPathComponent("clips")),
            languageSettings: LanguageSettings(storage: ConfigLanguageStorage()),
            monitorHistoryURL: root.appendingPathComponent("monitor.json"),
            analyticsModelDiscovery: IsolatedWallFixtureSupport.modelDiscovery)
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        return Fixture(root: root, model: model, registry: registry, previousModels: previousModels)
    }

    private func cleanup(_ fixture: Fixture) {
        fixture.model.shutdown()
        ModelSelectionRegistry.update(fixture.previousModels)
        try? FileManager.default.removeItem(at: fixture.root)
    }

    func testConfirmationSharedGUIPathAndBudgetInteroperation() async throws {
        let f = try await fixture()
        defer { cleanup(f) }
        let tools = try await ACTAAnalyticsCoordinator.registryTools(registry: f.registry)
        XCTAssertTrue(tools.contains { $0.name == "acta__settings__update_ai_config" })
        let before = f.model.vlmPreferences
        let pending = try await f.registry.executeJSON(actionID: "settings.update_ai_config", argumentsJSON: #"{"language":"en"}"#)
        XCTAssertTrue(pending.requiresOperatorConfirmation)
        XCTAssertTrue(pending.summary.contains("resets schedule and may prepare models"))
        XCTAssertEqual(f.model.vlmPreferences, before)
        let budget = try await f.registry.execute(actionID: "settings.update_ai_budget", parameters: ["dailyBudgetUSD": "12"])
        let budgetResult = try await f.registry.confirmAndExecute(token: XCTUnwrap(budget.confirmationToken), confirmed: true)
        XCTAssertTrue(budgetResult.success, budgetResult.summary)
        let result = try await f.registry.confirmAndExecute(token: XCTUnwrap(pending.confirmationToken), confirmed: true)
        XCTAssertTrue(result.success, result.summary)
        XCTAssertTrue(result.verified)
        var expected = before
        expected.dailyBudgetLimitUSD = 12
        expected.actaPreferredLanguage = .en
        XCTAssertEqual(f.model.vlmPreferences, expected)
        XCTAssertEqual(try VLMStore.loadPreferences(from: f.model.vlmPreferencesURL), expected)
        XCTAssertEqual(f.model.actaAnalytics.aiClient.configuration().preferredLanguage, .en)
        XCTAssertEqual(f.model.actaAnalytics.aiClient.configuration().dailyBudgetLimitUSD, 12)
        XCTAssertFalse(result.outputJSON.contains("private-fixture-model"))
        var gui = expected
        gui.actaPreferredLanguage = .he
        try f.model.saveVLMPreferences(gui)
        XCTAssertEqual(try VLMStore.loadPreferences(from: f.model.vlmPreferencesURL), gui)
        XCTAssertEqual(f.model.actaAnalytics.aiClient.configuration().preferredLanguage, .he)
    }

    func testInvalidRejectedAndUnconfirmedInputsDoNotWrite() async throws {
        let f = try await fixture()
        defer { cleanup(f) }
        let bytes = try Data(contentsOf: f.model.vlmPreferencesURL)
        for json in ["{}", #"{"language":true}"#, #"{"language":"EN"}"#,
                     #"{"speechEnabled":"true"}"#, #"{"speechEnabled":1}"#, #"{"speechEnabled":null}"#,
                     #"{"language":"en","dailyBudgetUSD":1}"#, #"{"actaOpenAIBaseURL":"https://example.com"}"#,
                     #"{"actaBackendMode":"dryRun"}"#] {
            let result = try await f.registry.executeJSON(actionID: "settings.update_ai_config", argumentsJSON: json)
            XCTAssertFalse(result.success, json)
            XCTAssertFalse(result.requiresOperatorConfirmation, json)
        }
        let direct = try await WallAIConfigAction(model: f.model).execute(parameters: ["language": "en"], context: ACTAActionContext())
        XCTAssertFalse(direct.success)
        let pending = try await f.registry.execute(actionID: "settings.update_ai_config", parameters: ["language": "en"])
        let rejected = try await f.registry.confirmAndExecute(token: XCTUnwrap(pending.confirmationToken), confirmed: false)
        XCTAssertFalse(rejected.success)
        XCTAssertEqual(try Data(contentsOf: f.model.vlmPreferencesURL), bytes)
        XCTAssertEqual(f.model.actaAnalytics.aiClient.configuration().preferredLanguage, .ru)
    }

    func testSpeechUnsupportedAcrossConsistentGUIBackendAndPolicyChange() async throws {
        let f = try await fixture()
        defer { cleanup(f) }
        let action = WallAIConfigAction(model: f.model)
        XCTAssertFalse(action.parameters.contains { $0.name == "speechEnabled" })
        let tools = try await ACTAAnalyticsCoordinator.registryTools(registry: f.registry)
        let tool = try XCTUnwrap(tools.first { $0.name == "acta__settings__update_ai_config" })
        let toolSchema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(tool.parametersSchemaJSON.utf8)) as? [String: Any])
        let properties = try XCTUnwrap(toolSchema["properties"] as? [String: Any])
        XCTAssertNil(properties["speechEnabled"])
        do {
            _ = try await action.execute(parameters: ["speechEnabled": "true"], context: ACTAActionContext(isConfirmed: true))
            XCTFail("Direct execution must reject speechEnabled")
        } catch {}
        let pending = try await f.registry.executeJSON(actionID: "settings.update_ai_config", argumentsJSON: #"{"speechEnabled":true}"#)
        XCTAssertFalse(pending.success)
        XCTAssertFalse(pending.requiresOperatorConfirmation)
        XCTAssertNil(pending.confirmationToken)
        var policy = f.model.featurePreferences
        policy.allowExternalAI = true
        try f.model.saveFeaturePolicy(policy)
        var changed = f.model.vlmPreferences
        changed.actaBackendMode = .openAI
        changed.actaOpenAIBaseURL = "https://fixture.invalid/v1?credential=synthetic-secret"
        try f.model.saveVLMPreferences(changed)
        XCTAssertEqual(f.model.actaAnalytics.aiClient.configuration(),
            WallModel.makeACTAAIConfiguration(from: changed, featurePreferences: policy))
        let result = try await f.registry.executeJSON(actionID: "settings.update_ai_config",
            argumentsJSON: #"{"language":"en","speechEnabled":true}"#)
        XCTAssertFalse(result.success)
        XCTAssertFalse(result.requiresOperatorConfirmation)
        XCTAssertNil(result.confirmationToken)
        XCTAssertEqual(f.model.vlmPreferences, changed)
        XCTAssertEqual(try VLMStore.loadPreferences(from: f.model.vlmPreferencesURL), changed)
        for text in [pending.summary, pending.outputJSON, result.summary, result.outputJSON] {
            XCTAssertFalse(text.contains("synthetic-secret"))
            XCTAssertFalse(text.contains("fixture.invalid"))
        }
    }

    func testDiskRuntimeAndPolicyDriftFailClosed() async throws {
        let f = try await fixture()
        defer { cleanup(f) }
        let before = f.model.vlmPreferences
        let pending = try await f.registry.execute(actionID: "settings.update_ai_config", parameters: ["language": "en"])
        var external = before
        external.intervalSeconds = 60
        try VLMStore.save(external, to: f.model.vlmPreferencesURL)
        let stale = try await f.registry.confirmAndExecute(token: XCTUnwrap(pending.confirmationToken), confirmed: true)
        XCTAssertFalse(stale.success)
        XCTAssertEqual(try VLMStore.loadPreferences(from: f.model.vlmPreferencesURL), external)
        XCTAssertEqual(f.model.vlmPreferences, before)
        try VLMStore.save(before, to: f.model.vlmPreferencesURL)
        let client = f.model.actaAnalytics.aiClient
        var changed = client.configuration()
        changed.dailyBudgetLimitUSD = 1
        client.updateConfiguration(changed)
        let direct = WallAIConfigAction(model: f.model)
        do {
            _ = try await direct.verify(parameters: ["language": "ru"], context: ACTAActionContext())
            XCTFail("Mismatched runtime must not verify")
        } catch {}
        let next = try await f.registry.execute(actionID: "settings.update_ai_config", parameters: ["language": "he"])
        let mismatch = try await f.registry.confirmAndExecute(token: XCTUnwrap(next.confirmationToken), confirmed: true)
        XCTAssertFalse(mismatch.success)
        XCTAssertEqual(try VLMStore.loadPreferences(from: f.model.vlmPreferencesURL), before)
        client.updateConfiguration(WallModel.makeACTAAIConfiguration(from: before, featurePreferences: f.model.featurePreferences))
        var policy = f.model.featurePreferences
        policy.allowExternalAI = true
        try CameraFeaturePreferencesStore.save(policy, to: f.root.appendingPathComponent("features.json"))
        let last = try await f.registry.execute(actionID: "settings.update_ai_config", parameters: ["language": "he"])
        let policyMismatch = try await f.registry.confirmAndExecute(token: XCTUnwrap(last.confirmationToken), confirmed: true)
        XCTAssertFalse(policyMismatch.success)
        XCTAssertEqual(try VLMStore.loadPreferences(from: f.model.vlmPreferencesURL), before)
    }

    func testWriteFailureDoesNotReportSuccessOrUpdateRuntime() async throws {
        let f = try await fixture()
        defer { cleanup(f) }
        let before = f.model.vlmPreferences
        let pending = try await f.registry.execute(actionID: "settings.update_ai_config", parameters: ["language": "en"])
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: f.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.root.path) }
        let result = try await f.registry.confirmAndExecute(token: XCTUnwrap(pending.confirmationToken), confirmed: true)
        XCTAssertFalse(result.success)
        XCTAssertFalse(result.verified)
        XCTAssertEqual(try VLMStore.loadPreferences(from: f.model.vlmPreferencesURL), before)
        XCTAssertEqual(f.model.vlmPreferences, before)
        XCTAssertEqual(f.model.actaAnalytics.aiClient.configuration().preferredLanguage, .ru)
    }
}

@MainActor
private final class ConfigLanguageStorage: LanguageSettingsStorage {
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String, forKey key: String) { values[key] = value }
}
