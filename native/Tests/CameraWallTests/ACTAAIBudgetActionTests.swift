import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTAAIBudgetActionTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let model: WallModel
        let registry: ACTAActionRegistry
        let previousModels: ModelSelectionPreferences
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-budget-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let previousModels = ModelSelectionPreferences(
            enabled: Set(LocalModelService.allCases.filter { ModelSelectionRegistry.isEnabled($0) }),
            paths: Dictionary(uniqueKeysWithValues: LocalModelService.allCases.compactMap { service in
                ModelSelectionRegistry.path(service).map { (service, $0.path) }
            }))
        try ConfigurationStore.save(WallConfiguration(), to: root.appendingPathComponent("cameras.json"))
        try CameraFeaturePreferencesStore.save(CameraFeaturePreferences(enabledFeatures: []), to: root.appendingPathComponent("features.json"))
        var models = ModelSelectionPreferences()
        models.enabled = []
        try models.save(to: root.appendingPathComponent("model-preferences.json"))
        var preferences = VLMPreferences()
        preferences.actaBackendMode = .dryRun
        preferences.intervalSeconds = 123
        preferences.cloudNanoModel = "fixture-nano"
        try VLMStore.save(preferences, to: root.appendingPathComponent("vlm.json"))
        let client = ACTAAIClient(config: WallModel.makeACTAAIConfiguration(
            from: preferences, featurePreferences: CameraFeaturePreferences(enabledFeatures: [])),
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
            languageSettings: LanguageSettings(storage: BudgetLanguageStorage()),
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

    func testConfirmationParityAndPreservingOtherSettings() async throws {
        let f = try await fixture()
        defer { cleanup(f) }
        let tools = try await ACTAAnalyticsCoordinator.registryTools(registry: f.registry)
        XCTAssertTrue(tools.contains { $0.name == "acta__settings__update_ai_budget" })
        let before = f.model.vlmPreferences
        let pending = try await f.registry.executeJSON(actionID: "settings.update_ai_budget",
            argumentsJSON: #"{"blurFaces":false,"dailyBudgetUSD":10,"monthlyBudgetUSD":20}"#)
        XCTAssertTrue(pending.requiresOperatorConfirmation)
        XCTAssertTrue(pending.summary.contains("resets schedule and may prepare models"))
        XCTAssertEqual(f.model.vlmPreferences, before)
        let token = try XCTUnwrap(pending.confirmationToken)
        let result = try await f.registry.confirmAndExecute(token: token, confirmed: true)
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertTrue(result.verified)
        var expected = before
        expected.privacyBlurFacesInCloud = false
        expected.dailyBudgetLimitUSD = 10
        expected.monthlyBudgetLimitUSD = 20
        XCTAssertEqual(f.model.vlmPreferences, expected)
        XCTAssertEqual(try VLMStore.loadPreferences(from: f.model.vlmPreferencesURL), expected)
        let runtime = try XCTUnwrap(f.model.actaAnalytics?.aiClient.configuration())
        XCTAssertFalse(runtime.privacyBlurFacesInCloud)
        XCTAssertTrue(runtime.privacyBlurPlatesInCloud)
        XCTAssertEqual(runtime.dailyBudgetLimitUSD, 10)
        XCTAssertEqual(runtime.monthlyBudgetLimitUSD, 20)
        XCTAssertFalse(runtime.allowExternalAI)
        XCTAssertFalse(result.outputJSON.contains("fixture-nano"))

        var guiDraft = expected
        guiDraft.privacyBlurPlatesInCloud = false
        try f.model.saveVLMPreferences(guiDraft)
        XCTAssertEqual(try VLMStore.loadPreferences(from: f.model.vlmPreferencesURL), guiDraft)
        XCTAssertFalse(try XCTUnwrap(f.model.actaAnalytics?.aiClient.configuration()).privacyBlurPlatesInCloud)
    }

    func testInvalidInputsAndRejectedOrDirectUnconfirmedActionDoNotMutate() async throws {
        let f = try await fixture()
        defer { cleanup(f) }
        let before = f.model.vlmPreferences
        for json in ["{}", #"{"blurFaces":"false"}"#, #"{"dailyBudgetUSD":true}"#,
                     #"{"dailyBudgetUSD":-1}"#, #"{"unknown":1}"#] {
            let result = try await f.registry.executeJSON(actionID: "settings.update_ai_budget", argumentsJSON: json)
            XCTAssertFalse(result.success, json)
            XCTAssertFalse(result.requiresOperatorConfirmation, json)
        }
        let direct = try await WallAIBudgetAction(model: f.model).execute(parameters: ["blurFaces": "false"], context: ACTAActionContext())
        XCTAssertFalse(direct.success)
        let pending = try await f.registry.execute(actionID: "settings.update_ai_budget", parameters: ["blurPlates": "false"])
        let rejected = try await f.registry.confirmAndExecute(token: XCTUnwrap(pending.confirmationToken), confirmed: false)
        XCTAssertFalse(rejected.success)
        let invalidBudget = try await f.registry.execute(actionID: "settings.update_ai_budget", parameters: ["dailyBudgetUSD": "401"])
        let result = try await f.registry.confirmAndExecute(token: XCTUnwrap(invalidBudget.confirmationToken), confirmed: true)
        XCTAssertFalse(result.success)
        XCTAssertEqual(f.model.vlmPreferences, before)
        XCTAssertEqual(try VLMStore.loadPreferences(from: f.model.vlmPreferencesURL), before)
    }

    func testChangedDiskOrRuntimeFailsClosed() async throws {
        let f = try await fixture()
        defer { cleanup(f) }
        let before = f.model.vlmPreferences
        let pending = try await f.registry.execute(actionID: "settings.update_ai_budget", parameters: ["blurFaces": "false"])
        var changed = before
        changed.intervalSeconds = 124
        try VLMStore.save(changed, to: f.model.vlmPreferencesURL)
        let stale = try await f.registry.confirmAndExecute(token: XCTUnwrap(pending.confirmationToken), confirmed: true)
        XCTAssertFalse(stale.success)
        XCTAssertEqual(try VLMStore.loadPreferences(from: f.model.vlmPreferencesURL), changed)
        XCTAssertEqual(f.model.vlmPreferences, before)
        try VLMStore.save(before, to: f.model.vlmPreferencesURL)
        let client = try XCTUnwrap(f.model.actaAnalytics?.aiClient)
        var runtime = client.configuration()
        runtime.privacyBlurFacesInCloud = false
        client.updateConfiguration(runtime)
        let action = WallAIBudgetAction(model: f.model)
        let verified = try await action.verify(parameters: ["monthlyBudgetUSD": "400"], context: ACTAActionContext())
        XCTAssertFalse(verified)
        let next = try await f.registry.execute(actionID: "settings.update_ai_budget", parameters: ["monthlyBudgetUSD": "500"])
        let mismatch = try await f.registry.confirmAndExecute(token: XCTUnwrap(next.confirmationToken), confirmed: true)
        XCTAssertFalse(mismatch.success)
        XCTAssertEqual(try VLMStore.loadPreferences(from: f.model.vlmPreferencesURL), before)
        client.updateConfiguration(WallModel.makeACTAAIConfiguration(from: before, featurePreferences: f.model.featurePreferences))
        var changedPolicy = f.model.featurePreferences
        changedPolicy.allowExternalAI = true
        try CameraFeaturePreferencesStore.save(changedPolicy, to: f.root.appendingPathComponent("features.json"))
        let last = try await f.registry.execute(actionID: "settings.update_ai_budget", parameters: ["blurFaces": "false"])
        let policyMismatch = try await f.registry.confirmAndExecute(token: XCTUnwrap(last.confirmationToken), confirmed: true)
        XCTAssertFalse(policyMismatch.success)
        XCTAssertEqual(try VLMStore.loadPreferences(from: f.model.vlmPreferencesURL), before)
    }
}

@MainActor
private final class BudgetLanguageStorage: LanguageSettingsStorage {
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String, forKey key: String) { values[key] = value }
}
