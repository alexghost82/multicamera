import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTASettingsActionAdapterTests: XCTestCase {
    private func fixture() throws -> (URL, WallModel, UUID) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(".settings-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        var config = WallConfiguration()
        let camera = Camera(name: "Fixture", substream: "rtsp://fixture.invalid/fixture", enabled: false)
        config.cameras = [camera]
        try ConfigurationStore.save(config, to: root.appendingPathComponent("cameras.json"))
        try ModelSelectionPreferences(enabled: []).save(to: root.appendingPathComponent("model-preferences.json"))
        try CameraFeaturePreferencesStore.save(CameraFeaturePreferences(enabledFeatures: []),
            to: root.appendingPathComponent("features.json"))
        var ai = VLMPreferences()
        ai.actaBackendMode = .dryRun
        try VLMStore.save(ai, to: root.appendingPathComponent("vlm.json"))
        let poseURL = root.appendingPathComponent("fake-pose.mlmodel")
        let model = WallModel(configURL: root.appendingPathComponent("cameras.json"),
            workerMode: false, poseModelURL: poseURL,
            trackingStoreURL: root.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: root.appendingPathComponent("features.json"), databaseURL: root.appendingPathComponent("features.sqlite")),
            analyticsDirectoryURL: root.appendingPathComponent("analytics"),
            agentClient: IsolatedWallFixtureSupport.client(),
            cameraMemoryStore: CameraMemoryStore(url: root.appendingPathComponent("frames")),
            operationsWatchURL: root.appendingPathComponent("watches.json"), missionStoreURL: root.appendingPathComponent("missions.json"),
            cameraCredentialStore: ACTAIsolatedCredentials(),
            operationsPreferencesURL: root.appendingPathComponent("operations.json"),
            alertClipStore: CriticalAlertClipStore(url: root.appendingPathComponent("clips")),
            languageSettings: LanguageSettings(storage: InMemoryLanguageStorage()),
            monitorHistoryURL: root.appendingPathComponent("monitor.json"),
            analyticsModelDiscovery: AnalyticsModelDiscovery(modelURL: { _ in nil }, integrity: { url in
                XCTAssertEqual(url, poseURL)
                return (hash: "synthetic", sizeBytes: 0)
            }))
        XCTAssertFalse(model.running)
        XCTAssertFalse(model.config.cameras.contains(where: \.enabled))
        XCTAssertNil(model.tiles[camera.id]?.session)
        XCTAssertTrue(model.featurePreferences.enabledFeatures.isEmpty)
        XCTAssertTrue(LocalModelService.allCases.allSatisfy { !ModelSelectionRegistry.isEnabled($0) })
        return (root, model, camera.id)
    }

    private func approved(_ registry: ACTAActionRegistry, _ action: String, _ args: [String: String]) async throws -> ACTAActionResult {
        let proposed = try await registry.execute(actionID: action, parameters: args)
        XCTAssertTrue(proposed.requiresOperatorConfirmation, proposed.summary)
        return try await registry.confirmAndExecute(token: XCTUnwrap(proposed.confirmationToken), confirmed: true)
    }

    func testRetryActionIsRegisteredWithoutStartingModels() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let tools = try await ACTAAnalyticsCoordinator.registryTools(registry: registry)
        XCTAssertTrue(tools.contains { $0.name == "acta__settings__retry_model_loading" })
        XCTAssertTrue(tools.contains { $0.name == "acta__analysis__set_section" })
        let result = try await registry.execute(actionID: "settings.retry_model_loading", parameters: [:])
        XCTAssertFalse(result.success)
        XCTAssertTrue(model.modelRuntime.states.values.allSatisfy { $0 == .waiting })
    }

    func testAllGUIFallFieldsAndCropFieldsPersistThroughRuntimeService() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let original = model.runtimePreferences
        let fall = ["torsoAngleThresholdDegrees": "60", "aspectRatioThreshold": "1.3", "heightCollapseThreshold": "0.5",
            "sittingHeightThreshold": "0.8", "crouchingHeightThreshold": "0.6", "lowFrameRateThreshold": "2",
            "lowFrameRatePersistenceSeconds": "3", "velocityFeatureMinimumFPS": "6", "walkingSpeedBodyHeightsPerSecond": "0.4",
            "runningSpeedBodyHeightsPerSecond": "1.5", "controlledSitBeforeLieSeconds": "2",
            "controlledLieDownMaxDropSpeedBodyHeightsPerSecond": "0.3", "emaAlpha": "0.1", "lowConfidenceFloor": "0.2",
            "matchIoUThreshold": "0.3", "relinkMaximumGapSeconds": "4", "relinkMaximumDiagonalRatio": "3",
            "frameIntervalSmoothing": "0.3", "minimumConfirmingSamples": "3", "minimumBaselineSamples": "4", "recoverySamples": "3", "maximumTracks": "128"]
        let updated = try await registry.execute(actionID: "settings.update_runtime_fall", parameters: fall)
        XCTAssertTrue(updated.success, updated.summary)
        let value = try AdvancedRuntimePreferences.load(from: model.runtimePreferencesURL)
        for field in AdvancedRuntimeSettingsEditor.numbers {
            XCTAssertNotEqual(value.fall[keyPath: field.path], original.fall[keyPath: field.path], field.title)
        }
        for field in AdvancedRuntimeSettingsEditor.integers {
            XCTAssertNotEqual(value.fall[keyPath: field.path], original.fall[keyPath: field.path], field.title)
        }
        XCTAssertEqual(value.fall.primaryConfidence, original.fall.primaryConfidence)
        XCTAssertEqual(value.fall.keypointConfidence, original.fall.keypointConfidence)
        XCTAssertEqual(value.storage, original.storage)
        let cropped = try await registry.execute(actionID: "settings.update_runtime_crop", parameters: [
            "bootstrapSeconds": "2", "intervalSeconds": "5", "movementFraction": "0.4", "inheritMaxAge": "3",
            "inheritMinIoU": "0.6", "staleTrackTTL": "40", "cropWindowSeconds": "20", "cropTopK": "5", "cropImprovementRatio": "1.1"])
        XCTAssertTrue(cropped.success, cropped.summary)
        let saved = try AdvancedRuntimePreferences.load(from: model.runtimePreferencesURL)
        XCTAssertEqual(saved, model.runtimePreferences)
        XCTAssertEqual(saved.capture.bootstrapSeconds, 2)
        XCTAssertEqual(saved.capture.intervalSeconds, 5)
        XCTAssertEqual(saved.capture.movementFraction, 0.4)
        XCTAssertEqual(saved.capture.inheritMaxAge, 3)
        XCTAssertEqual(saved.capture.inheritMinIoU, 0.6)
        XCTAssertEqual(saved.capture.staleTrackTTL, 40)
        XCTAssertEqual(saved.cropWindowSeconds, 20)
        XCTAssertEqual(saved.cropTopK, 5)
        XCTAssertEqual(saved.cropImprovementRatio, 1.1)
        XCTAssertEqual(saved.fall, value.fall)
        let bytes = try Data(contentsOf: model.runtimePreferencesURL)
        for (action, args) in [("settings.update_runtime_fall", ["emaAlpha": "2"]),
                               ("settings.update_runtime_fall", ["primaryConfidence": "0.8"]),
                               ("settings.update_runtime_fall", ["maximumTracks": "4097"]),
                               ("settings.update_runtime_crop", ["inheritMinIoU": "1.1"]),
                               ("settings.update_runtime_crop", ["cropTopK": "4.5"])] {
            let result = try await registry.execute(actionID: action, parameters: args)
            XCTAssertFalse(result.success)
            XCTAssertEqual(try Data(contentsOf: model.runtimePreferencesURL), bytes)
        }
    }

    func testReviewedStorageAndMemoryPolicyMatchDiskWithoutClaimingCleanup() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let proposed = try await registry.execute(actionID: "settings.update_runtime_storage", parameters: ["maxMediaDiskMB": "4096"])
        XCTAssertTrue(proposed.requiresOperatorConfirmation)
        XCTAssertEqual(model.runtimePreferences.storage.maxMediaDiskMB, 2048)
        let rejected = try await registry.confirmAndExecute(token: XCTUnwrap(proposed.confirmationToken), confirmed: false)
        XCTAssertFalse(rejected.success)
        let storage = try await approved(registry, "settings.update_runtime_storage", ["maxMediaDiskMB": "4096", "minFreeDiskGB": "3",
            "maxCropsPerIdentity": "50", "dataSaverEnabled": "true", "trackImageRetentionDays": "10", "logRetentionDays": "12"])
        XCTAssertTrue(storage.success, storage.summary)
        let saved = try AdvancedRuntimePreferences.load(from: model.runtimePreferencesURL)
        XCTAssertEqual(saved.storage, model.actaAnalytics.janitorPolicy)
        XCTAssertEqual(saved.storage.maxMediaDiskMB, 4096)
        XCTAssertTrue(saved.storage.dataSaverEnabled)
        let policy = try await approved(registry, "settings.update_memory_policy", ["retainFullFrames": "true", "retentionDays": "90"])
        XCTAssertTrue(policy.success, policy.summary)
        XCTAssertTrue(model.featurePreferences.retainFullFrames)
        XCTAssertEqual(model.featurePreferences.retentionDays, 90)
        XCTAssertFalse(model.featurePreferences.enabledFeatures.contains(.chronologicalMemory), "A policy update must not silently enable a feature")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(policy.outputJSON.utf8)) as? [String: Any])
        XCTAssertEqual(object["sampled_frame_retention_days_cap"] as? Int, 7)
        let persisted = try CameraFeaturePreferencesStore.load(from: root.appendingPathComponent("features.json"))
        XCTAssertEqual(persisted, model.featurePreferences)
        let bytes = try Data(contentsOf: root.appendingPathComponent("features.json"))
        let invalid = try await approved(registry, "settings.update_memory_policy", ["retentionDays": "0"])
        XCTAssertFalse(invalid.success)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("features.json")), bytes)
    }

    func testEventsAndSchedulesPreserveUnrelatedBackendAndPermissions() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, camera) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let before = model.vlmPreferences
        let events = try await registry.execute(actionID: "settings.update_events_alerts", parameters: [
            "personCountAlertsEnabled": "true", "personThreshold": "12", "holdSeconds": "5", "cooldownSeconds": "120", "criticalSoundEnabled": "true"])
        XCTAssertTrue(events.success, events.summary)
        let ops = try OperationsPreferencesStore.load(from: model.operationsPreferencesURL)
        XCTAssertEqual(ops, model.operationsPreferences)
        XCTAssertEqual(ops.personThreshold, 12)
        XCTAssertEqual(ops.holdSeconds, 5)
        XCTAssertEqual(ops.cooldownSeconds, 120)
        XCTAssertTrue(ops.personCountAlertsEnabled)
        XCTAssertTrue(ops.criticalSoundEnabled)
        let schedules = try await approved(registry, "settings.update_schedules", ["scheduleEnabled": "true", "intervalSeconds": "60",
            "analyzeAllEnabledCameras": "false", "camera_ids": camera.uuidString])
        XCTAssertTrue(schedules.success, schedules.summary)
        let saved = try VLMStore.loadPreferences(from: model.vlmPreferencesURL)
        XCTAssertEqual(saved.scheduledCameraIDs, [camera])
        XCTAssertEqual(saved.intervalSeconds, 60)
        XCTAssertTrue(saved.scheduleEnabled)
        XCTAssertEqual(saved.actaBackendMode, before.actaBackendMode)
        XCTAssertEqual(saved.model, before.model)
        XCTAssertEqual(saved.actaVLLMBaseURL, before.actaVLLMBaseURL)
        XCTAssertEqual(saved.dailyBudgetLimitUSD, before.dailyBudgetLimitUSD)
        XCTAssertFalse(model.featurePreferences.allowExternalAI)
        XCTAssertFalse(model.running)
        let bytes = try Data(contentsOf: model.vlmPreferencesURL)
        let invalid = try await approved(registry, "settings.update_schedules", ["camera_ids": UUID().uuidString])
        XCTAssertFalse(invalid.success)
        XCTAssertEqual(try Data(contentsOf: model.vlmPreferencesURL), bytes)
    }

    func testAlertRuleLifecycleIsReviewedAndUnrelatedPreferencesSurvive() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let before = model.vlmPreferences
        let created = try await approved(registry, "settings.save_alert_rule", ["condition": "A vehicle is visible", "cooldownSeconds": "60", "priority": "critical"])
        XCTAssertTrue(created.success, created.summary)
        let rule = try XCTUnwrap(model.vlmPreferences.alertRules.first)
        XCTAssertEqual(rule.condition, "A vehicle is visible")
        XCTAssertEqual(rule.cooldownSeconds, 60)
        XCTAssertEqual(rule.priority, .critical)
        let edited = try await approved(registry, "settings.save_alert_rule", ["rule_id": rule.id.uuidString, "condition": "A red vehicle is visible", "enabled": "false"])
        XCTAssertTrue(edited.success)
        XCTAssertEqual(model.vlmPreferences.alertRules.first?.id, rule.id)
        XCTAssertEqual(model.vlmPreferences.alertRules.first?.enabled, false)
        XCTAssertEqual(model.vlmPreferences.actaBackendMode, before.actaBackendMode)
        let removed = try await approved(registry, "settings.remove_alert_rule", ["rule_id": rule.id.uuidString])
        XCTAssertTrue(removed.success)
        XCTAssertTrue(try VLMStore.loadPreferences(from: model.vlmPreferencesURL).alertRules.isEmpty)
        let oversized = try await registry.execute(actionID: "settings.save_alert_rule", parameters: ["condition": String(repeating: "x", count: 501)])
        XCTAssertFalse(oversized.requiresOperatorConfirmation)
        XCTAssertFalse(oversized.success)
    }

    func testSectionInspectionRedactsEndpointsAndReturnsUnsupportedInsteadOfInventing() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        var ai = model.vlmPreferences
        ai.actaVLLMBaseURL = "http://127.0.0.1:8000/v1?token=fixture-private"
        try model.saveVLMPreferences(ai)
        for section in ["general", "cameras", "models", "advanced", "analytics", "ai", "schedules", "missions", "events", "memory", "features", "showcase", "system"] {
            let result = try await registry.execute(actionID: "settings.get_section", parameters: ["section": section])
            XCTAssertTrue(result.success, result.summary)
            XCTAssertFalse(result.outputJSON.contains("fixture-private"))
            _ = try JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8))
        }
        let identity = try await registry.execute(actionID: "settings.get_section", parameters: ["section": "identity"])
        XCTAssertFalse(identity.success)
        XCTAssertTrue(identity.error?.contains("UNSUPPORTED") == true)
    }

    func testCorruptAndStalePreferenceFilesAreNeverOverwritten() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: model.runtimePreferencesURL)
        let bad = try await registry.execute(actionID: "settings.update_runtime_crop", parameters: ["cropTopK": "6"])
        XCTAssertFalse(bad.success)
        XCTAssertEqual(try Data(contentsOf: model.runtimePreferencesURL), corrupt)
        let inspection = try await registry.execute(actionID: "settings.get_section", parameters: ["section": "advanced"])
        XCTAssertFalse(inspection.success)
        try corrupt.write(to: root.appendingPathComponent("features.json"))
        let policy = try await approved(registry, "settings.update_memory_policy", ["retentionDays": "20"])
        XCTAssertFalse(policy.success)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("features.json")), corrupt)
        var external = model.operationsPreferences
        external.personThreshold = 20
        try OperationsPreferencesStore.save(external, to: model.operationsPreferencesURL)
        let bytes = try Data(contentsOf: model.operationsPreferencesURL)
        let stale = try await registry.execute(actionID: "settings.update_events_alerts", parameters: ["personThreshold": "30"])
        XCTAssertFalse(stale.success)
        XCTAssertEqual(try Data(contentsOf: model.operationsPreferencesURL), bytes)
    }
}
