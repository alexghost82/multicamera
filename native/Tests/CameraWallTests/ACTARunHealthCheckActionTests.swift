import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTARunHealthCheckActionTests: XCTestCase {
    private struct CredentialsFake: CameraCredentialStore {
        func read(_ id: UUID) throws -> Credentials? { XCTFail("Unexpected credential access"); return nil }
        func save(_ credentials: Credentials, for id: UUID) throws { XCTFail("Unexpected credential access") }
        func remove(_ id: UUID) throws { XCTFail("Unexpected credential access") }
    }

    private func fixture(enabled: Bool = true, failedWrites: Bool = false, failedTracking: Bool = false,
                         corruptHistory: Bool = false) throws -> (URL, WallModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try ModelSelectionPreferences(enabled: []).save(to: root.appendingPathComponent("model-preferences.json"))
        let configURL = root.appendingPathComponent("cameras.json")
        try ConfigurationStore.save(WallConfiguration(), to: configURL)
        let preferencesURL = root.appendingPathComponent("features.json")
        try CameraFeaturePreferencesStore.save(
            CameraFeaturePreferences(enabledFeatures: enabled ? [.independentWatcher] : []),
            to: preferencesURL)
        let blocker = root.appendingPathComponent("not-a-directory")
        if failedWrites || failedTracking { try Data("blocker".utf8).write(to: blocker) }
        let historyURL = failedWrites ? blocker.appendingPathComponent("history.json") : root.appendingPathComponent("history.json")
        if corruptHistory { try Data("{broken".utf8).write(to: historyURL) }
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .dryRun), transport: { _ in
            XCTFail("Unexpected network access")
            throw URLError(.notConnectedToInternet)
        }, keyProvider: { _ in
            XCTFail("Unexpected AI credential access")
            return nil
        })
        let model = WallModel(
            configURL: configURL, workerMode: false,
            poseModelURL: root.appendingPathComponent("fake-pose.mlmodel"),
            trackingStoreURL: failedWrites || failedTracking ? blocker.appendingPathComponent("tracks.sqlite") : root.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: preferencesURL,
                databaseURL: root.appendingPathComponent("features.sqlite")),
            analyticsDirectoryURL: root.appendingPathComponent("analytics"), agentClient: client,
            cameraMemoryStore: CameraMemoryStore(url: root.appendingPathComponent("frames")),
            operationsWatchURL: root.appendingPathComponent("watches.json"),
            missionStoreURL: root.appendingPathComponent("missions.json"),
            cameraCredentialStore: CredentialsFake(),
            operationsPreferencesURL: root.appendingPathComponent("operations.json"),
            alertClipStore: CriticalAlertClipStore(url: root.appendingPathComponent("clips")),
            languageSettings: LanguageSettings(storage: InMemoryLanguageStorage()),
            monitorHistoryURL: historyURL,
            analyticsModelDiscovery: AnalyticsModelDiscovery(modelURL: { _ in nil },
                integrity: { _ in (hash: "synthetic", sizeBytes: 0) }))
        model.shutdown()
        XCTAssertTrue(model.config.cameras.isEmpty)
        XCTAssertFalse(model.running)
        XCTAssertTrue(LocalModelService.allCases.allSatisfy { !ModelSelectionRegistry.isEnabled($0) })
        return (root, model)
    }

    func testFreshReceiptAndGUIUseSamePath() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.runLocalOperationsMonitorCheck()
        let guiReceipt = try XCTUnwrap(model.currentLocalMonitorCheckReceipt())
        XCTAssertEqual(guiReceipt.snapshot, model.localMonitorSnapshot)
        let registry = ACTAActionRegistry()
        let action = ACTARunHealthCheckAction(model: model)
        XCTAssertEqual(action.classification, .serviceAffecting)
        await registerAllWallActions(registry: registry, model: model)
        let tools = try await ACTAAnalyticsCoordinator.registryTools(registry: registry)
        XCTAssertTrue(tools.contains { $0.name == "acta__settings__run_health_check" })
        let result = try await registry.execute(actionID: action.id, parameters: [:])
        XCTAssertTrue(result.success, result.summary)
        XCTAssertTrue(result.verified)
        let receipt = try XCTUnwrap(model.currentLocalMonitorCheckReceipt())
        XCTAssertNotEqual(receipt.id, guiReceipt.id)
        XCTAssertEqual(receipt.snapshot, model.localMonitorSnapshot)
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        XCTAssertEqual(output["check_id"] as? String, receipt.id.uuidString)
        XCTAssertEqual(output["independent_watcher"] as? Bool, false)
        XCTAssertEqual(output["history_written"] as? Bool, false)
        XCTAssertTrue(model.notice.contains("counters and history may change"))
        XCTAssertTrue(model.notice.contains("No independent watcher"))
        model.localMonitorSnapshot = .empty
        XCTAssertNil(model.currentLocalMonitorCheckReceipt())
    }

    func testDisabledAndUnknownParametersDoNotRunCheck() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model) = try fixture(enabled: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        let action = ACTARunHealthCheckAction(model: model)
        await registry.register(action)
        let invalid = try await registry.execute(actionID: action.id, parameters: ["extra": "1"])
        XCTAssertFalse(invalid.success)
        XCTAssertNil(model.currentLocalMonitorCheckReceipt())
        let disabled = try await registry.execute(actionID: action.id, parameters: [:])
        XCTAssertFalse(disabled.success)
        XCTAssertFalse(disabled.verified)
        XCTAssertTrue(disabled.error?.contains("FEATURE_DISABLED") == true)
        XCTAssertTrue(model.notice.contains("not run"))
        XCTAssertEqual(model.localMonitorSnapshot, .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("history.json").path))
    }

    func testVerificationRejectsReplacedReceipt() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let action = ACTARunHealthCheckAction(model: model)
        let result = try await action.execute(parameters: [:], context: ACTAActionContext())
        XCTAssertTrue(result.success)
        let initialVerification = try await action.verify(parameters: [:], context: ACTAActionContext())
        XCTAssertTrue(initialVerification)
        _ = try model.runLocalOperationsMonitorCheckChecked()
        let staleVerification = try await action.verify(parameters: [:], context: ACTAActionContext())
        XCTAssertFalse(staleVerification)
    }

    func testFailedHistoryWriteReportsPartialChangeAndDoesNotReuseReceipt() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model) = try fixture(failedWrites: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try model.runLocalOperationsMonitorCheckChecked()
        let second = try model.runLocalOperationsMonitorCheckChecked()
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(second.snapshot.probes.first(where: { $0.id == "track-history" })?.status, .down)
        let registry = ACTAActionRegistry()
        let action = ACTARunHealthCheckAction(model: model)
        await registry.register(action)
        let failure = try await registry.execute(actionID: action.id, parameters: [:])
        XCTAssertFalse(failure.success)
        XCTAssertFalse(failure.verified)
        XCTAssertTrue(failure.error?.contains("HISTORY_WRITE_FAILED") == true)
        XCTAssertTrue(failure.error?.contains("partially written") == true)
        XCTAssertTrue(model.notice.contains("Local monitor history could not be saved"))
        XCTAssertTrue(model.notice.contains("no independent watcher"))
        XCTAssertEqual(model.localMonitorHistory.last?.kind, .fault)
        XCTAssertNil(model.currentLocalMonitorCheckReceipt())
        let later = try await registry.execute(actionID: action.id, parameters: [:])
        XCTAssertFalse(later.success)
        XCTAssertTrue(later.error?.contains("HISTORY_UNAVAILABLE") == true)
        XCTAssertNil(model.currentLocalMonitorCheckReceipt())
    }

    func testFreshCheckPersistsHistoryToInjectedPath() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model) = try fixture(failedTracking: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try model.runLocalOperationsMonitorCheckChecked()
        _ = try model.runLocalOperationsMonitorCheckChecked()
        let registry = ACTAActionRegistry()
        let action = ACTARunHealthCheckAction(model: model)
        await registry.register(action)
        let result = try await registry.execute(actionID: action.id, parameters: [:])
        XCTAssertTrue(result.success, result.summary)
        let receipt = try XCTUnwrap(model.currentLocalMonitorCheckReceipt())
        XCTAssertTrue(receipt.historyWritten)
        XCTAssertEqual(try LocalOperationsMonitorStore.load(from: root.appendingPathComponent("history.json")), receipt.history)
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        XCTAssertEqual(output["history_written"] as? Bool, true)
        XCTAssertEqual(output["check_id"] as? String, receipt.id.uuidString)
    }

    func testUnreadableHistoryDoesNotTriggerOrOverwriteCheck() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model) = try fixture(corruptHistory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        let action = ACTARunHealthCheckAction(model: model)
        await registry.register(action)
        let result = try await registry.execute(actionID: action.id, parameters: [:])
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("HISTORY_UNAVAILABLE") == true)
        XCTAssertEqual(model.localMonitorSnapshot, .empty)
        model.runLocalOperationsMonitorCheck()
        XCTAssertTrue(model.notice.contains("HISTORY_UNAVAILABLE"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("history.json")), Data("{broken".utf8))
    }

    func testExternalHistoryChangeIsNotOverwritten() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.json")
        let foreign = LocalMonitorEvent(occurredAt: Date(), probeID: "external", label: "External",
                                        kind: .fault, detail: "Synthetic")
        try LocalOperationsMonitorStore.save([foreign], to: url)
        let registry = ACTAActionRegistry()
        await registry.register(ACTARunHealthCheckAction(model: model))
        let result = try await registry.execute(actionID: "settings.run_health_check", parameters: [:])
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("HISTORY_UNAVAILABLE") == true)
        XCTAssertEqual(try LocalOperationsMonitorStore.load(from: url), [foreign])
        XCTAssertEqual(model.localMonitorSnapshot, .empty)
    }
}
