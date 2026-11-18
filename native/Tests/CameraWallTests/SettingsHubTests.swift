import XCTest
import CameraCore
@testable import CameraWall

@MainActor
final class SettingsHubTests: XCTestCase {
    func testAllAnalyticsSwitchesAndScalarsHaveEditors() throws {
        // Encoding is the persisted contract; exercise every editor key path and compare changed keys.
        let baseline = VideoAnalyticsSettings()
        let before = try object(baseline)
        var covered = Set<String>()
        for field in AnalyticsSettingsFields.switches {
            var value = baseline; value[keyPath: field.path].toggle()
            covered.formUnion(try changed(before, object(value)))
        }
        for field in AnalyticsSettingsFields.numbers {
            var value = baseline; value[keyPath: field.path] += 0.001
            covered.formUnion(try changed(before, object(value)))
        }
        for field in AnalyticsSettingsFields.integers {
            var value = baseline; value[keyPath: field.path] += 1
            covered.formUnion(try changed(before, object(value)))
        }
        XCTAssertEqual(covered, Set(before.keys).subtracting(["executionMode", "sensitivityProfile", "overlaySettings", "cameraOverrides"]))
        XCTAssertEqual(AnalyticsSettingsFields.overlays.count, try object(AnalyticsOverlaySettings()).count)
        XCTAssertEqual(AnalyticsSettingsFields.cameraSwitches.count, 11)
    }

