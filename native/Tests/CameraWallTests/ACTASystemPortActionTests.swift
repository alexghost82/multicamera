import CameraCore
import Foundation
import XCTest
@testable import CameraWall

private actor SyntheticSystemProvider: ACTASystemSettingsProvider {
    var config = WallConfiguration()
    var writes = 0
    func loadConfiguration() -> WallConfiguration { config }
    func saveConfiguration(_ config: WallConfiguration) { self.config = config; writes += 1 }
    func snapshot() -> (WallConfiguration, Int) { (config, writes) }
}

@MainActor
final class ACTASystemPortActionTests: XCTestCase {
    func testInvalidNumericInputsNeverWriteOrVerify() async throws {
        let provider = SyntheticSystemProvider()
        let action = SettingsUpdateSystemAction(settingsProvider: provider)
        let invalid: [[String: String]] = [
            ["columns": "not-a-number", "detection_fps": "3"],
            ["columns": "1.5"], ["stale_threshold_ms": "nan"],
            ["detection_fps": "2.5"], ["detection_fps": "inf"],
            ["detection_threshold": "not-a-number"], ["detection_threshold": "nan"],
            ["detection_threshold": "inf"], ["detection_threshold": "1e9999"]
        ]
        for parameters in invalid {
            do {
                _ = try await action.execute(parameters: parameters, context: ACTAActionContext())
                XCTFail("Invalid numeric input must not execute: \(parameters)")
            } catch {}
            do {
                _ = try await action.verify(parameters: parameters, context: ACTAActionContext())
                XCTFail("Invalid numeric input must not verify: \(parameters)")
            } catch {}
        }
        let (config, writes) = await provider.snapshot()
        XCTAssertEqual(config, WallConfiguration())
        XCTAssertEqual(writes, 0)
    }

    func testNumericInputsStillClampToSupportedRanges() async throws {
        let provider = SyntheticSystemProvider()
        let action = SettingsUpdateSystemAction(settingsProvider: provider)
        let parameters = ["columns": "99", "detection_fps": "0",
                          "stale_threshold_ms": "1", "detection_threshold": "5"]
        let result = try await action.execute(parameters: parameters, context: ACTAActionContext())
        XCTAssertTrue(result.success)
        let verified = try await action.verify(parameters: parameters, context: ACTAActionContext())
        XCTAssertTrue(verified)
        let (config, writes) = await provider.snapshot()
        XCTAssertEqual(config.columns, 16)
        XCTAssertEqual(config.detectionFPS, 1)
        XCTAssertEqual(config.staleAfterMilliseconds, 200)
        XCTAssertEqual(config.detectionThreshold, 0.9)
        XCTAssertEqual(writes, 1)
    }

    func testPortsAndExecutableAreNotAdvertisedOrAccepted() async throws {
        let provider = SyntheticSystemProvider()
        let action = SettingsUpdateSystemAction(settingsProvider: provider)
        let registry = ACTAActionRegistry()
        await registry.register(ACTASystemLanguageAction(settingsProvider: provider,
            languageSettings: LanguageSettings(storage: InMemoryLanguageStorage())))
        for key in ["api_port", "rtsp_port", "go2rtc_path"] {
            XCTAssertFalse(action.parameters.contains { $0.name == key })
            let result = try await registry.execute(actionID: "settings.update_system",
                parameters: [key: "12000", "columns": "6"])
            XCTAssertFalse(result.success)
            XCTAssertFalse(result.requiresOperatorConfirmation)
            do {
                _ = try await action.execute(parameters: [key: "12000"], context: ACTAActionContext(isConfirmed: true))
                XCTFail("Direct execution must reject unsupported settings")
            } catch {}
            do {
                _ = try await action.verify(parameters: [key: "12000"], context: ACTAActionContext())
                XCTFail("Unsupported settings must not verify")
            } catch {}
        }
        let (config, writes) = await provider.snapshot()
        XCTAssertEqual(config, WallConfiguration())
        XCTAssertEqual(writes, 0)
    }

    func testWallProviderFailsClosedForPortsAndDetectsExistingDiskMismatch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(".system-port-fixture-\(UUID().uuidString)", isDirectory: true)
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous); try? FileManager.default.removeItem(at: root) }
        try IsolatedWallFixtureSupport.prepare(root)
        try CameraFeaturePreferencesStore.save(CameraFeaturePreferences(enabledFeatures: []),
            to: root.appendingPathComponent("features.json"))
        var ai = VLMPreferences()
        ai.actaBackendMode = .dryRun
        try VLMStore.save(ai, to: root.appendingPathComponent("vlm.json"))
        let configURL = root.appendingPathComponent("cameras.json")
        let model = WallModel(configURL: configURL, workerMode: false, poseModelURL: root.appendingPathComponent("unused.mlmodel"),
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
        defer { model.shutdown() }
        IsolatedWallFixtureSupport.assertSafe(model)
        let registry = ACTAActionRegistry()
        await registry.register(ACTASystemLanguageAction(settingsProvider: WallSystemSettingsProvider(model: model),
            languageSettings: LanguageSettings(storage: InMemoryLanguageStorage())))
        let original = model.config
        let denied = try await registry.execute(actionID: "settings.update_system",
            parameters: ["api_port": "12000", "rtsp_port": "12001"])
        XCTAssertFalse(denied.success)
        XCTAssertFalse(denied.requiresOperatorConfirmation)
        XCTAssertEqual(try ConfigurationStore.load(from: configURL), original)

        var external = original
        external.columns = 8
        try ConfigurationStore.save(external, to: configURL)
        let deniedAfterChange = try await registry.execute(actionID: "settings.update_system", parameters: ["api_port": "12000"])
        XCTAssertFalse(deniedAfterChange.success)
        XCTAssertFalse(deniedAfterChange.requiresOperatorConfirmation)
        let mismatch = try await registry.execute(actionID: "settings.update_system", parameters: ["columns": "6"])
        XCTAssertFalse(mismatch.success)
        XCTAssertEqual(try ConfigurationStore.load(from: configURL), external)
        XCTAssertFalse(model.running)
    }
}
