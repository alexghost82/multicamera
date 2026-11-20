import CameraCore
import Combine
import CoreVideo
import Foundation
import XCTest
@testable import CameraWall

private actor MissionListScript {
    private(set) var prompts: [String] = []
    func reply(_ prompt: String) -> String {
        prompts.append(prompt)
        if prompts.count == 1 {
            return #"{"tool_calls":[{"name":"acta__mission__list","arguments":{}}]}"#
        }
        return #"{"answerMarkdown":"Reviewed missions.","confidence":0.5}"#
    }
}

private actor SuspendedMissionConsult {
    private var continuation: CheckedContinuation<String, Never>?
    var started: Bool { continuation != nil }
    func respond() async -> String {
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        continuation?.resume(returning: #"{"answer":"synthetic answer","matched_alerts":[]}"#)
        continuation = nil
    }
}

private actor SuspendedMissionInference {
    private var continuation: CheckedContinuation<String, Never>?
    var started: Bool { continuation != nil }
    func respond() async -> String {
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        continuation?.resume(returning: #"{"answer":"One vehicle visible.","matched_alerts":[]}"#)
        continuation = nil
    }
}

private final class SyntheticMissionFrames: @unchecked Sendable {
    let session = CameraSession()
    let pixel: CVPixelBuffer

    init() throws {
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA,
                                         nil, &buffer)
        guard result == kCVReturnSuccess, let buffer else {
            throw ConfigurationError.invalid("Could not create synthetic frame.")
        }
        pixel = buffer
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
    }

    func publish() { session.publish(pixel, message: "Synthetic frame") }
}

private struct FailingMissionCredentials: CameraCredentialStore {
    func read(_ id: UUID) throws -> Credentials? { nil }
    func save(_ credentials: Credentials, for id: UUID) throws {
        throw ConfigurationError.invalid("Synthetic credential failure")
    }
    func remove(_ id: UUID) throws {}
}

@MainActor
final class ACTAScopedMissionListActionTests: XCTestCase {
    private func fixture(responder: (@Sendable (String) async throws -> String)? = nil,
                         executionHooks: WallModel.MissionExecutionHooks? = nil,
                         credentials: CameraCredentialStore = ACTAIsolatedCredentials()) throws -> (URL, WallModel, CameraMission, CameraMission) {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".mission-list-fixture-\(UUID().uuidString)", isDirectory: true)
        try IsolatedWallFixtureSupport.prepare(root)
        var config = WallConfiguration()
        let camera = Camera(name: "synthetic-secret-camera", substream: "rtsp://fixture.invalid/secret", enabled: true)
        config.cameras = [camera]
        try ConfigurationStore.save(config, to: root.appendingPathComponent("cameras.json"))
        let prefs = root.appendingPathComponent("features.json")
        try CameraFeaturePreferencesStore.save(CameraFeaturePreferences(enabledFeatures: [.scheduledMissions]), to: prefs)
        let enabled = try CameraMission(cameraID: camera.id, name: "synthetic-secret-name",
                                        brief: "synthetic-secret-brief", intervalSeconds: 600, enabled: true)
        let disabled = try CameraMission(cameraID: camera.id, name: "synthetic-secret-disabled",
                                         brief: "synthetic-secret-brief", intervalSeconds: 600)
        let missionURL = root.appendingPathComponent("missions.json")
        let run = CameraMissionRun(missionID: enabled.id, cameraID: camera.id, missionName: enabled.name,
                                   status: .completed, summary: "synthetic-secret-history")
        try CameraMissionStore.save([enabled, disabled], runs: [run], to: missionURL)
        let model = WallModel(configURL: root.appendingPathComponent("cameras.json"),
            poseModelURL: root.appendingPathComponent("fake-pose.mlmodel"),
            trackingStoreURL: root.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: prefs, databaseURL: root.appendingPathComponent("features.sqlite")),
            analyticsDirectoryURL: root.appendingPathComponent("analytics"),
            agentClient: IsolatedWallFixtureSupport.client(),
            cameraMemoryStore: CameraMemoryStore(url: root.appendingPathComponent("frames")),
            operationsWatchURL: root.appendingPathComponent("watches.json"), missionStoreURL: missionURL,
            missionConsultResponder: responder,
            missionExecutionHooks: executionHooks,
            cameraCredentialStore: credentials,
            operationsPreferencesURL: root.appendingPathComponent("operations.json"),
            alertClipStore: CriticalAlertClipStore(url: root.appendingPathComponent("clips")),
            languageSettings: LanguageSettings(storage: InMemoryLanguageStorage()),
            monitorHistoryURL: root.appendingPathComponent("monitor.json"),
            analyticsModelDiscovery: IsolatedWallFixtureSupport.modelDiscovery)
        XCTAssertFalse(model.running)
        XCTAssertNil(model.tiles[camera.id]?.session)
        return (root, model, enabled, disabled)
    }

    private func additionalModel(root: URL, missionURL: URL) throws -> WallModel {
        try IsolatedWallFixtureSupport.prepare(root)
        let prefs = root.appendingPathComponent("features.json")
        try CameraFeaturePreferencesStore.save(
            CameraFeaturePreferences(enabledFeatures: [.scheduledMissions]), to: prefs)
        return WallModel(configURL: root.appendingPathComponent("cameras.json"),
            poseModelURL: root.appendingPathComponent("fake-pose.mlmodel"),
            trackingStoreURL: root.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: prefs, databaseURL: root.appendingPathComponent("features.sqlite")),
            analyticsDirectoryURL: root.appendingPathComponent("analytics"),
            agentClient: IsolatedWallFixtureSupport.client(),
            cameraMemoryStore: CameraMemoryStore(url: root.appendingPathComponent("frames")),
            operationsWatchURL: root.appendingPathComponent("watches.json"), missionStoreURL: missionURL,
            cameraCredentialStore: ACTAIsolatedCredentials(),
            operationsPreferencesURL: root.appendingPathComponent("operations.json"),
            alertClipStore: CriticalAlertClipStore(url: root.appendingPathComponent("clips")),
            languageSettings: LanguageSettings(storage: InMemoryLanguageStorage()),
            monitorHistoryURL: root.appendingPathComponent("monitor.json"),
            analyticsModelDiscovery: IsolatedWallFixtureSupport.modelDiscovery)
    }

    func testMissionSaveRejectsStalePolicyAndCameraInventory() throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, mission, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        var edited = mission
        edited.name = "Synthetic edit"
        let created = try CameraMission(cameraID: mission.cameraID, name: "Synthetic create",
                                        brief: "Inspect", intervalSeconds: 600)
        let original = try Data(contentsOf: model.missionStoreURL)
        let featureURL = root.appendingPathComponent("features.json")
        try CameraFeaturePreferencesStore.save(CameraFeaturePreferences(), to: featureURL)
        for draft in [edited, created] {
            XCTAssertThrowsError(try model.saveCameraMission(draft))
            XCTAssertEqual(try Data(contentsOf: model.missionStoreURL), original)
        }
        try CameraFeaturePreferencesStore.save(model.featurePreferences, to: featureURL)
        var changed = model.config
        changed.cameras = []
        try ConfigurationStore.save(changed, to: root.appendingPathComponent("cameras.json"))
        for draft in [edited, created] {
            XCTAssertThrowsError(try model.saveCameraMission(draft))
            XCTAssertEqual(try Data(contentsOf: model.missionStoreURL), original)
        }
        try ConfigurationStore.save(model.config, to: root.appendingPathComponent("cameras.json"))
        var unknown = created
        unknown.cameraID = UUID()
        XCTAssertThrowsError(try model.saveCameraMission(unknown))
        XCTAssertEqual(try Data(contentsOf: model.missionStoreURL), original)
        try model.saveCameraMission(edited)
        XCTAssertEqual(try model.missionDocumentChecked().missions.first(where: { $0.id == mission.id })?.name, edited.name)
    }

    func testMissionSaveHoldsBothLocksDuringCreateAndEdit() throws {
        guard let helper = ProcessInfo.processInfo.environment["MISSION_COORDINATION_TEST_HELPER"] else {
            throw XCTSkip("Set MISSION_COORDINATION_TEST_HELPER to run the interprocess test.")
        }
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, mission, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let cameraURL = root.appendingPathComponent("cameras.json")
        let featureURL = root.appendingPathComponent("features.json")
        let cameraBytes = try Data(contentsOf: cameraURL)
        let featureBytes = try Data(contentsOf: featureURL)
        func attempt(_ mode: String, _ url: URL) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = [mode, url.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        var probe = false
        var outcomes: [[Int32]] = []
        var failure: Error?
        let subscription = model.$cameraMissions.sink { _ in
            guard probe else { return }
            do { outcomes.append(try [attempt("camera", cameraURL), attempt("feature", featureURL)]) }
            catch { failure = error }
        }
        var edited = mission
        edited.name = "Synthetic edit"
        probe = true
        try model.saveCameraMission(edited)
        let created = try CameraMission(cameraID: mission.cameraID, name: "Synthetic create",
                                        brief: "Inspect", intervalSeconds: 600)
        try model.saveCameraMission(created)
        probe = false
        withExtendedLifetime(subscription) {}
        XCTAssertNil(failure)
        XCTAssertEqual(outcomes, [[7, 7], [7, 7]])
        XCTAssertEqual(try Data(contentsOf: cameraURL), cameraBytes)
        XCTAssertEqual(try Data(contentsOf: featureURL), featureBytes)
        XCTAssertEqual(try attempt("camera", cameraURL), 0)
        XCTAssertEqual(try attempt("feature", featureURL), 0)
    }

    func testMissionSaveFailsWithoutWriteWhileEitherLockIsHeld() throws {
        guard let helper = ProcessInfo.processInfo.environment["MISSION_COORDINATION_TEST_HELPER"] else {
            throw XCTSkip("Set MISSION_COORDINATION_TEST_HELPER to run the interprocess test.")
        }
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        for (mode, file) in [("hold-feature", "features.json"), ("hold-camera", "cameras.json")] {
            let (root, model, mission, _) = try fixture()
            defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
            let original = try Data(contentsOf: model.missionStoreURL)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = [mode, root.appendingPathComponent(file).path]
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            defer {
                try? input.fileHandleForWriting.close()
                if process.isRunning { process.waitUntilExit() }
            }
            XCTAssertEqual(String(data: output.fileHandleForReading.availableData, encoding: .utf8), "ready\n")
            var edited = mission
            edited.name = "Blocked edit"
            XCTAssertThrowsError(try model.saveCameraMission(edited))
            XCTAssertEqual(try Data(contentsOf: model.missionStoreURL), original)
            try input.fileHandleForWriting.write(contentsOf: Data("x".utf8))
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            try model.saveCameraMission(edited)
        }
    }

    func testReentrantCameraChangeAfterMissionWriteRequiresReconciliation() throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, mission, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        var armed = false
        let subscription = model.$cameraMissions.sink { _ in
            guard armed else { return }
            armed = false
            var changed = model.config
            changed.columns = changed.columns == 4 ? 5 : 4
            model.config = changed
        }
        var edited = mission
        edited.name = "Saved before concurrent change"
        armed = true
        XCTAssertThrowsError(try model.saveCameraMission(edited))
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(try CameraMissionStore.loadDocument(from: model.missionStoreURL)
            .missions.first(where: { $0.id == mission.id })?.name, edited.name)
        XCTAssertThrowsError(try model.missionDocumentChecked())
        XCTAssertThrowsError(try model.saveCameraMission(edited))
    }

    func testReentrantFeatureChangeAfterMissionWriteRequiresReconciliation() throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, mission, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        var armed = false
        let subscription = model.$cameraMissions.sink { _ in
            guard armed else { return }
            armed = false
            var changed = model.featurePreferences
            changed.enabledFeatures.remove(.scheduledMissions)
            model.featurePreferences = changed
        }
        var edited = mission
        edited.name = "Saved before feature change"
        armed = true
        XCTAssertThrowsError(try model.saveCameraMission(edited))
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(try CameraMissionStore.loadDocument(from: model.missionStoreURL)
            .missions.first(where: { $0.id == mission.id })?.name, edited.name)
        XCTAssertThrowsError(try model.missionDocumentChecked())
        XCTAssertThrowsError(try model.saveCameraMission(edited))
    }

    func testLiveChatLoopReturnsOnlyAuditedCurrentMetadata() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, enabled, disabled) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try model.requestMissionRunChecked(enabled.id), "queued")
        let bytes = try Data(contentsOf: model.missionStoreURL)
        let action = ACTAScopedMissionListAction(model: model)
        let scopes = ACTAAnalyticsCoordinator.localInspectionIDs
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id],
                                                     allowedInspectionIDs: scopes, audit: { _ in })
        let host = try XCTUnwrap(made)
        let issued = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
            threadID: "fixture", actionIDs: [action.id], inspectionIDs: scopes)
        let session = try XCTUnwrap(issued)
        let direct = await host.broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
        XCTAssertTrue(direct.success)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(direct.outputJSON.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["missions"])
        let rows = try XCTUnwrap(object["missions"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        for row in rows { XCTAssertEqual(Set(row.keys), ["id", "enabled", "execution_state"]) }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as! String, $0) })
        XCTAssertEqual(byID[enabled.id.uuidString]?["enabled"] as? Bool, true)
        XCTAssertEqual(byID[enabled.id.uuidString]?["execution_state"] as? String, "queued")
        XCTAssertEqual(byID[disabled.id.uuidString]?["enabled"] as? Bool, false)
        XCTAssertEqual(byID[disabled.id.uuidString]?["execution_state"] as? String, "idle")
        let script = MissionListScript()
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .mlxInProcess), transport: { _ in
            XCTFail("Unexpected network request")
            throw URLError(.notConnectedToInternet)
        }, keyProvider: { _ in XCTFail("Unexpected Keychain access"); return nil },
            localAgentInference: { prompt, _ in await script.reply(prompt) })
        let store = try LocalTrackingStore(url: root.appendingPathComponent("chat.sqlite"))
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        _ = await coordinator.askACTAChatAgent(question: "List missions", threadID: "fixture",
                                              broker: host.broker, brokerSession: session)
        let prompts = await script.prompts
        XCTAssertTrue(prompts.first?.contains("acta__mission__list") == true)
        XCTAssertTrue(prompts.dropFirst().contains {
            $0.contains("action_output") && $0.contains(enabled.id.uuidString) && $0.contains("queued")
        })
        XCTAssertTrue(prompts.allSatisfy {
            !$0.contains("synthetic-secret") && !$0.contains(enabled.cameraID.uuidString)
        })
        XCTAssertEqual(try Data(contentsOf: model.missionStoreURL), bytes)
        await host.broker.closeSession(session, operatorKey: host.operatorKey)
    }

    func testInvalidArgumentsAndAuditFailureReleaseNoData() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, mission, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let bytes = try Data(contentsOf: model.missionStoreURL)
        let action = ACTAScopedMissionListAction(model: model)
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id], audit: { event in
            if event.phase == .result && event.outcome == "success" { throw CocoaError(.fileWriteUnknown) }
        })
        let host = try XCTUnwrap(made)
        let issued = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
                                                   threadID: "fixture", actionIDs: [action.id])
        let session = try XCTUnwrap(issued)
        for arguments in [#"{"limit":1}"#, #"{"name":"synthetic-secret"}"#, "[]", "{"] {
            let result = await host.broker.request(session: session, actionID: action.id, argumentsJSON: arguments)
            XCTAssertFalse(result.success)
            XCTAssertFalse(result.outputJSON.contains(mission.id.uuidString))
            XCTAssertFalse(result.outputJSON.contains("synthetic-secret"))
        }
        let denied = await host.broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
        XCTAssertTrue(denied.error?.hasPrefix("AUDIT_FAILED:") == true)
        XCTAssertFalse(denied.outputJSON.contains(mission.id.uuidString))
        XCTAssertEqual(try Data(contentsOf: model.missionStoreURL), bytes)
        await host.broker.closeSession(session, operatorKey: host.operatorKey)
    }

    func testDisabledMissingCorruptAndInconsistentStorageFailClosed() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, mission, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let action = ACTAScopedMissionListAction(model: model)
        model.featurePreferences.enabledFeatures.remove(.scheduledMissions)
        var result = try await action.execute(parameters: [:], context: ACTAActionContext())
        XCTAssertTrue(result.error?.hasPrefix("UNAVAILABLE:") == true)
        model.featurePreferences.enabledFeatures.insert(.scheduledMissions)
        model.cameraMissions = []
        result = try await action.execute(parameters: [:], context: ACTAActionContext())
        XCTAssertTrue(result.error?.hasPrefix("STORAGE_ERROR:") == true)
        XCTAssertFalse(result.outputJSON.contains(mission.id.uuidString))
        try Data("invalid synthetic JSON".utf8).write(to: model.missionStoreURL)
        result = try await action.execute(parameters: [:], context: ACTAActionContext())
        XCTAssertTrue(result.error?.hasPrefix("STORAGE_ERROR:") == true)
        try FileManager.default.removeItem(at: model.missionStoreURL)
        result = try await action.execute(parameters: [:], context: ACTAActionContext())
        XCTAssertTrue(result.error?.hasPrefix("STORAGE_ERROR:") == true)
        XCTAssertFalse(result.outputJSON.contains("missions"))
    }

    func testMatchingEmptyStoreReturnsEmptyListWithoutWriting() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, _, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        try CameraMissionStore.save([], runs: [], consults: [], to: model.missionStoreURL)
        model.cameraMissions = []
        model.cameraMissionRuns = []
        model.cameraMissionConsultMessages = []
        let bytes = try Data(contentsOf: model.missionStoreURL)
        let action = ACTAScopedMissionListAction(model: model)
        let result = try await action.execute(parameters: [:], context: ACTAActionContext())
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.outputJSON, #"{"missions":[]}"#)
        XCTAssertEqual(try Data(contentsOf: model.missionStoreURL), bytes)
    }

    func testMissionHistoryModelRouteReleasesOnlyBoundedMetadata() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, mission, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let action = ACTAScopedMissionHistoryAction(model: model)
        let ids = WallModel.modelFacingActionIDs([action])
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: ids, audit: { _ in })
        let host = try XCTUnwrap(made)
        let issued = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
                                                   threadID: "fixture", actionIDs: ids)
        let session = try XCTUnwrap(issued)
        let coordinator = ACTAAnalyticsCoordinator(aiClient: IsolatedWallFixtureSupport.client())
        let name = "acta__mission__history"
        let call = ACTAAgentFunctionCall(callID: "history", name: name,
                                         argumentsJSON: #"{"mission_id":"\#(mission.id.uuidString)","limit":1}"#)
        let response = await coordinator.executeModelGeneratedAgentTool(call, threadID: "fixture",
            requestToolNames: [name], broker: host.broker, brokerSession: session)
        XCTAssertTrue(response.outputJSON.contains("completed"))
        XCTAssertFalse(response.outputJSON.contains("synthetic-secret"))
        XCTAssertFalse(response.outputJSON.contains(mission.cameraID.uuidString))
        let result = await host.broker.request(session: session, actionID: action.id,
            argumentsJSON: #"{"mission_id":"\#(mission.id.uuidString)","limit":1}"#)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        let rows = try XCTUnwrap(object["runs"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(Set(try XCTUnwrap(rows.first).keys), ["id", "status", "occurred_at"])
        for invalid in [#"{"mission_id":"bad"}"#,
                        #"{"mission_id":"\#(mission.id.uuidString)","limit":0}"#,
                        #"{"mission_id":"\#(mission.id.uuidString)","limit":51}"#] {
            let rejected = await host.broker.request(session: session, actionID: action.id, argumentsJSON: invalid)
            XCTAssertFalse(rejected.success)
        }
        model.cameraMissionRuns = []
        let stale = await host.broker.request(session: session, actionID: action.id,
            argumentsJSON: #"{"mission_id":"\#(mission.id.uuidString)"}"#)
        XCTAssertFalse(stale.success)
        XCTAssertFalse(stale.outputJSON.contains("completed"))
        await host.broker.closeSession(session, operatorKey: host.operatorKey)
    }

    func testReviewedMissionRunFailsClosedWithoutCrossInstanceCoordination() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, mission, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let action = ACTAReviewedMissionRunAction(model: model)
        let ids = WallModel.modelFacingActionIDs([action])
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: ids, audit: { _ in })
        let host = try XCTUnwrap(made)
        let issued = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
                                                   threadID: "fixture", actionIDs: ids)
        let session = try XCTUnwrap(issued)
        let coordinator = ACTAAnalyticsCoordinator(aiClient: IsolatedWallFixtureSupport.client())
        let name = "acta__mission__run_now"
        let call = ACTAAgentFunctionCall(callID: "run", name: name,
                                         argumentsJSON: #"{"mission_id":"\#(mission.id.uuidString)"}"#)
        let result = await coordinator.executeModelGeneratedAgentTool(call, threadID: "fixture",
            requestToolNames: [name], broker: host.broker, brokerSession: session)
        XCTAssertFalse(result.outputJSON.contains("requires_operator_confirmation"))
        XCTAssertEqual(model.missionExecutionStatus(mission.id), "idle")
        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        XCTAssertTrue(reviews.isEmpty)
        do {
            _ = try await action.prepareConfirmation(
                parameters: ["mission_id": mission.id.uuidString], context: ACTAActionContext(threadID: "fixture"))
            XCTFail("Uncoordinated mission execution must not be reviewed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("UNAVAILABLE"))
        }
        XCTAssertEqual(model.missionExecutionStatus(mission.id), "idle")
        await host.broker.closeSession(session, operatorKey: host.operatorKey)
    }

    func testSecondModelRefusesMissionWritesAndRetainsOwnerAfterShutdown() throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, first, mission, _) = try fixture()
        defer { first.shutdown(); try? FileManager.default.removeItem(at: root) }
        let secondRoot = root.appendingPathComponent("second", isDirectory: true)
        try IsolatedWallFixtureSupport.prepare(secondRoot)
        let prefs = secondRoot.appendingPathComponent("features.json")
        try CameraFeaturePreferencesStore.save(CameraFeaturePreferences(enabledFeatures: [.scheduledMissions]), to: prefs)
        let second = WallModel(configURL: secondRoot.appendingPathComponent("cameras.json"),
            poseModelURL: secondRoot.appendingPathComponent("fake-pose.mlmodel"),
            trackingStoreURL: secondRoot.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: prefs, databaseURL: secondRoot.appendingPathComponent("features.sqlite")),
            analyticsDirectoryURL: secondRoot.appendingPathComponent("analytics"),
            agentClient: IsolatedWallFixtureSupport.client(),
            cameraMemoryStore: CameraMemoryStore(url: secondRoot.appendingPathComponent("frames")),
            operationsWatchURL: secondRoot.appendingPathComponent("watches.json"), missionStoreURL: first.missionStoreURL,
            cameraCredentialStore: ACTAIsolatedCredentials(),
            operationsPreferencesURL: secondRoot.appendingPathComponent("operations.json"),
            alertClipStore: CriticalAlertClipStore(url: secondRoot.appendingPathComponent("clips")),
            languageSettings: LanguageSettings(storage: InMemoryLanguageStorage()),
            monitorHistoryURL: secondRoot.appendingPathComponent("monitor.json"),
            analyticsModelDiscovery: IsolatedWallFixtureSupport.modelDiscovery)
        defer { second.shutdown() }
        let bytes = try Data(contentsOf: first.missionStoreURL)
        XCTAssertTrue(second.missionServiceError?.contains("another application instance") == true)
        XCTAssertThrowsError(try second.missionDocumentChecked())
        XCTAssertThrowsError(try second.saveCameraMission(mission))
        XCTAssertThrowsError(try second.requestMissionRunChecked(mission.id))
        XCTAssertThrowsError(try second.clearMissionConsult(missionID: mission.id))
        XCTAssertThrowsError(try second.setFeatureEnabled(.scheduledMissions, enabled: false))
        XCTAssertEqual(try first.requestMissionRunChecked(mission.id), "queued")
        first.shutdown()
        XCTAssertThrowsError(try second.saveCameraMission(mission))
        XCTAssertEqual(try Data(contentsOf: first.missionStoreURL), bytes)
        withExtendedLifetime(first) {}
    }

    func testMissionWriteRejectsUnknownFieldsAndReentrantEdits() throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, mission, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        var nestedRejected = false
        let subscription = model.$cameraMissions.dropFirst().sink { _ in
            do { try model.saveCameraMission(mission) }
            catch { nestedRejected = true }
        }
        var edited = mission
        edited.name = "Updated mission"
        try model.saveCameraMission(edited)
        XCTAssertTrue(nestedRejected)
        XCTAssertEqual(try model.missionDocumentChecked().missions.first?.name, "Updated mission")
        withExtendedLifetime(subscription) {}
        let original = try Data(contentsOf: model.missionStoreURL)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object["future_field"] = ["must_preserve": true]
        let extended = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try extended.write(to: model.missionStoreURL, options: .atomic)
        XCTAssertThrowsError(try model.saveCameraMission(edited))
        XCTAssertThrowsError(try model.requestMissionRunChecked(edited.id))
        XCTAssertEqual(try Data(contentsOf: model.missionStoreURL), extended)
    }

    func testLeaseTransfersOnlyAfterShutdownAndOwnerDeallocation() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        var owner: WallModel?
        let root: URL
        let mission: CameraMission
        do {
            let fixture = try fixture()
            root = fixture.0
            owner = fixture.1
            mission = fixture.2
        }
        defer { owner?.shutdown(); try? FileManager.default.removeItem(at: root) }
        let missionURL = root.appendingPathComponent("missions.json")
        let denied = try additionalModel(root: root.appendingPathComponent("denied"), missionURL: missionURL)
        defer { denied.shutdown() }
        XCTAssertNotNil(denied.missionServiceError)
        XCTAssertThrowsError(try denied.requestMissionRunChecked(mission.id))
        let before = try Data(contentsOf: missionURL)
        owner?.shutdown()
        XCTAssertNil(try ACTAMissionServiceLease.acquire(storeURL: missionURL))
        weak var oldOwner = owner
        owner = nil
        let deadline = Date().addingTimeInterval(3)
        while oldOwner != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(oldOwner, "The stopped owner must release its lease when all work drains")
        guard oldOwner == nil else { return }
        let successor = try additionalModel(root: root.appendingPathComponent("successor"), missionURL: missionURL)
        defer { successor.shutdown() }
        XCTAssertNil(successor.missionServiceError)
        XCTAssertEqual(try successor.missionDocumentChecked().missions.map(\.id),
                       try CameraMissionStore.loadDocument(from: missionURL).missions.map(\.id))
        XCTAssertThrowsError(try denied.missionDocumentChecked())
        XCTAssertEqual(try Data(contentsOf: missionURL), before)
    }

    func testMissingStoreDoesNotGetRecreatedByMutation() throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, mission, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: model.missionStoreURL)
        XCTAssertThrowsError(try model.saveCameraMission(mission))
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.missionStoreURL.path))
    }

    func testOfflineSchedulerKeepsSingleQueuedMissionAndStopCancelsIt() throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, mission, disabled) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        var other = disabled
        other.enabled = true
        try model.saveCameraMission(other)
        let before = try Data(contentsOf: model.missionStoreURL)
        XCTAssertEqual(try model.requestMissionRunChecked(mission.id), "queued")
        XCTAssertEqual(try model.requestMissionRunChecked(mission.id), "queued")
        XCTAssertThrowsError(try model.requestMissionRunChecked(other.id))
        model.refresh()
        XCTAssertEqual(model.missionExecutionStatus(mission.id), "queued")
        XCTAssertNil(model.tiles[mission.cameraID]?.session)
        XCTAssertEqual(try Data(contentsOf: model.missionStoreURL), before)
        model.stop()
        XCTAssertEqual(model.missionExecutionStatus(mission.id), "idle")
        XCTAssertEqual(try Data(contentsOf: model.missionStoreURL), before)
        XCTAssertEqual(try model.requestMissionRunChecked(other.id), "queued")
    }

    func testEditingQueuedMissionMustCancelPriorRequest() throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, mission, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try model.requestMissionRunChecked(mission.id), "queued")
        try model.saveCameraMission(mission)
        XCTAssertEqual(model.missionExecutionStatus(mission.id), "queued")
        var edited = mission
        edited.brief = "Different synthetic task"
        try model.saveCameraMission(edited)
        XCTAssertEqual(model.missionExecutionStatus(mission.id), "idle",
                       "A queued review must not silently run changed execution inputs")
        model.refresh()
        XCTAssertEqual(model.missionExecutionStatus(mission.id), "idle")
    }

    func testFailedMissionEditDoesNotCancelQueuedRequest() throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, mission, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try model.requestMissionRunChecked(mission.id), "queued")
        let bytes = try Data(contentsOf: model.missionStoreURL)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object["future_field"] = true
        let unknown = try JSONSerialization.data(withJSONObject: object)
        try unknown.write(to: model.missionStoreURL, options: .atomic)
        var edited = mission
        edited.brief = "Different synthetic task"
        XCTAssertThrowsError(try model.saveCameraMission(edited))
        XCTAssertEqual(model.missionExecutionStatus(mission.id), "queued")
        XCTAssertEqual(try Data(contentsOf: model.missionStoreURL), unknown)
    }

    func testDisablingFeatureMustCancelQueuedRequest() throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, mission, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try model.requestMissionRunChecked(mission.id), "queued")
        try model.setFeatureEnabled(.scheduledMissions, enabled: false)
        XCTAssertEqual(model.missionExecutionStatus(mission.id), "idle")
        try model.setFeatureEnabled(.scheduledMissions, enabled: true)
        model.refresh()
        XCTAssertEqual(model.missionExecutionStatus(mission.id), "idle",
                       "Re-enabling the feature must not revive an old request")
    }

    func testCameraChangesInvalidateQueueAcrossABAAndNotifications() throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, mission, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try model.requestMissionRunChecked(mission.id), "queued")
        var rejected = false
        let subscription = model.$config.dropFirst().sink { _ in
            do { _ = try model.requestMissionRunChecked(mission.id) }
            catch { rejected = true }
        }
        let original = model.config.cameras[0]
        model.config.cameras[0].substream = "rtsp://changed.invalid"
        model.config.cameras[0] = original
        XCTAssertTrue(rejected)
        XCTAssertEqual(model.missionExecutionStatus(mission.id), "idle")
        withExtendedLifetime(subscription) {}
    }

    func testFailedCredentialChangeStillCancelsQueue() throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, mission, _) = try fixture(credentials: FailingMissionCredentials())
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try model.requestMissionRunChecked(mission.id), "queued")
        let camera = try XCTUnwrap(model.config.cameras.first)
        XCTAssertThrowsError(try model.save(camera: camera, credentials: Credentials(username: "fixture", password: "fixture")))
        XCTAssertEqual(model.missionExecutionStatus(mission.id), "idle")
    }

    func testDiscardingCameraSessionCancelsQueuedRequest() throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let frames = try SyntheticMissionFrames()
        let (root, model, mission, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        try XCTUnwrap(model.tiles[mission.cameraID]).session = frames.session
        XCTAssertEqual(try model.requestMissionRunChecked(mission.id), "queued")
        model.discardFileReconnect(frames.session, cameraID: mission.cameraID)
        XCTAssertEqual(model.missionExecutionStatus(mission.id), "idle")
    }

    func testActiveMissionCancellationFencesLateSyntheticInference() async throws {
        for cancellation in ["stop", "disable", "edit", "shutdown", "cameraABA", "reconnect"] {
            let previous = IsolatedWallFixtureSupport.modelPreferences()
            let frames = try SyntheticMissionFrames()
            let inference = SuspendedMissionInference()
            let finished = expectation(description: "\(cancellation) task drained")
            let hooks = WallModel.MissionExecutionHooks(
                waitForNextFrame: { frames.publish() },
                analyze: { _, _ in await inference.respond() },
                didFinish: { finished.fulfill() })
            let (root, model, mission, _) = try fixture(executionHooks: hooks)
            defer {
                model.shutdown()
                try? FileManager.default.removeItem(at: root)
                ModelSelectionRegistry.update(previous)
            }
            model.config.cameras[0].substream = ""
            model.config.cameras[0].localDeviceID = "synthetic-only"
            try ConfigurationStore.save(model.config, to: model.configURL)
            let tile = try XCTUnwrap(model.tiles[mission.cameraID])
            tile.session = frames.session
            frames.publish()
            model.running = true
            XCTAssertEqual(try model.requestMissionRunChecked(mission.id), "queued")
            model.refresh()
            let deadline = Date().addingTimeInterval(5)
            while !(await inference.started), Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard await inference.started else {
                XCTFail("\(cancellation): synthetic inference did not start")
                return
            }
            XCTAssertEqual(model.missionExecutionStatus(mission.id), "running")
            XCTAssertNil(try ACTAMissionServiceLease.acquire(storeURL: model.missionStoreURL))
            do {
                switch cancellation {
                case "stop": model.stop()
                case "disable": try model.setFeatureEnabled(.scheduledMissions, enabled: false)
                case "edit":
                    var edited = mission
                    edited.brief = "Different synthetic task"
                    try model.saveCameraMission(edited)
                case "shutdown": model.shutdown()
                case "cameraABA":
                    let original = model.config.cameras[0]
                    model.config.cameras[0].substream = "rtsp://changed.invalid"
                    model.config.cameras[0] = original
                default: model.discardFileReconnect(frames.session, cameraID: mission.cameraID)
                }
            } catch {
                model.shutdown()
                await inference.finish()
                await fulfillment(of: [finished], timeout: 5)
                throw error
            }
            let afterCancellation = try Data(contentsOf: model.missionStoreURL)
            await inference.finish()
            await fulfillment(of: [finished], timeout: 5)
            XCTAssertEqual(try Data(contentsOf: model.missionStoreURL), afterCancellation,
                           "\(cancellation): late inference must not commit")
            XCTAssertEqual(model.missionExecutionStatus(mission.id), "idle")
            XCTAssertFalse(model.vlmBusy)
            XCTAssertNil(try ACTAMissionServiceLease.acquire(storeURL: model.missionStoreURL))
        }
    }

    func testActiveMissionCommitsOnlySyntheticInferenceResult() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let frames = try SyntheticMissionFrames()
        let inference = SuspendedMissionInference()
        let finished = expectation(description: "synthetic mission task drained")
        let hooks = WallModel.MissionExecutionHooks(
            waitForNextFrame: { frames.publish() },
            analyze: { _, _ in await inference.respond() },
            didFinish: { finished.fulfill() })
        let (root, model, mission, _) = try fixture(executionHooks: hooks)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let second = try additionalModel(root: root.appendingPathComponent("second"), missionURL: model.missionStoreURL)
        defer { second.shutdown() }
        model.config.cameras[0].localDeviceID = "synthetic-only"
        try XCTUnwrap(model.tiles[mission.cameraID]).session = frames.session
        frames.publish()
        model.running = true
        XCTAssertEqual(try model.requestMissionRunChecked(mission.id), "queued")
        model.refresh()
        let deadline = Date().addingTimeInterval(5)
        while !(await inference.started), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard await inference.started else {
            XCTFail("Synthetic inference did not start")
            return
        }
        XCTAssertTrue(second.missionServiceError?.contains("another application instance") == true)
        XCTAssertThrowsError(try second.requestMissionRunChecked(mission.id))
        let runCount = model.cameraMissionRuns.count
        await inference.finish()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(model.missionExecutionStatus(mission.id), "idle")
        XCTAssertFalse(model.vlmBusy)
        let document = try model.missionDocumentChecked()
        XCTAssertEqual(document.runs.count, runCount + 1)
        XCTAssertEqual(document.runs.last?.status, .completed)
        XCTAssertEqual(document.runs.last?.summary, "One vehicle visible.")
        XCTAssertThrowsError(try second.missionDocumentChecked())
    }

    func testReentrantStopDuringMissionStartClearsBusyWithoutStartingInference() throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let frames = try SyntheticMissionFrames()
        let hooks = WallModel.MissionExecutionHooks(
            waitForNextFrame: { XCTFail("No sampling should start") },
            analyze: { _, _ in
                XCTFail("No inference should start")
                throw CancellationError()
            },
            didFinish: { XCTFail("No mission task should start") })
        let (root, model, mission, _) = try fixture(executionHooks: hooks)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.config.cameras[0].localDeviceID = "synthetic-only"
        try XCTUnwrap(model.tiles[mission.cameraID]).session = frames.session
        frames.publish()
        model.running = true
        XCTAssertEqual(try model.requestMissionRunChecked(mission.id), "queued")
        let subscription = model.$vlmBusy.dropFirst().sink { busy in
            if busy { model.stop() }
        }
        model.refresh()
        XCTAssertFalse(model.running)
        XCTAssertEqual(model.missionExecutionStatus(mission.id), "idle")
        XCTAssertFalse(model.vlmBusy, "A reentrant stop must not leave the background VLM busy")
        withExtendedLifetime(subscription) {}
    }

    func testShutdownRetainsLeaseAndFencesLateConsultCallback() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let responder = SuspendedMissionConsult()
        let (root, model, mission, _) = try fixture(responder: { _ in await responder.respond() })
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        _ = try model.askMissionConsult(missionID: mission.id, question: "Synthetic question?")
        let deadline = Date().addingTimeInterval(3)
        while !(await responder.started), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard await responder.started else { XCTFail("Consult did not reach fixture responder"); return }
        let before = try Data(contentsOf: model.missionStoreURL)
        model.shutdown()
        XCTAssertNil(try ACTAMissionServiceLease.acquire(storeURL: model.missionStoreURL))
        await responder.finish()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(try Data(contentsOf: model.missionStoreURL), before)
        XCTAssertFalse(model.missionConsultBusy)
        withExtendedLifetime(model) {}
    }
}