    func testModelSelectionsPersistAndDisabledRuntimeDoesNotLoad() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("models.json")
        var preferences = ModelSelectionPreferences(); preferences.enabled = [.yolo]
        try preferences.save(to: url)
        XCTAssertEqual(try ModelSelectionPreferences.load(from: url), preferences)
        let calls = SettingsModelLoadRecorder()
        let runtime = LocalModelRuntime { service, _ in await calls.record(service) }
        await runtime.start(modelPath: "/synthetic", enabled: preferences.enabled).value
        let loaded = await calls.values()
        XCTAssertEqual(loaded, [.yolo])
        XCTAssertEqual(runtime.states[.pose], .disabled)
        XCTAssertEqual(runtime.states[.qwen], .disabled)
        await runtime.start(modelPath: "/synthetic", enabled: Set(LocalModelService.allCases)).value
        XCTAssertEqual(runtime.states[.pose], .ready)
    }

    func testDisabledModelsRejectInferenceBeforeLoading() async throws {
        defer { ModelSelectionRegistry.update(ModelSelectionPreferences()) }
        var preferences = ModelSelectionPreferences(); preferences.enabled = []
        ModelSelectionRegistry.update(preferences)
        XCTAssertThrowsError(try ModelSelectionRegistry.require(.yolo))
        XCTAssertNil(ONNXSegmentationEncoder.modelURL)
        XCTAssertNil(ONNXReIDEncoder.modelURL(for: .person))
        do { try await LocalVLMClient(model: "/does-not-exist").prepare(); XCTFail("Disabled VLM must reject preparation") }
        catch { XCTAssertTrue(error.localizedDescription.contains("disabled")) }
    }

    func testNewAIAndAdvancedPreferencesRoundTripAndRejectInvalidValues() throws {
        var ai = VLMPreferences()
        ai.cloudNanoModel = "test-nano"; ai.actaBackupRelayURL = "http://127.0.0.1:8123/v1"
        ai.dailyBudgetLimitUSD = 4; ai.monthlyBudgetLimitUSD = 40; ai.privacyBlurPlatesInCloud = false
        XCTAssertEqual(try JSONDecoder().decode(VLMPreferences.self, from: JSONEncoder().encode(ai)), ai)
        ai.dailyBudgetLimitUSD = .nan
        XCTAssertThrowsError(try ai.validate())
        var runtime = AdvancedRuntimePreferences(); runtime.storage.maxCropsPerIdentity = 25; runtime.capture.intervalSeconds = 6
        XCTAssertEqual(try JSONDecoder().decode(AdvancedRuntimePreferences.self, from: JSONEncoder().encode(runtime)), runtime)
        runtime.fall.emaAlpha = 0
        XCTAssertThrowsError(try runtime.validate())
    }

    func testMalformedZonesAndCameraOverridesAreRejected() {
        var settings = VideoAnalyticsSettings()
        let id = UUID()
        settings.cameraOverrides[id] = CameraAnalyticsOverride(cameraID: id, customSamplingFPS: -1)
        XCTAssertThrowsError(try settings.validate())
        settings.cameraOverrides[id] = CameraAnalyticsOverride(cameraID: id, restrictedZones: [.rectangle(name: "", x: 0, y: 0, width: 1, height: 1)])
        XCTAssertThrowsError(try settings.validate())
        settings.cameraOverrides[id]?.restrictedZones[0].name = "Entrance"
        XCTAssertNoThrow(try settings.validate())
    }

    func testCentralSettingsApplyPortsAndAIConfigurationWithoutChangingCameras() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(".settings-hub-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let previousModels = ModelSelectionPreferences(
            enabled: Set(LocalModelService.allCases.filter { ModelSelectionRegistry.isEnabled($0) }),
            paths: Dictionary(uniqueKeysWithValues: LocalModelService.allCases.compactMap { service in
                ModelSelectionRegistry.path(service).map { (service, $0.path) }
            }))
        defer { try? FileManager.default.removeItem(at: directory); ModelSelectionRegistry.update(previousModels) }
        let configURL = directory.appendingPathComponent("cameras.json")
        try ConfigurationStore.save(WallConfiguration(), to: configURL)
        var models = ModelSelectionPreferences(); models.enabled = []
        try models.save(to: directory.appendingPathComponent("model-preferences.json"))
        var aiPreferences = VLMPreferences(); aiPreferences.actaBackendMode = .dryRun
        try VLMStore.save(aiPreferences, to: directory.appendingPathComponent("vlm.json"))
        let features = CameraFeatureCoordinator(preferencesURL: directory.appendingPathComponent("features.json"),
            databaseURL: directory.appendingPathComponent("features.sqlite"))
        try features.savePreferences(CameraFeaturePreferences(enabledFeatures: []))
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .dryRun), transport: { _ in
            XCTFail("Unexpected network request")
            throw URLError(.notConnectedToInternet)
        }, keyProvider: { _ in
            XCTFail("Unexpected AI credential access")
            return nil
        })
        let model = WallModel(configURL: configURL,
            poseModelURL: directory.appendingPathComponent("fake-pose.mlmodel"),
            trackingStoreURL: directory.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: features,
            analyticsDirectoryURL: directory.appendingPathComponent("analytics"),
            agentClient: client,
            cameraMemoryStore: CameraMemoryStore(url: directory.appendingPathComponent("frames")),
            operationsWatchURL: directory.appendingPathComponent("watches.json"),
            missionStoreURL: directory.appendingPathComponent("missions.json"),
            cameraCredentialStore: SettingsTestCredentials(),
            operationsPreferencesURL: directory.appendingPathComponent("operations.json"),
            alertClipStore: CriticalAlertClipStore(url: directory.appendingPathComponent("clips")),
            languageSettings: LanguageSettings(storage: InMemoryLanguageStorage()),
            monitorHistoryURL: directory.appendingPathComponent("monitor.json"),
            analyticsModelDiscovery: IsolatedWallFixtureSupport.modelDiscovery)
        defer { model.shutdown() }
        XCTAssertTrue(model.config.cameras.isEmpty)
        XCTAssertTrue(model.featurePreferences.enabledFeatures.isEmpty)
        XCTAssertFalse(model.running)
        var system = model.config
        system.apiPort = 22001; system.rtspPort = 22002; system.columns = 7
        let cameras = system.cameras
        try model.saveSystemSettings(system)
        XCTAssertEqual(model.config.apiPort, 22001)
        XCTAssertEqual(try ConfigurationStore.load(from: directory.appendingPathComponent("cameras.json")).rtspPort, 22002)
        XCTAssertEqual(model.config.cameras, cameras)
        var ai = model.vlmPreferences
        ai.cloudNanoModel = "custom-nano"; ai.dailyBudgetLimitUSD = 3; ai.monthlyBudgetLimitUSD = 15
        ai.actaBackupRelayURL = "http://127.0.0.1:8418/v1"
        try model.saveVLMPreferences(ai)
        let applied = model.actaAnalytics.aiClient.configuration()
        XCTAssertEqual(applied.tierModelNames[ACTAAITier.nano.rawValue], "custom-nano")
        XCTAssertEqual(applied.dailyBudgetLimitUSD, 3)
        XCTAssertEqual(applied.backupRelayURL, ai.actaBackupRelayURL)
        var runtime = model.runtimePreferences; runtime.storage.maxCropsPerIdentity = 17
        try model.saveRuntimePreferences(runtime)
        XCTAssertEqual(model.actaAnalytics.janitorPolicy.maxCropsPerIdentity, 17)
    }

    private func object<T: Encodable>(_ value: T) throws -> [String: NSObject] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: NSObject])
    }
    private func changed(_ before: [String: NSObject], _ after: [String: NSObject]) -> Set<String> {
        Set(before.keys.filter { before[$0] != after[$0] })
    }
}

private struct SettingsTestCredentials: CameraCredentialStore {
    private struct UnexpectedAccess: Error {}
    func read(_ id: UUID) throws -> Credentials? { XCTFail("Unexpected credential read"); throw UnexpectedAccess() }
    func save(_ credentials: Credentials, for id: UUID) throws { XCTFail("Unexpected credential save"); throw UnexpectedAccess() }
    func remove(_ id: UUID) throws { XCTFail("Unexpected credential removal"); throw UnexpectedAccess() }
}

private actor SettingsModelLoadRecorder {
    private var services: [LocalModelService] = []
    func record(_ value: LocalModelService) { services.append(value) }
    func values() -> [LocalModelService] { services }
}
