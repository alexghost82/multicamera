import CameraCore
import Foundation
import XCTest
@testable import CameraWall

final class ACTAPhase1FullParityTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acta-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    @MainActor
    private func makeIsolatedModel(dir: URL) throws -> WallModel {
        let cam = Camera(name: "Main", substream: "rtsp://127.0.0.1:8554/main", enabled: false)
        var config = WallConfiguration()
        config.cameras = [cam]
        try ConfigurationStore.save(config, to: dir.appendingPathComponent("cameras.json"))
        try ModelSelectionPreferences(enabled: []).save(to: dir.appendingPathComponent("model-preferences.json"))
        try CameraFeaturePreferencesStore.save(
            CameraFeaturePreferences(enabledFeatures: [.chronologicalMemory, .crossCameraIdentity, .scheduledMissions, .operationalAlerts]),
            to: dir.appendingPathComponent("features.json")
        )
        var ai = VLMPreferences()
        ai.actaBackendMode = .dryRun
        try VLMStore.save(ai, to: dir.appendingPathComponent("vlm.json"))
        let poseURL = dir.appendingPathComponent("fake-pose.mlmodel")
        let model = WallModel(
            configURL: dir.appendingPathComponent("cameras.json"),
            workerMode: false,
            poseModelURL: poseURL,
            trackingStoreURL: dir.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(
                preferencesURL: dir.appendingPathComponent("features.json"),
                databaseURL: dir.appendingPathComponent("features.sqlite")
            ),
            analyticsDirectoryURL: dir.appendingPathComponent("analytics"),
            agentClient: IsolatedWallFixtureSupport.client(),
            cameraMemoryStore: CameraMemoryStore(url: dir.appendingPathComponent("frames")),
            operationsWatchURL: dir.appendingPathComponent("watches.json"),
            missionStoreURL: dir.appendingPathComponent("missions.json"),
            cameraCredentialStore: ACTAIsolatedCredentials(),
            operationsPreferencesURL: dir.appendingPathComponent("operations.json"),
            alertClipStore: CriticalAlertClipStore(url: dir.appendingPathComponent("clips")),
            languageSettings: LanguageSettings(storage: InMemoryLanguageStorage()),
            monitorHistoryURL: dir.appendingPathComponent("monitor.json"),
            analyticsModelDiscovery: AnalyticsModelDiscovery(
                modelURL: { _ in nil },
                integrity: { _ in (hash: "synthetic", sizeBytes: 0) }
            )
        )
        addTeardownBlock { Task { @MainActor in model.shutdown() } }
        return model
    }

    func testProductionBrokerBijectionAndCompletePhase1Catalogue() async throws {
        let previous = await MainActor.run { IsolatedWallFixtureSupport.modelPreferences() }
        defer { ModelSelectionRegistry.update(previous) }
        let dir = try tempDir()
        let model = try await makeIsolatedModel(dir: dir)

        let actions = await MainActor.run { model.buildProductionBrokerActions() }
        let actionIDs = actions.map(\.id)
        let uniqueIDs = Set(actionIDs)

        // 1. No duplicate action IDs in production broker
        XCTAssertEqual(actionIDs.count, uniqueIDs.count, "Duplicate action IDs detected in buildProductionBrokerActions()")

        // 2. Every action has unique, valid parameter names
        for action in actions {
            let names = action.parameters.map(\.name)
            XCTAssertEqual(names.count, Set(names).count, "Duplicate parameter schema in \(action.id)")
            for param in action.parameters {
                XCTAssertTrue(["string", "number", "integer", "boolean"].contains(param.type),
                              "Unsupported schema type '\(param.type)' in \(action.id).\(param.name)")
            }
        }

        // 3. Every production action maps cleanly to ACTAAnalyticsCoordinator.allBrokerActionIDs
        let mappedValues = Set(ACTAAnalyticsCoordinator.allBrokerActionIDs.values)
        for id in uniqueIDs {
            let expectedTransport = "acta__" + id.replacingOccurrences(of: ".", with: "__")
            XCTAssertEqual(ACTAAnalyticsCoordinator.allBrokerActionIDs[expectedTransport], id,
                           "Missing transport mapping for production action '\(id)'")
        }
        // Conditional actions (narrative pin, identity follow-up, mission exports) may be absent only if their store is inactive
        let allowedConditional: Set<String> = ["memory.toggle_pin", "identity.set_follow_up", "monitor.export_report_html", "mission.export_pdf"]
        let unconstructed = mappedValues.subtracting(uniqueIDs).subtracting(allowedConditional)
        XCTAssertTrue(unconstructed.isEmpty, "Transport mappings with no production action: \(unconstructed.sorted())")

        // 4. Broker successfully constructs and exposes full catalogue
        let madeHost = await ACTALocalActionBroker.make(
            actions: actions,
            allowedActionIDs: uniqueIDs,
            allowedInspectionIDs: ACTAAnalyticsCoordinator.localInspectionIDs,
            audit: { _ in }
        )
        let host = try XCTUnwrap(madeHost, "ACTALocalActionBroker.make failed for production action set")
        let opened = await host.broker.openSession(
            operatorKey: host.operatorKey,
            input: .chat,
            threadID: "parity-check",
            actionIDs: uniqueIDs,
            inspectionIDs: ACTAAnalyticsCoordinator.localInspectionIDs
        )
        let session = try XCTUnwrap(opened)
        let catalogue = await host.broker.catalogue(session: session)
        XCTAssertEqual(catalogue.count, uniqueIDs.count)
        XCTAssertGreaterThanOrEqual(catalogue.count, 108)

        // 5. Unknown / unsupported action returns explicit denial without executing
        let unknown = await host.broker.request(
            session: session,
            actionID: "nonexistent.unsupported_action",
            argumentsJSON: "{}"
        )
        XCTAssertFalse(unknown.success)
        XCTAssertTrue(unknown.error?.hasPrefix("AUTHORIZATION_DENIED:") == true)

        // 6. Legacy registry also returns explicit UNSUPPORTED for unknown actions
        let legacyRegistry = ACTAActionRegistry()
        let unsupported = try await legacyRegistry.execute(actionID: "nonexistent.action", parameters: [:])
        XCTAssertFalse(unsupported.success)
        XCTAssertTrue(unsupported.error?.hasPrefix("UNSUPPORTED:") == true)
    }
}
