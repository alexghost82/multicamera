import CameraCore
import Foundation
import XCTest
@testable import CameraWall

final class ACTAWave1COperationsBrokerTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acta-wave1c-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    @MainActor
    private func makeIsolatedModel(dir: URL) throws -> (WallModel, UUID) {
        let cam = Camera(name: "Yard", substream: "rtsp://127.0.0.1:8554/yard", enabled: true)
        var config = WallConfiguration()
        config.cameras = [cam]
        try ConfigurationStore.save(config, to: dir.appendingPathComponent("cameras.json"))
        try ModelSelectionPreferences(enabled: []).save(to: dir.appendingPathComponent("model-preferences.json"))
        try CameraFeaturePreferencesStore.save(
            CameraFeaturePreferences(enabledFeatures: [.operationalAlerts, .scheduledMissions]),
            to: dir.appendingPathComponent("features.json")
        )
        var ai = VLMPreferences()
        ai.actaBackendMode = .dryRun
        try VLMStore.save(ai, to: dir.appendingPathComponent("vlm.json"))
        try VLMStore.save([
            VLMAlert(cameraID: cam.id, cameraName: "Yard", condition: "Person in yard", evidence: "Detected", priority: .critical)
        ], to: dir.appendingPathComponent("vlm-alerts.json"))
        try ISAPIEventStore.save([
            ISAPIEventRecord(
                cameraID: cam.id,
                cameraName: "Yard",
                payload: ISAPIEventPayload(eventType: "VMD", eventState: "active", channelID: "1", eventDescription: "Motion", occurredAt: Date())
            )
        ], to: dir.appendingPathComponent("isapi-events.json"))
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
        return (model, cam.id)
    }

    func testAlertClearISAPIClearWatchAndMissionLifecycleThroughBroker() async throws {
        let previous = await MainActor.run { IsolatedWallFixtureSupport.modelPreferences() }
        defer { ModelSelectionRegistry.update(previous) }
        let dir = try tempDir()
        let (model, camID) = try await makeIsolatedModel(dir: dir)
        let actions: [any ACTAActionProtocol] = await MainActor.run {
            [
                ACTAReviewedClearVLMAlertsAction(model: model),
                ACTAReviewedClearISAPIEventsAction(model: model),
                WallOperationalAction(specification: WatchCreateAction(), model: model),
                WallOperationalAction(specification: WatchCancelAction(), model: model),
                WallMissionAction(kind: .create, model: model),
                WallMissionAction(kind: .edit, model: model),
                ACTAReviewedMissionRunAction(model: model, allowCoordinatedLocalExecution: true),
                WallMissionAction(kind: .delete, model: model)
            ]
        }
        let ids = Set(actions.map(\.id))
        let madeHost = await ACTALocalActionBroker.make(actions: actions, allowedActionIDs: ids, audit: { _ in })
        let host = try XCTUnwrap(madeHost)
        let opened = await host.broker.openSession(
            operatorKey: host.operatorKey, input: .chat, threadID: "t-ops", actionIDs: ids
        )
        let session = try XCTUnwrap(opened)

        func approve(_ actionID: String, args: String) async throws -> ACTAActionResult {
            let pending = await host.broker.request(session: session, actionID: actionID, argumentsJSON: args)
            XCTAssertTrue(pending.requiresOperatorConfirmation, "\(actionID): \(pending.error ?? pending.summary)")
            let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
            let review = try XCTUnwrap(reviews.last { $0.actionID == actionID })
            return await host.broker.resolve(operatorKey: host.operatorKey, session: session, reviewed: review, approved: true)
        }

        // 1. Clear VLM alerts
        let alertRes = try await approve("alert.clear_all", args: "{}")
        XCTAssertTrue(alertRes.success, alertRes.error ?? "")
        XCTAssertTrue(alertRes.verified)
        let remainingAlerts = await MainActor.run { model.vlmAlerts.count }
        XCTAssertEqual(remainingAlerts, 0)

        // 2. Clear ISAPI events
        let isapiRes = try await approve("monitor.clear_isapi_events", args: "{}")
        XCTAssertTrue(isapiRes.success, isapiRes.error ?? "")
        XCTAssertTrue(isapiRes.verified)
        let remainingISAPI = await MainActor.run { model.isapiEvents.count }
        XCTAssertEqual(remainingISAPI, 0)

        // 3. Create & cancel watch rule
        let watchRes = try await approve("watch.create", args: #"{"text":"Watch gate","ttl_minutes":30}"#)
        XCTAssertTrue(watchRes.success, watchRes.error ?? "")
        let watchJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(watchRes.outputJSON.utf8)) as? [String: Any])
        let watchID = try XCTUnwrap(watchJSON["watch_id"] as? String)
        let cancelRes = try await approve("watch.cancel", args: #"{"watch_id":"\#(watchID)"}"#)
        XCTAssertTrue(cancelRes.success, cancelRes.error ?? "")

        // 4. Create mission -> enable via edit -> queue run_now -> delete mission
        let createRes = try await approve(
            "mission.create",
            args: #"{"camera_id":"\#(camID.uuidString)","name":"Perimeter","brief":"Check fence","interval_seconds":900}"#
        )
        XCTAssertTrue(createRes.success, createRes.error ?? "")
        let createObj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(createRes.outputJSON.utf8)) as? [String: Any])
        let missionObj = try XCTUnwrap(createObj["mission"] as? [String: Any])
        let missionID = try XCTUnwrap(missionObj["id"] as? String)

        let editRes = try await approve(
            "mission.edit",
            args: #"{"mission_id":"\#(missionID)","enabled":true}"#
        )
        XCTAssertTrue(editRes.success, editRes.error ?? "")

        let runRes = try await approve(
            "mission.run_now",
            args: #"{"mission_id":"\#(missionID)"}"#
        )
        XCTAssertTrue(runRes.success, runRes.error ?? "")
        XCTAssertTrue(runRes.verified)

        let delRes = try await approve(
            "mission.delete",
            args: #"{"mission_id":"\#(missionID)"}"#
        )
        XCTAssertTrue(delRes.success, delRes.error ?? "")
    }
}
