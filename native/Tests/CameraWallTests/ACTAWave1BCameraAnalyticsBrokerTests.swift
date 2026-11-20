import CameraCore
import Foundation
import XCTest
@testable import CameraWall

final class ACTAWave1BCameraAnalyticsBrokerTests: XCTestCase {
    private final class FakeCameraCredentialStore: CameraCredentialStore, @unchecked Sendable {
        private let lock = NSLock()
        private var store: [UUID: Credentials] = [:]

        func read(_ cameraID: UUID) throws -> Credentials? {
            lock.lock(); defer { lock.unlock() }
            return store[cameraID]
        }

        func save(_ credentials: Credentials, for cameraID: UUID) throws {
            lock.lock(); defer { lock.unlock() }
            store[cameraID] = credentials
        }

        func remove(_ cameraID: UUID) throws {
            lock.lock(); defer { lock.unlock() }
            store.removeValue(forKey: cameraID)
        }
    }

    @MainActor
    private final class InMemoryFavoritesStorage: ACTACameraFavoritesStorage {
        var value = ""
        func read() throws -> String { value }
        func write(_ value: String) throws { self.value = value }
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acta-wave1b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    @MainActor
    private func makeIsolatedModel(dir: URL) throws -> (WallModel, UUID, FakeCameraCredentialStore) {
        let cam = Camera(name: "Lobby", substream: "rtsp://127.0.0.1:8554/lobby", enabled: false)
        var config = WallConfiguration()
        config.columns = 2
        config.cameras = [cam]
        try ConfigurationStore.save(config, to: dir.appendingPathComponent("cameras.json"))
        try ModelSelectionPreferences(enabled: []).save(to: dir.appendingPathComponent("model-preferences.json"))
        try CameraFeaturePreferencesStore.save(
            CameraFeaturePreferences(enabledFeatures: []),
            to: dir.appendingPathComponent("features.json")
        )
        var ai = VLMPreferences()
        ai.actaBackendMode = .dryRun
        try VLMStore.save(ai, to: dir.appendingPathComponent("vlm.json"))
        let creds = FakeCameraCredentialStore()
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
            cameraCredentialStore: creds,
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
        return (model, cam.id, creds)
    }

    func testStructuredNetworkAddEditFavoriteAndImportThroughBroker() async throws {
        let previous = await MainActor.run { IsolatedWallFixtureSupport.modelPreferences() }
        defer { ModelSelectionRegistry.update(previous) }
        let dir = try tempDir()
        let (model, lobbyID, creds) = try await makeIsolatedModel(dir: dir)
        let favStorage = await MainActor.run { InMemoryFavoritesStorage() }
        let actions: [any ACTAActionProtocol] = await MainActor.run {
            [
                ACTABrokerCameraNetworkAddAction(model: model),
                ACTABrokerCameraEditAction(model: model),
                ACTAPreparedCameraFavoriteAction(domain: ACTALocalFavoriteReviewDomain(model: model, storage: favStorage)),
                ACTACameraImportSourcesAction(model: model),
                ACTACameraSetAllRunningAction(model: model, lifecycleHook: { _ in })
            ]
        }
        let ids = Set(actions.map(\.id))
        let madeHost = await ACTALocalActionBroker.make(actions: actions, allowedActionIDs: ids, audit: { _ in })
        let host = try XCTUnwrap(madeHost)
        let opened = await host.broker.openSession(
            operatorKey: host.operatorKey, input: .chat, threadID: "t-cam", actionIDs: ids
        )
        let session = try XCTUnwrap(opened)

        // 1. Add anonymous network camera using structured parameters (passes broker displayable check)
        let addReq = await host.broker.request(
            session: session,
            actionID: "camera.add_network",
            argumentsJSON: #"{"name":"Gate","scheme":"rtsp","host":"192.0.2.10","port":554,"path":"/stream1"}"#
        )
        XCTAssertTrue(addReq.requiresOperatorConfirmation, addReq.error ?? "")
        let addRev = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let addRes = await host.broker.resolve(operatorKey: host.operatorKey, session: session, reviewed: addRev[0], approved: true)
        XCTAssertTrue(addRes.success, addRes.error ?? "")
        XCTAssertTrue(addRes.verified)
        let gateCam = await MainActor.run { model.config.cameras.first { $0.name == "Gate" } }
        XCTAssertEqual(gateCam?.substream, "rtsp://192.0.2.10:554/stream1")
        XCTAssertEqual(gateCam?.enabled, false)

        // 2. Edit camera metadata & location through broker
        let editReq = await host.broker.request(
            session: session,
            actionID: "camera.edit",
            argumentsJSON: #"{"camera_id":"\#(lobbyID.uuidString)","location":"Building A"}"#
        )
        XCTAssertTrue(editReq.requiresOperatorConfirmation, editReq.error ?? "")
        let editRev = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let editRes = await host.broker.resolve(operatorKey: host.operatorKey, session: session, reviewed: editRev[0], approved: true)
        XCTAssertTrue(editRes.success, editRes.error ?? "")
        let updatedLoc = await MainActor.run { model.config.cameras.first { $0.id == lobbyID }?.location }
        XCTAssertEqual(updatedLoc, "Building A")

        // 3. Local revisioned favorite toggle through broker
        let favReq = await host.broker.request(
            session: session,
            actionID: "camera.set_favorite",
            argumentsJSON: #"{"camera_id":"\#(lobbyID.uuidString)","favorite":true}"#
        )
        XCTAssertTrue(favReq.requiresOperatorConfirmation, favReq.error ?? "")
        let favRev = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let favRes = await host.broker.resolve(operatorKey: host.operatorKey, session: session, reviewed: favRev[0], approved: true)
        XCTAssertTrue(favRes.success, favRes.error ?? "")
        XCTAssertTrue(favRes.verified)
        let favStored = await MainActor.run { favStorage.value }
        XCTAssertEqual(ACTACameraFavorites.decode(favStored), [lobbyID])

        // 4. Import sources file with credentialed RTSP URL -> credentials saved to store, NEVER leaked in review/output
        let importFile = dir.appendingPathComponent("sources.txt")
        let secretPass = "VerySecretImportPass123"
        try "rtsp://admin:\(secretPass)@192.0.2.50:554/ch1\n".write(to: importFile, atomically: true, encoding: .utf8)
        let importReq = await host.broker.request(
            session: session,
            actionID: "camera.import_sources",
            argumentsJSON: #"{"file_path":"\#(importFile.path)","start_enabled":false}"#
        )
        XCTAssertTrue(importReq.requiresOperatorConfirmation, importReq.error ?? "")
        let importRev = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        XCTAssertFalse(importRev[0].title.contains(secretPass))
        let importRes = await host.broker.resolve(operatorKey: host.operatorKey, session: session, reviewed: importRev[0], approved: true)
        XCTAssertTrue(importRes.success, importRes.error ?? "")
        XCTAssertFalse(importRes.outputJSON.contains(secretPass))
        let importedCam = await MainActor.run { model.config.cameras.first { $0.substream == "rtsp://192.0.2.50:554/ch1" } }
        let importedID = try XCTUnwrap(importedCam?.id)
        let storedCred = try creds.read(importedID)
        XCTAssertEqual(storedCred?.username, "admin")
        XCTAssertEqual(storedCred?.password, secretPass)

        // 5. Wall start/stop through broker
        let runReq = await host.broker.request(
            session: session,
            actionID: "camera.set_all_running",
            argumentsJSON: #"{"running":false}"#
        )
        XCTAssertTrue(runReq.requiresOperatorConfirmation, runReq.error ?? "")
        let runRev = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let runRes = await host.broker.resolve(operatorKey: host.operatorKey, session: session, reviewed: runRev[0], approved: true)
        XCTAssertTrue(runRes.success, runRes.error ?? "")
    }

