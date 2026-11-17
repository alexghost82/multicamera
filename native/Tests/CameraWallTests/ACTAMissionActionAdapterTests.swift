import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTAMissionActionAdapterTests: XCTestCase {
    private func fixture(responder: (@Sendable (String) async throws -> String)? = nil) throws -> (URL, WallModel, UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var config = WallConfiguration()
        let camera = Camera(name: "Fixture", substream: "rtsp://127.0.0.1/fixture", enabled: true)
        config.cameras = [camera]
        try ConfigurationStore.save(config, to: root.appendingPathComponent("cameras.json"))
        let prefs = root.appendingPathComponent("features.json")
        try CameraFeaturePreferencesStore.save(CameraFeaturePreferences(enabledFeatures: [.scheduledMissions]), to: prefs)
        let model = WallModel(configURL: root.appendingPathComponent("cameras.json"),
            trackingStoreURL: root.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: prefs, databaseURL: root.appendingPathComponent("features.sqlite")),
            analyticsDirectoryURL: root.appendingPathComponent("analytics"),
            cameraMemoryStore: CameraMemoryStore(url: root.appendingPathComponent("frames")),
            operationsWatchURL: root.appendingPathComponent("watches.json"), missionStoreURL: root.appendingPathComponent("missions.json"), missionConsultResponder: responder)
        return (root, model, camera.id)
    }

    func testConsultationReceiptAndSavedReplyUseLocalDomainWorkflow() async throws {
        let script = MissionConsultScript()
        let (root, model, camera) = try fixture(responder: { prompt in await script.answer(prompt) })
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let mission = try CameraMission(cameraID: camera, name: "Fixture", brief: "Describe activity", intervalSeconds: 600)
        try model.saveCameraMission(mission)
        let result = try await registry.execute(actionID: "mission.ask_consult", parameters: ["mission_id": mission.id.uuidString, "question": "What happened?"])
        XCTAssertTrue(result.success, result.summary)
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        XCTAssertEqual(output["accepted"] as? Bool, true)
        XCTAssertEqual(output["completion_verified"] as? Bool, false)
        let questionID = try XCTUnwrap(output["question_id"] as? String)
        let deadline = Date().addingTimeInterval(3)
        while model.missionConsultBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.missionConsultBusy)
        let saved = try CameraMissionStore.loadDocument(from: model.missionStoreURL)
        XCTAssertEqual(saved.consults.count, 2)
        XCTAssertTrue(saved.consults.contains { $0.id.uuidString == questionID && $0.role == .operatorMessage })
        XCTAssertEqual(saved.consults.last?.text, "No saved observations are available.")
        let prompt = await script.prompt
        XCTAssertTrue(prompt.contains("read-only local assistant"))
        XCTAssertTrue(prompt.contains("What happened?"))
        let history = try await registry.execute(actionID: "mission.history", parameters: ["mission_id": mission.id.uuidString])
        XCTAssertTrue(history.outputJSON.contains("No saved observations are available."))
        let before = try Data(contentsOf: model.missionStoreURL)
        let oversized = try await registry.execute(actionID: "mission.ask_consult", parameters: ["mission_id": mission.id.uuidString, "question": String(repeating: "x", count: 2001)])
        XCTAssertFalse(oversized.success)
        XCTAssertEqual(try Data(contentsOf: model.missionStoreURL), before)
    }

    func testMissionExecutionIdentityIgnoresHistoryButRejectsChangedRequest() throws {
        let original = try CameraMission(cameraID: UUID(), name: "Fixture", brief: "Describe activity", intervalSeconds: 600, enabled: true)
        var history = original
        history.nextRunAt = Date().addingTimeInterval(600)
        history.lastRunAt = Date()
        history.lastResult = "Saved observation"
        XCTAssertTrue(original.hasSameExecutionRequest(as: history))
        var edited = original
        edited.brief = "Count vehicles"
        XCTAssertFalse(original.hasSameExecutionRequest(as: edited))
        edited = original
        edited.cameraID = UUID()
        XCTAssertFalse(original.hasSameExecutionRequest(as: edited))
        edited = original
        edited.intervalSeconds = 1200
        XCTAssertFalse(original.hasSameExecutionRequest(as: edited))
        edited = original
        edited.enabled = false
        XCTAssertFalse(original.hasSameExecutionRequest(as: edited))
    }

    func testMissionLifecyclePreservesHistoryAndUsesInjectedGUIStore() async throws {
        let (root, model, camera) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let created = try await registry.execute(actionID: "mission.create", parameters: [
            "camera_id": camera.uuidString, "name": "Entrance", "brief": "Describe visible activity", "interval_seconds": "600"])
        XCTAssertTrue(created.success, created.summary)
        let first = try XCTUnwrap(CameraMissionStore.load(from: model.missionStoreURL).first)
        XCTAssertFalse(first.enabled)
        XCTAssertEqual(first.intervalSeconds, 600)
        // Seed real run/consult records through the domain store, then refresh the feature as GUI does.
        let run = CameraMissionRun(missionID: first.id, cameraID: camera, missionName: first.name, status: .completed, summary: "Saved observation")
        let consult = try CameraMissionConsultMessage(missionID: first.id, role: .operatorMessage, text: "Saved question")
        try CameraMissionStore.save([first], runs: [run], consults: [consult], to: model.missionStoreURL)
        try model.setFeatureEnabled(.scheduledMissions, enabled: true)
        let edit = try await registry.execute(actionID: "mission.edit", parameters: ["mission_id": first.id.uuidString, "name": "Renamed"])
        XCTAssertTrue(edit.success, edit.summary)
        let updated = try model.missionDocumentChecked()
        XCTAssertEqual(updated.missions.first?.name, "Renamed")
        XCTAssertEqual(updated.missions.first?.nextRunAt, first.nextRunAt)
        XCTAssertEqual(updated.runs.count, 1)
        XCTAssertEqual(updated.consults.count, 1)
        let listed = try await registry.execute(actionID: "mission.list", parameters: [:])
        XCTAssertTrue(listed.outputJSON.contains("Renamed"))
        let history = try await registry.execute(actionID: "mission.history", parameters: ["mission_id": first.id.uuidString])
        XCTAssertTrue(history.outputJSON.contains("Saved observation"))
        XCTAssertTrue(history.outputJSON.contains("Saved question"))
        var ledger = AgentEvidenceLedger()
        ledger.record(outputJSON: history.outputJSON, tool: "acta__mission__history")
        XCTAssertTrue(ledger.references.contains { $0.recordID == run.id.uuidString && $0.kind == "mission_run" && $0.cameraID == camera.uuidString })
        XCTAssertTrue(ledger.references.contains { $0.recordID == consult.id.uuidString && $0.kind == "mission_consult_question" })
        let clear = try await registry.execute(actionID: "mission.clear_consult", parameters: ["mission_id": first.id.uuidString])
        XCTAssertTrue(clear.requiresOperatorConfirmation)
        XCTAssertEqual(try CameraMissionStore.loadDocument(from: model.missionStoreURL).consults.count, 1)
        let cleared = try await registry.confirmAndExecute(token: XCTUnwrap(clear.confirmationToken), confirmed: true)
        XCTAssertTrue(cleared.success, cleared.summary)
        let pending = try await registry.execute(actionID: "mission.delete", parameters: ["mission_id": first.id.uuidString])
        XCTAssertTrue(pending.requiresOperatorConfirmation)
        let deleted = try await registry.confirmAndExecute(token: XCTUnwrap(pending.confirmationToken), confirmed: true)
        XCTAssertTrue(deleted.success, deleted.summary)
        let saved = try model.missionDocumentChecked()
        XCTAssertTrue(saved.missions.isEmpty)
        XCTAssertTrue(saved.consults.isEmpty)
        XCTAssertEqual(saved.runs.count, 1)
        let archived = try await registry.execute(actionID: "mission.history", parameters: ["mission_id": first.id.uuidString])
        XCTAssertTrue(archived.success)
        XCTAssertTrue(archived.outputJSON.contains("Saved observation"))
    }

    func testClockScheduleValidationAndScheduleRecalculation() async throws {
        let (root, model, camera) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let base = ["camera_id": camera.uuidString, "name": "Morning", "brief": "Describe visible activity", "schedule_kind": "clock"]
        let noZone = try await registry.execute(actionID: "mission.create", parameters: base.merging(["clock_times": "09:00"]) { _, new in new })
        XCTAssertFalse(noZone.success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.missionStoreURL.path))
        let args = base.merging(["clock_times": "09:00,18:00", "weekdays": "1,2,3,4,5", "time_zone": "Asia/Jerusalem"]) { _, new in new }
        let created = try await registry.execute(actionID: "mission.create", parameters: args)
        XCTAssertTrue(created.success, created.summary)
        let mission = try XCTUnwrap(model.cameraMissions.first)
        XCTAssertEqual(mission.clockTimes, ["09:00", "18:00"])
        XCTAssertEqual(mission.weekdays, [1,2,3,4,5])
        let now = Date().addingTimeInterval(3600)
        let edited = try await registry.execute(actionID: "mission.edit", parameters: [
            "mission_id": mission.id.uuidString, "clock_times": "10:00"], context: ACTAActionContext(now: now))
        XCTAssertTrue(edited.success, edited.summary)
        let saved = try XCTUnwrap(CameraMissionStore.load(from: model.missionStoreURL).first)
        let expected = try CameraMissionScheduler.nextRunAt(for: saved, after: now)
        XCTAssertEqual(saved.nextRunAt.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1)
        let bytes = try Data(contentsOf: model.missionStoreURL)
        for patch in [["weekdays": "1,1"], ["clock_times": "25:00"], ["time_zone": "Unknown/Zone"],
                      ["interval_seconds": "1"], ["weekdays": "a"], ["clock_times": "09:00,"], ["camera_id": UUID().uuidString]] {
            let result = try await registry.execute(actionID: "mission.edit", parameters: ["mission_id": mission.id.uuidString].merging(patch) { _, new in new })
            XCTAssertFalse(result.success)
            XCTAssertEqual(try Data(contentsOf: model.missionStoreURL), bytes)
        }
    }

    func testCorruptOrExternallyChangedMissionStorageIsNotOverwritten() async throws {
        let (root, model, camera) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let args = ["camera_id": camera.uuidString, "name": "Fixture", "brief": "Describe activity"]
        let broken = Data("{broken".utf8)
        try broken.write(to: model.missionStoreURL)
        let corrupted = try await registry.execute(actionID: "mission.create", parameters: args)
        XCTAssertFalse(corrupted.success)
        XCTAssertEqual(try Data(contentsOf: model.missionStoreURL), broken)
        try FileManager.default.removeItem(at: model.missionStoreURL)
        let external = try CameraMission(cameraID: camera, name: "External", brief: "Saved elsewhere", intervalSeconds: 600)
        try CameraMissionStore.save([external], to: model.missionStoreURL)
        let bytes = try Data(contentsOf: model.missionStoreURL)
        let stale = try await registry.execute(actionID: "mission.create", parameters: args)
        XCTAssertFalse(stale.success)
        XCTAssertEqual(try Data(contentsOf: model.missionStoreURL), bytes)
        try model.setFeatureEnabled(.scheduledMissions, enabled: true)
        let refreshed = try await registry.execute(actionID: "mission.create", parameters: args)
        XCTAssertTrue(refreshed.success, refreshed.summary)
        try model.setFeatureEnabled(.scheduledMissions, enabled: false)
        let disabled = try await registry.execute(actionID: "mission.create", parameters: args)
        XCTAssertFalse(disabled.success)
    }

    func testManualRunIsAnIdempotentQueueReceiptNotACompletedAnalysis() async throws {
        let (root, model, camera) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let created = try await registry.execute(actionID: "mission.create", parameters: [
            "camera_id": camera.uuidString, "name": "Fixture", "brief": "Describe activity", "enabled": "true"])
        XCTAssertTrue(created.success)
        let mission = try XCTUnwrap(model.cameraMissions.first)
        XCTAssertFalse(model.running)
        for _ in 0..<2 {
            let run = try await registry.execute(actionID: "mission.run_now", parameters: ["mission_id": mission.id.uuidString])
            XCTAssertTrue(run.success, run.summary)
            let output = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(run.outputJSON.utf8)) as? [String: Any])
            XCTAssertEqual(output["status"] as? String, "queued")
            XCTAssertEqual(output["completed"] as? Bool, false)
            XCTAssertTrue(model.cameraMissionRuns.isEmpty)
        }
        let second = try CameraMission(cameraID: camera, name: "Other", brief: "Describe activity", intervalSeconds: 600, enabled: true)
        try model.saveCameraMission(second)
        let busy = try await registry.execute(actionID: "mission.run_now", parameters: ["mission_id": second.id.uuidString])
        XCTAssertFalse(busy.success)
        model.stop()
        XCTAssertEqual(model.missionExecutionStatus(mission.id), "idle")
        let disabled = try await registry.execute(actionID: "mission.edit", parameters: ["mission_id": mission.id.uuidString, "enabled": "false"])
        XCTAssertTrue(disabled.success)
        let failed = try await registry.execute(actionID: "mission.run_now", parameters: ["mission_id": mission.id.uuidString])
        XCTAssertFalse(failed.success)
    }
}

private actor MissionConsultScript {
    private(set) var prompt = ""
    func answer(_ value: String) -> String {
        prompt = value
        return "{\"answer\":\"No saved observations are available.\",\"matched_alerts\":[]}"
    }
}
