import CameraCore
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import CameraWall

final class ACTAWave1FFullClosureTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("acta-wave1f-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    @MainActor
    private func makeIsolatedModel(
        dir: URL,
        enabledFeatures: Set<CameraFeatureID> = [.operationalAlerts, .crossCameraIdentity, .plateRecognition],
        allowVoiceInput: Bool = true
    ) throws -> (WallModel, UUID) {
        let cam = Camera(name: "Front", substream: "rtsp://127.0.0.1:8554/front", enabled: false)
        var config = WallConfiguration()
        config.columns = 2
        config.cameras = [cam]
        try ConfigurationStore.save(config, to: dir.appendingPathComponent("cameras.json"))
        try ModelSelectionPreferences(enabled: []).save(to: dir.appendingPathComponent("model-preferences.json"))
        var prefs = CameraFeaturePreferences(enabledFeatures: enabledFeatures)
        prefs.allowVoiceInput = allowVoiceInput
        try CameraFeaturePreferencesStore.save(prefs, to: dir.appendingPathComponent("features.json"))
        var ai = VLMPreferences()
        ai.actaBackendMode = .dryRun
        try VLMStore.save(ai, to: dir.appendingPathComponent("vlm.json"))
        let model = WallModel(
            configURL: dir.appendingPathComponent("cameras.json"),
            workerMode: false,
            poseModelURL: dir.appendingPathComponent("fake-pose.mlmodel"),
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

    private func makeBrokerHost(
        actions: [any ACTAActionProtocol],
        threadID: String
    ) async throws -> (broker: ACTALocalActionBroker, operatorKey: ACTABrokerOperator, session: ACTABrokerSession) {
        let ids = Set(actions.map(\.id))
        let made = await ACTALocalActionBroker.make(actions: actions, allowedActionIDs: ids, audit: { _ in })
        let host = try XCTUnwrap(made)
        let opened = await host.broker.openSession(
            operatorKey: host.operatorKey, input: .chat, threadID: threadID, actionIDs: ids
        )
        let session = try XCTUnwrap(opened)
        return (host.broker, host.operatorKey, session)
    }

    private func requestAndApprove(
        broker: ACTALocalActionBroker,
        operatorKey: ACTABrokerOperator,
        session: ACTABrokerSession,
        actionID: String,
        argumentsJSON: String
    ) async throws -> ACTAActionResult {
        let req = await broker.request(session: session, actionID: actionID, argumentsJSON: argumentsJSON)
        XCTAssertTrue(req.requiresOperatorConfirmation, "\(actionID) expected confirmation: \(req.error ?? "")")
        let reviews = await broker.reviews(operatorKey: operatorKey, session: session)
        let rev = try XCTUnwrap(reviews.first, "\(actionID) missing review entry")
        return await broker.resolve(operatorKey: operatorKey, session: session, reviewed: rev, approved: true)
    }

    private func makeMinimalJPEGData() throws -> Data {
        let width = 16
        let height = 16
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = ctx.makeImage() else {
            throw ConfigurationError.invalid("Could not build synthetic CGImage.")
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else {
            throw ConfigurationError.invalid("Could not create JPEG destination.")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ConfigurationError.invalid("Could not finalize synthetic JPEG.")
        }
        return out as Data
    }

    func testNavigationAndDictationLanguageActionsThroughBroker() async throws {
        let previous = await MainActor.run { IsolatedWallFixtureSupport.modelPreferences() }
        defer { ModelSelectionRegistry.update(previous) }
        let dir = try tempDir()
        let (model, _) = try await makeIsolatedModel(dir: dir)

        let actions: [any ACTAActionProtocol] = await MainActor.run {
            [
                ACTAAppSelectSectionAction(model: model),
                ACTASettingsSelectSectionAction(model: model),
                ACTAVoiceSetDictationLanguageAction(model: model)
            ]
        }
        let (broker, key, session) = try await makeBrokerHost(actions: actions, threadID: "t-nav")

        let res1 = try await requestAndApprove(broker: broker, operatorKey: key, session: session,
                                               actionID: "app.select_section", argumentsJSON: #"{"section":"events"}"#)
        XCTAssertTrue(res1.success, res1.error ?? "")
        XCTAssertTrue(res1.verified)
        let mainSec = await MainActor.run { model.navigationBridge.selectedMainSection }
        XCTAssertEqual(mainSec, "events")

        let res2 = try await requestAndApprove(broker: broker, operatorKey: key, session: session,
                                               actionID: "settings.select_section", argumentsJSON: #"{"section":"analytics"}"#)
        XCTAssertTrue(res2.success, res2.error ?? "")
        XCTAssertTrue(res2.verified)
        let (navMain, navSettings) = await MainActor.run {
            (model.navigationBridge.selectedMainSection, model.navigationBridge.selectedSettingsSection)
        }
        XCTAssertEqual(navMain, "settings")
        XCTAssertEqual(navSettings, .analytics)

        let res3 = try await requestAndApprove(broker: broker, operatorKey: key, session: session,
                                               actionID: "voice.set_dictation_language", argumentsJSON: #"{"language":"ru-RU"}"#)
        XCTAssertTrue(res3.success, res3.error ?? "")
        XCTAssertTrue(res3.verified)
        let lang = await MainActor.run { model.navigationBridge.voiceDictationLanguage }
        XCTAssertEqual(lang, .russian)

        let bad = await broker.request(session: session, actionID: "app.select_section", argumentsJSON: #"{"section":"nonexistent"}"#)
        XCTAssertFalse(bad.success)
    }

    func testDiscoveryAndSanitizedMetadataInspectionThroughBroker() async throws {
        let previous = await MainActor.run { IsolatedWallFixtureSupport.modelPreferences() }
        defer { ModelSelectionRegistry.update(previous) }
        let dir = try tempDir()
        let (model, camID) = try await makeIsolatedModel(dir: dir)

        let alertID = UUID()
        let jpeg = try makeMinimalJPEGData()
        let incidentID = try await MainActor.run { () -> UUID in
            try model.actaFeatureCoordinator.reviewOperationsAlert(
                alertID: alertID,
                priority: .critical,
                status: .acknowledged,
                note: "SENSITIVE-OPERATOR-NOTE-DO-NOT-LEAK"
            )
            model.operationsAlertReviews = Dictionary(
                uniqueKeysWithValues: try model.actaFeatureCoordinator.operationsAlertReviews().map { ($0.alertID, $0) }
            )
            let now = Date()
            let frame1 = AlertLookbackFrame(serial: 1, capturedAt: now.addingTimeInterval(-1), jpegData: jpeg)
            let frame2 = AlertLookbackFrame(serial: 2, capturedAt: now, jpegData: jpeg)
            _ = try model.actaAlertClipStore.save(alertID: alertID, cameraID: camID, frames: [frame1, frame2], now: now)
            let engine = model.localAnalyticsEngine
            let event = BehaviorSafetyCandidate(
                cameraID: camID,
                trackIDs: [UUID()],
                type: .fallConfirmed,
                severity: .high,
                confidence: 0.91,
                monotonicTimestamp: 1,
                explanation: "Synthetic fall",
                detectorSource: "pose"
            )
            let recorded = try XCTUnwrap(engine.incidentManager.ingestWithEvidence(
                candidate: event,
                cameraName: "Front",
                evidenceStore: engine.evidenceStore,
                triggerSnapshotJPEG: jpeg,
                enableEvidence: true,
                postEventBufferSeconds: 0
            ))
            return recorded.id
        }

        let actions: [any ACTAActionProtocol] = await MainActor.run {
            [
                ACTACameraDiscoverLocalAction(provider: {
                    [ACTADiscoveredLocalCamera(deviceID: "usb-cam-1", name: "Built-in Camera", connected: true)]
                }),
                ACTACameraDiscoverScreensAction(provider: {
                    [ACTADiscoveredScreen(displayID: 1, width: 2560, height: 1600)]
                }),
                ACTAAlertListReviewHistoryAction(model: model),
                ACTAAlertListClipsAction(model: model),
                ACTAIncidentGetEvidenceMetadataAction(model: model)
            ]
        }
        let (broker, _, session) = try await makeBrokerHost(actions: actions, threadID: "t-inspect")

        let localRes = await broker.request(session: session, actionID: "camera.discover_local", argumentsJSON: "{}")
        XCTAssertTrue(localRes.success, localRes.error ?? "")
        XCTAssertTrue(localRes.outputJSON.contains("usb-cam-1"))
        XCTAssertTrue(localRes.outputJSON.contains("\"capture_started\":false"))

        let screenRes = await broker.request(session: session, actionID: "camera.discover_screens", argumentsJSON: "{}")
        XCTAssertTrue(screenRes.success, screenRes.error ?? "")
        XCTAssertTrue(screenRes.outputJSON.contains("\"display_id\":\"1\""))

        let revHistRes = await broker.request(session: session, actionID: "alert.list_review_history", argumentsJSON: #"{"limit":10}"#)
        XCTAssertTrue(revHistRes.success, revHistRes.error ?? "")
        XCTAssertTrue(revHistRes.outputJSON.contains(alertID.uuidString))
        XCTAssertTrue(revHistRes.outputJSON.contains("\"has_note\":true"))
        XCTAssertFalse(revHistRes.outputJSON.contains("SENSITIVE-OPERATOR-NOTE"))

        let clipsRes = await broker.request(session: session, actionID: "alert.list_clips", argumentsJSON: #"{"limit":10}"#)
        XCTAssertTrue(clipsRes.success, clipsRes.error ?? "")
        XCTAssertTrue(clipsRes.outputJSON.contains("\"count\":1"))
        XCTAssertFalse(clipsRes.outputJSON.contains(dir.path))

        let evRes = await broker.request(
            session: session,
            actionID: "incident.get_evidence_metadata",
            argumentsJSON: #"{"incident_id":"\#(incidentID.uuidString)"}"#
        )
        XCTAssertTrue(evRes.success, evRes.error ?? "")
        XCTAssertTrue(evRes.outputJSON.contains("\"has_evidence\":true"))
        XCTAssertTrue(evRes.outputJSON.contains("\"has_snapshot\":true"))
        XCTAssertFalse(evRes.outputJSON.contains("secret-evidence"))
    }

    func testIncidentMutationsThroughBroker() async throws {
        let previous = await MainActor.run { IsolatedWallFixtureSupport.modelPreferences() }
        defer { ModelSelectionRegistry.update(previous) }
        let dir = try tempDir()
        let (model, camID) = try await makeIsolatedModel(dir: dir)

        let incidentID = try await MainActor.run { () -> UUID in
            let engine = model.localAnalyticsEngine
            let event = BehaviorSafetyCandidate(
                cameraID: camID,
                trackIDs: [UUID()],
                type: .fallConfirmed,
                severity: .high,
                confidence: 0.93,
                monotonicTimestamp: 1,
                explanation: "Synthetic fall",
                detectorSource: "pose"
            )
            let recorded = try XCTUnwrap(engine.incidentManager.ingestWithEvidence(
                candidate: event,
                cameraName: "Front",
                evidenceStore: engine.evidenceStore,
                triggerSnapshotJPEG: Data([1, 2, 3]),
                enableEvidence: true,
                postEventBufferSeconds: 0
            ))
            return recorded.id
        }

        let actions: [any ACTAActionProtocol] = await MainActor.run {
            [
                WallOperationalAction(specification: IncidentTransitionStatusAction(), model: model),
                WallOperationalAction(specification: IncidentUpdateNoteAction(), model: model),
                WallOperationalAction(specification: IncidentDeleteEvidenceAction(), model: model)
            ]
        }
        let (broker, key, session) = try await makeBrokerHost(actions: actions, threadID: "t-inc")

        let tRes = try await requestAndApprove(
            broker: broker, operatorKey: key, session: session,
            actionID: "incident.transition_status",
            argumentsJSON: #"{"incident_id":"\#(incidentID.uuidString)","status":"acknowledged"}"#
        )
        XCTAssertTrue(tRes.success, tRes.error ?? "")
        XCTAssertTrue(tRes.verified)

        let nRes = try await requestAndApprove(
            broker: broker, operatorKey: key, session: session,
            actionID: "incident.update_note",
            argumentsJSON: #"{"incident_id":"\#(incidentID.uuidString)","note":"Checked by operator"}"#
        )
        XCTAssertTrue(nRes.success, nRes.error ?? "")
        XCTAssertTrue(nRes.verified)

        let dRes = try await requestAndApprove(
            broker: broker, operatorKey: key, session: session,
            actionID: "incident.delete_evidence",
            argumentsJSON: #"{"incident_id":"\#(incidentID.uuidString)"}"#
        )
        XCTAssertTrue(dRes.success, dRes.error ?? "")
        XCTAssertTrue(dRes.verified)

        let updated = await MainActor.run { model.localAnalyticsEngine.incidentManager.incident(id: incidentID) }
        XCTAssertEqual(updated?.status, SafetyIncidentStatus.acknowledged)
        XCTAssertEqual(updated?.operatorNotes, "Checked by operator")
    }

    func testIdentityAndPlateAndTrackGroupActionsThroughBroker() async throws {
        let previous = await MainActor.run { IsolatedWallFixtureSupport.modelPreferences() }
        defer { ModelSelectionRegistry.update(previous) }
        let dir = try tempDir()
        let (model, camID) = try await makeIsolatedModel(dir: dir)
        let jpeg = try makeMinimalJPEGData()

        let (personA, personB, carTrack, proposalID) = try await MainActor.run { () -> (UUID, UUID, UUID, UUID) in
            let store = try XCTUnwrap(model.actaTrackingStore)
            let aID = UUID()
            let bID = UUID()
            let cID = UUID()
            let cam2 = UUID()
            _ = try store.record(
                DetectedObject(id: 1, label: "person", confidence: 0.92, box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.4), trackID: aID),
                cameraID: camID, cameraName: "Front", cropJPEG: jpeg
            )
            _ = try store.record(
                DetectedObject(id: 2, label: "person", confidence: 0.91, box: CGRect(x: 0.2, y: 0.1, width: 0.2, height: 0.4), trackID: bID),
                cameraID: cam2, cameraName: "Lobby", cropJPEG: jpeg
            )
            _ = try store.record(
                DetectedObject(id: 3, label: "car", confidence: 0.95, box: CGRect(x: 0.3, y: 0.2, width: 0.3, height: 0.3), trackID: cID),
                cameraID: camID, cameraName: "Front", cropJPEG: jpeg
            )
            model.recentTracks = try store.recentTracks()
            let recA = try XCTUnwrap(store.track(trackID: aID))
            let recB = try XCTUnwrap(store.track(trackID: bID))
            let reviewSvc = try model.actaCrossCameraIdentityReviewService()
            let prop = try reviewSvc.propose(candidate: ReIDValidationCandidate(trackA: recA, trackB: recB, distance: 0.12))
            let evidence = VehicleTextEvidence(
                trackID: cID,
                candidates: [VehicleTextCandidate(text: "ABC-123", confidence: 0.9)],
                cropSHA256: String(repeating: "a", count: 64)
            )
            try store.saveVehicleTextEvidence(evidence)
            model.savedVehicleTextEvidence[cID] = evidence
            return (aID, bID, cID, prop.id)
        }

        let describedFlag = LockedFlag()
        let actions: [any ACTAActionProtocol] = await MainActor.run {
            [
                ACTAIdentityDescribeTrackAction(model: model, describeHook: { _ in
                    describedFlag.setTrue()
                    return true
                }),
                ACTAIdentityFindSimilarTracksAction(model: model, searchHook: { _ in 2 }),
                ACTAIdentityReviewProposalAction(model: model),
                ACTAIdentityUndoMergeAction(model: model),
                ACTAIdentityTrackGroupAction(mode: .group, model: model),
                ACTAIdentityTrackGroupAction(mode: .detach, model: model),
                ACTAIdentityReadVehiclePlateAction(model: model, ocrReader: { _ in
                    [VehicleTextCandidate(text: "TEST-777", confidence: 0.96)]
                }),
                ACTAIdentityClearVehiclePlateAction(model: model),
                ACTAIdentityDeleteTrackedObjectAction(model: model)
            ]
        }
        let (broker, key, session) = try await makeBrokerHost(actions: actions, threadID: "t-id")

        let dRes = try await requestAndApprove(broker: broker, operatorKey: key, session: session,
                                               actionID: "identity.describe_track", argumentsJSON: #"{"track_id":"\#(personA.uuidString)"}"#)
        XCTAssertTrue(dRes.success, dRes.error ?? "")
        XCTAssertTrue(describedFlag.value)

        let simRes = await broker.request(session: session, actionID: "identity.find_similar_tracks", argumentsJSON: #"{"track_id":"\#(personA.uuidString)"}"#)
        XCTAssertTrue(simRes.success, simRes.error ?? "")
        XCTAssertTrue(simRes.outputJSON.contains("\"match_count\":2"))

        let rpRes = try await requestAndApprove(
            broker: broker, operatorKey: key, session: session,
            actionID: "identity.review_proposal",
            argumentsJSON: #"{"proposal_id":"\#(proposalID.uuidString)","accept":true}"#
        )
        XCTAssertTrue(rpRes.success, rpRes.error ?? "")

        let uRes = try await requestAndApprove(
            broker: broker, operatorKey: key, session: session,
            actionID: "identity.undo_merge",
            argumentsJSON: #"{"proposal_id":"\#(proposalID.uuidString)"}"#
        )
        XCTAssertTrue(uRes.success, uRes.error ?? "")

        let gRes = try await requestAndApprove(
            broker: broker, operatorKey: key, session: session,
            actionID: "identity.group_tracks",
            argumentsJSON: #"{"track_ids":"\#(personA.uuidString),\#(personB.uuidString)"}"#
        )
        XCTAssertTrue(gRes.success, gRes.error ?? "")

        let dtRes = try await requestAndApprove(
            broker: broker, operatorKey: key, session: session,
            actionID: "identity.detach_tracks",
            argumentsJSON: #"{"track_ids":"\#(personA.uuidString)"}"#
        )
        XCTAssertTrue(dtRes.success, dtRes.error ?? "")

        let rvpRes = try await requestAndApprove(
            broker: broker, operatorKey: key, session: session,
            actionID: "identity.read_vehicle_plate",
            argumentsJSON: #"{"track_id":"\#(carTrack.uuidString)"}"#
        )
        XCTAssertTrue(rvpRes.success, rvpRes.error ?? "")

        try await MainActor.run {
            let store = try XCTUnwrap(model.actaTrackingStore)
            let evidence = VehicleTextEvidence(
                trackID: carTrack,
                candidates: [VehicleTextCandidate(text: "XYZ-999", confidence: 0.95)],
                cropSHA256: String(repeating: "b", count: 64)
            )
            try store.saveVehicleTextEvidence(evidence)
            model.savedVehicleTextEvidence[carTrack] = evidence
        }

        let cvpRes = try await requestAndApprove(
            broker: broker, operatorKey: key, session: session,
            actionID: "identity.clear_vehicle_plate",
            argumentsJSON: #"{"track_id":"\#(carTrack.uuidString)"}"#
        )
        XCTAssertTrue(cvpRes.success, cvpRes.error ?? "")
        XCTAssertTrue(cvpRes.verified)

        let delRes = try await requestAndApprove(
            broker: broker, operatorKey: key, session: session,
            actionID: "identity.delete_tracked_object",
            argumentsJSON: #"{"track_id":"\#(carTrack.uuidString)"}"#
        )
        XCTAssertTrue(delRes.success, delRes.error ?? "")
        XCTAssertTrue(delRes.verified)
        let stillThere = try await MainActor.run { try XCTUnwrap(model.actaTrackingStore).contains(trackID: carTrack) }
        XCTAssertFalse(stillThere)
    }

    func testVoiceListeningLifecycleThroughBroker() async throws {
        let previous = await MainActor.run { IsolatedWallFixtureSupport.modelPreferences() }
        defer { ModelSelectionRegistry.update(previous) }
        let dir = try tempDir()
        let (model, _) = try await makeIsolatedModel(dir: dir, allowVoiceInput: true)

        let filterState = await MainActor.run { () -> ACTACanvasFilterState in
            let state = ACTACanvasFilterState()
            model.canvasFilterBridge.attach(state)
            return state
        }
        defer {
            Task { @MainActor in
                filterState.stopAnalysisVoice()
                model.canvasFilterBridge.detach(filterState)
            }
        }

        let actions: [any ACTAActionProtocol] = await MainActor.run {
            [
                ACTAVoiceControlAction(mode: .startListening, model: model),
                ACTAVoiceControlAction(mode: .stopListening, model: model),
                ACTAVoiceControlAction(mode: .cancelListening, model: model)
            ]
        }
        let (broker, key, session) = try await makeBrokerHost(actions: actions, threadID: "t-voice")

        let startRes = try await requestAndApprove(
            broker: broker, operatorKey: key, session: session,
            actionID: "voice.start_listening", argumentsJSON: #"{"locale":"en-US"}"#
        )
        XCTAssertTrue(startRes.success, startRes.error ?? "")

        let stopRes = try await requestAndApprove(
            broker: broker, operatorKey: key, session: session,
            actionID: "voice.stop_listening", argumentsJSON: "{}"
        )
        XCTAssertTrue(stopRes.success, stopRes.error ?? "")

        let cancelRes = try await requestAndApprove(
            broker: broker, operatorKey: key, session: session,
            actionID: "voice.cancel_listening", argumentsJSON: "{}"
        )
        XCTAssertTrue(cancelRes.success, cancelRes.error ?? "")
    }

    func testDirectGUIAuditAndExcludedUnsafeActions() async throws {
        let previous = await MainActor.run { IsolatedWallFixtureSupport.modelPreferences() }
        defer { ModelSelectionRegistry.update(previous) }
        let dir = try tempDir()
        let (model, _) = try await makeIsolatedModel(dir: dir)

        try await MainActor.run {
            var updated = model.config
            updated.columns = 3
            try model.saveSystemSettings(updated)
            model.clearISAPIEvents()
            model.recordDirectGUIAction(
                actionID: "settings.set_api_key",
                parameters: ["account": "primary", "api_key": "sk-secret-value", "endpoint_url": "https://secret.example/token"],
                ok: true
            )
        }
        let rows = try await MainActor.run {
            try XCTUnwrap(model.actaTrackingStore).executeReadOnlyACTASQL(
                "SELECT thread_id, tool_name, args_json FROM ghost_chat_tool_calls WHERE thread_id = 'ui_direct'"
            )
        }
        XCTAssertTrue(rows.contains { $0["tool_name"] == "settings.update_system" && ($0["args_json"] ?? "").contains("\"initiator\":\"ui_direct\"") })
        XCTAssertTrue(rows.contains { $0["tool_name"] == "monitor.clear_isapi_events" })
        XCTAssertTrue(rows.contains { $0["tool_name"] == "settings.set_api_key" && ($0["args_json"] ?? "").contains("[redacted]") })
        XCTAssertFalse(rows.contains { ($0["args_json"] ?? "").contains("sk-secret-value") })
        XCTAssertFalse(rows.contains { ($0["args_json"] ?? "").contains("https://secret.example") })

        let excludedIDs = [
            "window.toggle_fullscreen",
            "showcase.copy_link",
            "ai.toggle_spoken_briefing",
            "worker.edit_config",
            "agent.request_confirmation",
            "agent.resolve_confirmation"
        ]
        let mappedValues = Set(ACTAAnalyticsCoordinator.allBrokerActionIDs.values)
        let actions = await MainActor.run { model.buildProductionBrokerActions() }
        let (broker, _, session) = try await makeBrokerHost(actions: actions, threadID: "t-excl")
        for excluded in excludedIDs {
            XCTAssertFalse(mappedValues.contains(excluded), "\(excluded) must remain excluded from model-facing broker")
            let result = await broker.request(session: session, actionID: excluded, argumentsJSON: "{}")
            XCTAssertFalse(result.success)
            XCTAssertTrue(result.error?.hasPrefix("AUTHORIZATION_DENIED:") == true, "Expected AUTHORIZATION_DENIED for \(excluded)")
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func setTrue() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}
