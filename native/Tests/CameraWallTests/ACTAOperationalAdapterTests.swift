import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTAOperationalAdapterTests: XCTestCase {
    private func fixture() throws -> (URL, WallModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let prefs = root.appendingPathComponent("features.json")
        try CameraFeaturePreferencesStore.save(CameraFeaturePreferences(enabledFeatures: [.operationalAlerts]), to: prefs)
        var config = WallConfiguration()
        config.cameras = [Camera(name: "Fixture", substream: "rtsp://127.0.0.1/fixture", enabled: false)]
        try ConfigurationStore.save(config, to: root.appendingPathComponent("cameras.json"))
        let model = WallModel(configURL: root.appendingPathComponent("cameras.json"),
            trackingStoreURL: root.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: prefs, databaseURL: root.appendingPathComponent("features.sqlite")),
            analyticsDirectoryURL: root.appendingPathComponent("analytics"),
            cameraMemoryStore: CameraMemoryStore(url: root.appendingPathComponent("frames")),
            operationsWatchURL: root.appendingPathComponent("watches.json"))
        return (root, model)
    }

    func testNarrativeActionsRequireReviewAndPreserveAISummary() async throws {
        let (root, model) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let store = try LocalTrackingStore(url: root.appendingPathComponent("tracks.sqlite"))
        let record = ACTANarrativeChapterRecord(chapterID: UUID().uuidString, cameraID: UUID(), cameraName: "Fixture",
            startedAt: Date().addingTimeInterval(-60), endedAt: Date(),
            narrative: ACTATemporalNarrativeResult(chapterTitle: "Fixture", summary: "Original AI observation"))
        try store.saveACTANarrativeChapterRecord(record)
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let oversized = try await registry.execute(actionID: "memory.set_chapter_text", parameters: ["chapter_id": record.chapterID, "text": String(repeating: "x", count: 16001)])
        XCTAssertFalse(oversized.success)
        XCTAssertFalse(oversized.requiresOperatorConfirmation, "Invalid content must not be persisted as a proposal")
        let conflicting = try await registry.execute(actionID: "memory.set_chapter_text", parameters: ["chapter_id": record.chapterID, "text": "Wrong", "clear": "true"])
        XCTAssertFalse(conflicting.requiresOperatorConfirmation)
        let pending = try await registry.execute(actionID: "memory.set_chapter_text", parameters: [
            "chapter_id": record.chapterID, "text": "  Reviewed observation  "])
        XCTAssertTrue(pending.requiresOperatorConfirmation)
        XCTAssertNil(try store.loadACTANarrativeChapterRecord(chapterID: record.chapterID)?.operatorText)
        XCTAssertFalse(try XCTUnwrap(store.loadACTANarrativeChapterRecord(chapterID: record.chapterID)?.operatorMarked))
        let reviewed = try await registry.confirmAndExecute(token: XCTUnwrap(pending.confirmationToken), confirmed: true)
        XCTAssertTrue(reviewed.success, reviewed.summary)
        let saved = try XCTUnwrap(store.loadACTANarrativeChapterRecord(chapterID: record.chapterID))
        XCTAssertEqual(saved.operatorText, "Reviewed observation")
        XCTAssertEqual(saved.aiSummary, record.aiSummary)
        XCTAssertTrue(saved.operatorMarked)
        XCTAssertEqual(model.actaNarrativeChapters.first?.operatorText, saved.operatorText)
        // The action sets a desired state; repeated operator-approved requests never invert it.
        for _ in 0..<2 {
            let pin = try await registry.execute(actionID: "memory.toggle_pin", parameters: ["chapter_id": record.chapterID, "pinned": "true"])
            XCTAssertTrue(pin.requiresOperatorConfirmation)
            let applied = try await registry.confirmAndExecute(token: XCTUnwrap(pin.confirmationToken), confirmed: true)
            XCTAssertTrue(applied.success)
            XCTAssertTrue(try XCTUnwrap(store.loadACTANarrativeChapterRecord(chapterID: record.chapterID)?.pinned))
        }
        let clear = try await registry.execute(actionID: "memory.set_chapter_text", parameters: ["chapter_id": record.chapterID, "clear": "true"])
        let cleared = try await registry.confirmAndExecute(token: XCTUnwrap(clear.confirmationToken), confirmed: true)
        XCTAssertTrue(cleared.success)
        let after = try XCTUnwrap(store.loadACTANarrativeChapterRecord(chapterID: record.chapterID))
        XCTAssertNil(after.operatorText)
        XCTAssertEqual(after.aiSummary, record.aiSummary)
        XCTAssertTrue(after.pinned)
        for arguments in [["chapter_id": record.chapterID],
                          ["chapter_id": record.chapterID, "text": "Bad", "clear": "true"],
                          ["chapter_id": "missing", "text": "Not saved"]] {
            let result = try await registry.execute(actionID: "memory.set_chapter_text", parameters: arguments,
                context: ACTAActionContext(isConfirmed: true))
            XCTAssertFalse(result.success)
        }
        XCTAssertEqual(try store.loadACTANarrativeChapterRecord(chapterID: record.chapterID), after)
    }

    func testWatchActionsShareGUIServiceAndVerifyDisk() async throws {
        let (root, model) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let cameraID = try XCTUnwrap(model.config.cameras.first?.id)
        let created = try await registry.execute(actionID: "watch.create", parameters: [
            "text": "red car", "camera_ids": cameraID.uuidString, "ttl_minutes": "5"])
        XCTAssertTrue(created.success, created.summary)
        XCTAssertTrue(created.verified)
        let saved = try OperationsWatchStore.load(from: model.operationsWatchURL)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.cameraIDs, [cameraID])
        XCTAssertEqual(model.operationsWatchRules, saved)
        let listed = try await registry.execute(actionID: "watch.list", parameters: [:])
        XCTAssertTrue(listed.outputJSON.contains(saved[0].id.uuidString))
        let cancelled = try await registry.execute(actionID: "watch.cancel", parameters: ["watch_id": saved[0].id.uuidString])
        XCTAssertTrue(cancelled.success, cancelled.summary)
        XCTAssertTrue(try OperationsWatchStore.load(from: model.operationsWatchURL).isEmpty)
        XCTAssertTrue(model.operationsWatchRules.isEmpty)
        let repeated = try await registry.execute(actionID: "watch.cancel", parameters: ["watch_id": saved[0].id.uuidString])
        XCTAssertFalse(repeated.success)
    }

    func testWatchValidationAndCorruptStorageCannotReportSuccess() async throws {
        let (root, model) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        for args in [["text": "red car", "camera_ids": UUID().uuidString],
                     ["text": "red car", "ttl_minutes": "0"],
                     ["text": "red car", "ttl_minutes": "5", "forever": "true"]] {
            let result = try await registry.execute(actionID: "watch.create", parameters: args)
            XCTAssertFalse(result.success)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.operationsWatchURL.path))
        let broken = Data("{corrupt".utf8)
        try broken.write(to: model.operationsWatchURL)
        let result = try await registry.execute(actionID: "watch.create", parameters: ["text": "red car"])
        XCTAssertFalse(result.success)
        XCTAssertEqual(try Data(contentsOf: model.operationsWatchURL), broken)
        try FileManager.default.removeItem(at: model.operationsWatchURL)
        try model.setFeatureEnabled(.operationalAlerts, enabled: false)
        let disabled = try await registry.execute(actionID: "watch.create", parameters: ["text": "red car"])
        XCTAssertFalse(disabled.success)
    }

    func testIncidentTransitionAndQueryUsePersistentDomainService() async throws {
        let (root, model) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let event = BehaviorSafetyCandidate(cameraID: UUID(), trackIDs: [UUID()], type: .fallConfirmed,
            severity: .critical, confidence: 0.9, monotonicTimestamp: 1, explanation: "Fixture", detectorSource: "test")
        let engine = model.localAnalyticsEngine
        _ = engine.incidentManager.ingest(candidate: event, cameraName: "Fixture")
        let incident = try XCTUnwrap(engine.incidentManager.allIncidents().first)
        let listed = try await registry.execute(actionID: "incident.list", parameters: ["camera_id": event.cameraID.uuidString])
        XCTAssertTrue(listed.success)
        XCTAssertTrue(listed.outputJSON.contains(incident.id.uuidString))
        let detail = try await registry.execute(actionID: "incident.get", parameters: ["incident_id": incident.id.uuidString])
        XCTAssertTrue(detail.success, detail.summary)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(detail.outputJSON.utf8)) as? [String: Any])
        let metadata = try XCTUnwrap(payload["incident"] as? [String: Any])
        XCTAssertEqual(metadata["id"] as? String, incident.id.uuidString)
        let tools = try await ACTAAnalyticsCoordinator.registryTools(registry: registry)
        XCTAssertTrue(tools.contains { $0.name == "acta__incident__get" })
        let result = try await registry.execute(actionID: "incident.transition_status", parameters: [
            "incident_id": incident.id.uuidString, "status": "resolved", "note": "Verified fixture"])
        XCTAssertTrue(result.success, result.summary)
        let restored = UnifiedIncidentManager(storageURL: engine.incidentManager.storageURL, auditLog: engine.auditLog)
        XCTAssertEqual(restored.incident(id: incident.id)?.status, .resolved)
        XCTAssertEqual(restored.incident(id: incident.id)?.operatorNotes, "Verified fixture")
        let dismiss = try await registry.execute(actionID: "incident.transition_status", parameters: [
            "incident_id": incident.id.uuidString, "status": "false_positive"])
        XCTAssertTrue(dismiss.requiresOperatorConfirmation)
        XCTAssertEqual(engine.incidentManager.incident(id: incident.id)?.status, .resolved)
        let unknown = try await registry.execute(actionID: "incident.transition_status", parameters: [
            "incident_id": UUID().uuidString, "status": "resolved"])
        XCTAssertFalse(unknown.success)
    }

    func testAlertAndISAPIReadsUseVerifiedGUIState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let prefs = root.appendingPathComponent("features.json")
        try CameraFeaturePreferencesStore.save(CameraFeaturePreferences(enabledFeatures: [.operationalAlerts]), to: prefs)
        let cameraID = UUID()
        let alert = VLMAlert(cameraID: cameraID, cameraName: "Fixture", condition: "Fixture", evidence: "private")
        let event = ISAPIEventRecord(cameraID: cameraID, cameraName: "Fixture",
            payload: ISAPIEventPayload(eventType: "VMD", eventState: "active", channelID: nil,
                                       eventDescription: "private", occurredAt: nil))
        let alertsURL = root.appendingPathComponent("vlm-alerts.json")
        let eventsURL = root.appendingPathComponent("isapi-events.json")
        try VLMStore.save([alert], to: alertsURL)
        try ISAPIEventStore.save([event], to: eventsURL)
        let model = WallModel(configURL: root.appendingPathComponent("cameras.json"),
            trackingStoreURL: root.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: prefs, databaseURL: root.appendingPathComponent("features.sqlite")),
            analyticsDirectoryURL: root.appendingPathComponent("analytics"),
            cameraMemoryStore: CameraMemoryStore(url: root.appendingPathComponent("frames")),
            operationsWatchURL: root.appendingPathComponent("watches.json"))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let tools = try await ACTAAnalyticsCoordinator.registryTools(registry: registry)
        XCTAssertTrue(tools.contains { $0.name == "acta__alert__vlm_list" })
        XCTAssertTrue(tools.contains { $0.name == "acta__monitor__get_isapi_events" })
        let alerts = try await registry.execute(actionID: "alert.vlm_list", parameters: [:])
        let events = try await registry.execute(actionID: "monitor.get_isapi_events", parameters: [:])
        XCTAssertTrue(alerts.success, alerts.summary)
        XCTAssertTrue(alerts.outputJSON.contains(alert.id.uuidString))
        XCTAssertTrue(events.success, events.summary)
        XCTAssertTrue(events.outputJSON.contains(event.id.uuidString))
        XCTAssertFalse(alerts.outputJSON.contains("private"))
        XCTAssertFalse(events.outputJSON.contains("private"))

        let expired = try await registry.execute(actionID: "monitor.get_isapi_events", parameters: [:],
            context: ACTAActionContext(now: Date().addingTimeInterval(31 * 86_400)))
        XCTAssertTrue(expired.success, expired.summary)
        let expiredOutput = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(expired.outputJSON.utf8)) as? [String: Any])
        XCTAssertEqual((expiredOutput["events"] as? [Any])?.count, 0)
        try model.setFeatureEnabled(.operationalAlerts, enabled: false)
        let disabled = try await registry.execute(actionID: "alert.vlm_list", parameters: [:])
        XCTAssertFalse(disabled.success)
        try model.setFeatureEnabled(.operationalAlerts, enabled: true)
        let reenabled = try await registry.execute(actionID: "alert.vlm_list", parameters: [:])
        XCTAssertTrue(reenabled.success, reenabled.summary)

        model.vlmAlerts = []
        model.isapiEvents = []
        let staleAlerts = try await registry.execute(actionID: "alert.vlm_list", parameters: [:])
        let staleEvents = try await registry.execute(actionID: "monitor.get_isapi_events", parameters: [:])
        XCTAssertFalse(staleAlerts.success)
        XCTAssertFalse(staleEvents.success)
        model.vlmAlerts = [alert]
        model.isapiEvents = [event]
        try Data("{broken".utf8).write(to: alertsURL)
        try Data("{broken".utf8).write(to: eventsURL)
        let brokenAlerts = try await registry.execute(actionID: "alert.vlm_list", parameters: [:])
        let brokenEvents = try await registry.execute(actionID: "monitor.get_isapi_events", parameters: [:])
        XCTAssertFalse(brokenAlerts.success)
        XCTAssertFalse(brokenEvents.success)
    }

    func testReadSourcesStayUnavailableAfterFailedStartupEvenIfFilesReappear() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let prefs = root.appendingPathComponent("features.json")
        try CameraFeaturePreferencesStore.save(CameraFeaturePreferences(enabledFeatures: [.operationalAlerts]), to: prefs)
        let alertsURL = root.appendingPathComponent("vlm-alerts.json")
        let eventsURL = root.appendingPathComponent("isapi-events.json")
        try Data("{broken".utf8).write(to: alertsURL)
        try Data("{broken".utf8).write(to: eventsURL)
        let model = WallModel(configURL: root.appendingPathComponent("cameras.json"),
            trackingStoreURL: root.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: prefs, databaseURL: root.appendingPathComponent("features.sqlite")),
            analyticsDirectoryURL: root.appendingPathComponent("analytics"),
            cameraMemoryStore: CameraMemoryStore(url: root.appendingPathComponent("frames")),
            operationsWatchURL: root.appendingPathComponent("watches.json"))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        try Data("[]".utf8).write(to: alertsURL)
        try Data("[]".utf8).write(to: eventsURL)
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let alerts = try await registry.execute(actionID: "alert.vlm_list", parameters: [:])
        let events = try await registry.execute(actionID: "monitor.get_isapi_events", parameters: [:])
        XCTAssertFalse(alerts.success)
        XCTAssertFalse(events.success)
    }

    func testExpiredAlertReviewDoesNotLeaveStaleAcknowledgementInGUI() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let prefsURL = root.appendingPathComponent("features.json")
        let preferences = CameraFeaturePreferences(enabledFeatures: [.operationalAlerts], retentionDays: 1)
        try CameraFeaturePreferencesStore.save(preferences, to: prefsURL)
        let alert = VLMAlert(cameraID: UUID(), cameraName: "Fixture", condition: "Fixture", evidence: "Fixture")
        try VLMStore.save([alert], to: root.appendingPathComponent("vlm-alerts.json"))
        let databaseURL = root.appendingPathComponent("features.sqlite")
        let store = try CameraFeatureStore(url: databaseURL)
        _ = try store.reviewOperationsAlert(alertID: alert.id, status: .acknowledged, preferences: preferences,
                                            at: Date().addingTimeInterval(-2 * 86_400))
        let model = WallModel(configURL: root.appendingPathComponent("cameras.json"),
            trackingStoreURL: root.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: prefsURL, databaseURL: databaseURL),
            analyticsDirectoryURL: root.appendingPathComponent("analytics"),
            cameraMemoryStore: CameraMemoryStore(url: root.appendingPathComponent("frames")),
            operationsWatchURL: root.appendingPathComponent("watches.json"))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(model.operationsAlertReviews[alert.id])
        XCTAssertNil(model.operationsAlertAcknowledgements[alert.id])
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let result = try await registry.execute(actionID: "alert.vlm_list", parameters: ["unacknowledged_only": "true"])
        XCTAssertTrue(result.success, result.summary)
        XCTAssertTrue(result.outputJSON.contains(alert.id.uuidString))
    }

    func testAlertsBecomeReadableWhenEnabledAfterStartup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let prefsURL = root.appendingPathComponent("features.json")
        try CameraFeaturePreferencesStore.save(CameraFeaturePreferences(), to: prefsURL)
        try VLMStore.save([], to: root.appendingPathComponent("vlm-alerts.json"))
        let model = WallModel(configURL: root.appendingPathComponent("cameras.json"),
            trackingStoreURL: root.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: prefsURL, databaseURL: root.appendingPathComponent("features.sqlite")),
            analyticsDirectoryURL: root.appendingPathComponent("analytics"),
            cameraMemoryStore: CameraMemoryStore(url: root.appendingPathComponent("frames")),
            operationsWatchURL: root.appendingPathComponent("watches.json"))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let disabled = try await registry.execute(actionID: "alert.vlm_list", parameters: [:])
        XCTAssertFalse(disabled.success)
        try model.setFeatureEnabled(.operationalAlerts, enabled: true)
        let enabled = try await registry.execute(actionID: "alert.vlm_list", parameters: [:])
        XCTAssertTrue(enabled.success, enabled.summary)
    }

    func testAlertReadIgnoresUnrelatedWatchLoadFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let prefsURL = root.appendingPathComponent("features.json")
        try CameraFeaturePreferencesStore.save(CameraFeaturePreferences(enabledFeatures: [.operationalAlerts]), to: prefsURL)
        try VLMStore.save([], to: root.appendingPathComponent("vlm-alerts.json"))
        let watchURL = root.appendingPathComponent("watches.json")
        let broken = Data("{invalid".utf8)
        try broken.write(to: watchURL)
        let model = WallModel(configURL: root.appendingPathComponent("cameras.json"),
            trackingStoreURL: root.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: prefsURL, databaseURL: root.appendingPathComponent("features.sqlite")),
            analyticsDirectoryURL: root.appendingPathComponent("analytics"),
            cameraMemoryStore: CameraMemoryStore(url: root.appendingPathComponent("frames")),
            operationsWatchURL: watchURL)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let result = try await registry.execute(actionID: "alert.vlm_list", parameters: [:])
        XCTAssertTrue(result.success, result.summary)
        XCTAssertEqual(try Data(contentsOf: watchURL), broken)
    }

    func testAlertReadMatchesGUIAfterRetentionPolicyChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let prefsURL = root.appendingPathComponent("features.json")
        let preferences = CameraFeaturePreferences(enabledFeatures: [.operationalAlerts], retentionDays: 30)
        try CameraFeaturePreferencesStore.save(preferences, to: prefsURL)
        let alert = VLMAlert(cameraID: UUID(), cameraName: "Fixture", condition: "Fixture", evidence: "Fixture")
        try VLMStore.save([alert], to: root.appendingPathComponent("vlm-alerts.json"))
        let databaseURL = root.appendingPathComponent("features.sqlite")
        let store = try CameraFeatureStore(url: databaseURL)
        _ = try store.reviewOperationsAlert(alertID: alert.id, status: .acknowledged, preferences: preferences,
                                            at: Date().addingTimeInterval(-2 * 86_400))
        let model = WallModel(configURL: root.appendingPathComponent("cameras.json"),
            trackingStoreURL: root.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: prefsURL, databaseURL: databaseURL),
            analyticsDirectoryURL: root.appendingPathComponent("analytics"),
            cameraMemoryStore: CameraMemoryStore(url: root.appendingPathComponent("frames")),
            operationsWatchURL: root.appendingPathComponent("watches.json"))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        var updated = model.featurePreferences
        updated.retentionDays = 1
        try model.saveFeaturePolicy(updated)
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let result = try await registry.execute(actionID: "alert.vlm_list", parameters: [:])
        XCTAssertTrue(result.success, result.summary)
        XCTAssertTrue(result.outputJSON.contains("\"status\":\"acknowledged\""))
    }

    func testEvidenceDeletionRequiresApprovalAndPreservesIncidentRecord() async throws {
        let (root, model) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let engine = model.localAnalyticsEngine
        let event = BehaviorSafetyCandidate(cameraID: UUID(), trackIDs: [UUID()], type: .fallConfirmed,
            severity: .critical, confidence: 0.9, monotonicTimestamp: 1, explanation: "Fixture", detectorSource: "test")
        let incident = try XCTUnwrap(engine.incidentManager.ingestWithEvidence(candidate: event, cameraName: "Fixture",
            evidenceStore: engine.evidenceStore, triggerSnapshotJPEG: Data([1, 2, 3]), enableEvidence: true, postEventBufferSeconds: 0))
        let bundleID = try XCTUnwrap(incident.clipID)
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let pending = try await registry.execute(actionID: "incident.delete_evidence", parameters: ["incident_id": incident.id.uuidString])
        XCTAssertTrue(pending.requiresOperatorConfirmation)
        XCTAssertTrue(engine.evidenceStore.hasEvidenceBundle(for: bundleID))
        let rejected = try await registry.confirmAndExecute(token: XCTUnwrap(pending.confirmationToken), confirmed: false)
        XCTAssertFalse(rejected.success)
        XCTAssertTrue(engine.evidenceStore.hasEvidenceBundle(for: bundleID))
        let next = try await registry.execute(actionID: "incident.delete_evidence", parameters: ["incident_id": incident.id.uuidString])
        let deleted = try await registry.confirmAndExecute(token: XCTUnwrap(next.confirmationToken), confirmed: true)
        XCTAssertTrue(deleted.success, deleted.summary)
        XCTAssertFalse(engine.evidenceStore.hasEvidenceBundle(for: bundleID))
        let restored = UnifiedIncidentManager(storageURL: engine.incidentManager.storageURL, auditLog: engine.auditLog)
        XCTAssertNotNil(restored.incident(id: incident.id))
        XCTAssertNil(restored.incident(id: incident.id)?.clipID)
        XCTAssertNil(restored.incident(id: incident.id)?.snapshotRelativePath)
    }

    func testMemoryDeletionRequiresApprovalAndRemovesActualImage() async throws {
        let (root, model) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let frame = try model.cameraMemoryStore.save(Data("fixture frame".utf8), cameraID: UUID(),
            cameraName: "Fixture", capturedAt: Date(), summary: "Fixture")
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let pending = try await registry.execute(actionID: "memory.delete_frame", parameters: ["frame_id": frame.id.uuidString])
        XCTAssertTrue(pending.requiresOperatorConfirmation)
        XCTAssertTrue(try model.cameraMemoryStore.hasStoredImage(for: frame))
        let token = try XCTUnwrap(pending.confirmationToken)
        let deleted = try await registry.confirmAndExecute(token: token, confirmed: true)
        XCTAssertTrue(deleted.success, deleted.summary)
        XCTAssertTrue(deleted.verified)
        XCTAssertFalse(try model.cameraMemoryStore.hasStoredImage(for: frame))
        XCTAssertTrue(try model.cameraMemoryStore.load().isEmpty)
        XCTAssertTrue(model.cameraMemoryFrames.isEmpty)
    }
}
