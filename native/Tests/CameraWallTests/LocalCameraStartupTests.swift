import Foundation
import Testing
@testable import CameraWall
import CameraCore

struct LocalCameraStartupTests {
    @Test @MainActor func packagedAppPrefersBundledGo2RTC() throws {
        let directory = fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundleURL = directory.appendingPathComponent("CameraWall.app", isDirectory: true)
        let helper = bundleURL.appendingPathComponent("Contents/Helpers/go2rtc")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

        #expect(Go2RTC.executablePath(configuredPath: "/custom/go2rtc", bundleURL: bundleURL) == helper.path)
        #expect(Go2RTC.executablePath(configuredPath: "/custom/go2rtc", bundleURL: directory) == "/custom/go2rtc")
    }

    @Test @MainActor func localOnlyWallDoesNotRequireRelay() async throws {
        let directory = fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let previousModels = ModelSelectionPreferences(
            enabled: Set(LocalModelService.allCases.filter { ModelSelectionRegistry.isEnabled($0) }),
            paths: Dictionary(uniqueKeysWithValues: LocalModelService.allCases.compactMap { service in
                ModelSelectionRegistry.path(service).map { (service, $0.path) }
            }))
        defer { ModelSelectionRegistry.update(previousModels) }
        let url = directory.appendingPathComponent("cameras.json")
        var config = WallConfiguration()
        config.go2rtcPath = "/nonexistent/go2rtc"
        // A disabled device avoids requesting hardware access during automated tests.
        config.cameras = [Camera(name: "Mac", substream: "", enabled: false, localDeviceID: "test")]
        try ConfigurationStore.save(config, to: url)
        let root = url.deletingLastPathComponent()
        try ModelSelectionPreferences(enabled: []).save(to: root.appendingPathComponent("model-preferences.json"))
        let features = CameraFeatureCoordinator(preferencesURL: root.appendingPathComponent("features.json"),
            databaseURL: root.appendingPathComponent("features.sqlite3"))
        try features.savePreferences(CameraFeaturePreferences(enabledFeatures: [.operationalAlerts]))
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .dryRun), transport: { _ in
            Issue.record("Unexpected network request")
            throw URLError(.notConnectedToInternet)
        }, keyProvider: { _ in
            Issue.record("Unexpected AI credential access")
            return nil
        })
        let model = WallModel(configURL: url, workerMode: false,
            poseModelURL: root.appendingPathComponent("fake-pose.mlmodel"),
            trackingStoreURL: root.appendingPathComponent("tracking.sqlite3"),
            featureCoordinator: features, analyticsDirectoryURL: root.appendingPathComponent("analytics"),
            agentClient: client, cameraMemoryStore: CameraMemoryStore(url: root.appendingPathComponent("frames")),
            operationsWatchURL: root.appendingPathComponent("watches.json"),
            missionStoreURL: root.appendingPathComponent("missions.json"),
            cameraCredentialStore: StartupTestCredentials(),
            operationsPreferencesURL: root.appendingPathComponent("operations.json"),
            alertClipStore: CriticalAlertClipStore(url: root.appendingPathComponent("clips")),
            languageSettings: LanguageSettings(storage: StartupTestLanguageStorage()),
            monitorHistoryURL: root.appendingPathComponent("monitor.json"),
            analyticsModelDiscovery: AnalyticsModelDiscovery(modelURL: { _ in nil },
                integrity: { _ in (hash: "synthetic", sizeBytes: 0) }))
        defer { model.shutdown() }
        #expect(LocalModelService.allCases.allSatisfy { !ModelSelectionRegistry.isEnabled($0) })
        #expect(!model.featurePreferences.enabledFeatures.contains(.independentWatcher))
        model.start()
        for _ in 0..<100 {
            if !model.connecting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        model.refresh()
        #expect(model.running)
        #expect(!model.connecting)
        #expect(model.error == nil)
        #expect(model.tiles[config.cameras[0].id]?.session == nil)
    }

    private func fixtureDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(".startup-test-\(UUID().uuidString)", isDirectory: true)
    }
}

private struct StartupTestCredentials: CameraCredentialStore {
    private struct UnexpectedAccess: Error {}
    func read(_ id: UUID) throws -> Credentials? { Issue.record("Unexpected credential read"); throw UnexpectedAccess() }
    func save(_ credentials: Credentials, for id: UUID) throws { Issue.record("Unexpected credential save"); throw UnexpectedAccess() }
    func remove(_ id: UUID) throws { Issue.record("Unexpected credential removal"); throw UnexpectedAccess() }
}

@MainActor
private final class StartupTestLanguageStorage: LanguageSettingsStorage {
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String, forKey key: String) { values[key] = value }
}