    func testPerCameraAnalyticsOverrideAndRestrictedZoneThroughBroker() async throws {
        let previous = await MainActor.run { IsolatedWallFixtureSupport.modelPreferences() }
        defer { ModelSelectionRegistry.update(previous) }
        let dir = try tempDir()
        let (model, lobbyID, _) = try await makeIsolatedModel(dir: dir)
        let actions: [any ACTAActionProtocol] = await MainActor.run {
            let domain = ACTAEngineAnalyticsMutationDomain(engine: model.localAnalyticsEngine)
            let inv = ACTAWallAnalyticsCameraInventory(model: model)
            return [
                WallAnalyticsAction(kind: .get, model: model),
                ACTAPreparedAnalyticsSettingsAction(kind: .cameraOverride, domain: domain, cameraInventory: inv),
                ACTAPreparedAnalyticsSettingsAction(kind: .removeCameraOverride, domain: domain, cameraInventory: inv),
                WallAnalyticsAction(kind: .zone, model: model),
                WallAnalyticsAction(kind: .removeZone, model: model)
            ]
        }
        let ids = Set(actions.map(\.id))
        let madeHost = await ACTALocalActionBroker.make(actions: actions, allowedActionIDs: ids, audit: { _ in })
        let host = try XCTUnwrap(madeHost)
        let opened = await host.broker.openSession(
            operatorKey: host.operatorKey, input: .chat, threadID: "t-analytics", actionIDs: ids
        )
        let session = try XCTUnwrap(opened)

        // 1. Set per-camera override
        let ovReq = await host.broker.request(
            session: session,
            actionID: "analytics.set_camera_override",
            argumentsJSON: #"{"camera_id":"\#(lobbyID.uuidString)","field":"fallDetectionEnabled","value":"false"}"#
        )
        XCTAssertTrue(ovReq.requiresOperatorConfirmation, ovReq.error ?? "")
        let ovRev = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let ovRes = await host.broker.resolve(operatorKey: host.operatorKey, session: session, reviewed: ovRev[0], approved: true)
        XCTAssertTrue(ovRes.success, ovRes.error ?? "")

        // 2. Add restricted zone
        let zoneReq = await host.broker.request(
            session: session,
            actionID: "analytics.set_restricted_zone",
            argumentsJSON: #"{"camera_id":"\#(lobbyID.uuidString)","name":"RestrictedBay","x":0.1,"y":0.1,"width":0.4,"height":0.4}"#
        )
        XCTAssertTrue(zoneReq.requiresOperatorConfirmation, zoneReq.error ?? "")
        let zoneRev = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let zoneRes = await host.broker.resolve(operatorKey: host.operatorKey, session: session, reviewed: zoneRev[0], approved: true)
        XCTAssertTrue(zoneRes.success, zoneRes.error ?? "")

        // 3. Remove complete override (including zone)
        let rmReq = await host.broker.request(
            session: session,
            actionID: "analytics.remove_camera_override",
            argumentsJSON: #"{"camera_id":"\#(lobbyID.uuidString)"}"#
        )
        XCTAssertTrue(rmReq.requiresOperatorConfirmation, rmReq.error ?? "")
        let rmRev = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let rmRes = await host.broker.resolve(operatorKey: host.operatorKey, session: session, reviewed: rmRev[0], approved: true)
        XCTAssertTrue(rmRes.success, rmRes.error ?? "")
        let hasOverride = await MainActor.run { model.localAnalyticsEngine.settings.cameraOverrides[lobbyID] != nil }
        XCTAssertFalse(hasOverride)
    }
}
