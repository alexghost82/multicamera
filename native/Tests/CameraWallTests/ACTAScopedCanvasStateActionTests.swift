import CameraCore
import Foundation
import XCTest
@testable import CameraWall

private final class CanvasStateAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ACTABrokerAuditEvent] = []
    let failAt: Int?
    init(failAt: Int? = nil) { self.failAt = failAt }
    func record(_ event: ACTABrokerAuditEvent) throws {
        try lock.withLock {
            recorded.append(event)
            if recorded.count == failAt { throw CocoaError(.fileWriteUnknown) }
        }
    }
    var events: [ACTABrokerAuditEvent] { lock.withLock { recorded } }
}

private actor CanvasStateScript {
    private(set) var prompts: [String] = []
    func reply(_ prompt: String) -> String {
        prompts.append(prompt)
        if prompts.count == 1 {
            return #"{"tool_calls":[{"name":"acta__canvas__get_state","arguments":{}}]}"#
        }
        return #"{"answerMarkdown":"Canvas state inspected.","confidence":0.5}"#
    }
}

private final class CanvasStateRevoker: @unchecked Sendable {
    private let lock = NSLock()
    private var capability: (ACTABrokerSession, ACTABrokerOperator)?
    func set(_ session: ACTABrokerSession, _ key: ACTABrokerOperator) {
        lock.withLock { capability = (session, key) }
    }
    func record(_ event: ACTABrokerAuditEvent) {
        guard event.phase == .result, event.outcome == "success" else { return }
        let pair = lock.withLock { capability }
        if let pair { pair.0.invalidate(operatorKey: pair.1) }
    }
}

@MainActor
final class ACTAScopedCanvasStateActionTests: XCTestCase {
    private func viewState() -> ACTACanvasFilterState {
        ACTACanvasFilterState(analysisVoiceInput: LocalVoiceInput(
            speechPermission: { XCTFail("Unexpected speech permission request"); return false },
            microphonePermission: { XCTFail("Unexpected microphone permission request"); return false },
            makeCapture: { _, _ in
                XCTFail("Unexpected voice capture")
                throw CocoaError(.fileReadUnknown)
            }))
    }

    private func host(_ action: ACTAScopedCanvasStateAction, audit: CanvasStateAudit, scoped: Bool = true) async throws
        -> (ACTALocalActionBroker, ACTABrokerOperator, ACTABrokerSession) {
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id],
            allowedInspectionIDs: ["other"], audit: { try audit.record($0) })
        let host = try XCTUnwrap(made)
        let session = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
            threadID: "fixture", actionIDs: scoped ? [action.id] : [], inspectionIDs: scoped ? [] : ["other"])
        return (host.broker, host.operatorKey, try XCTUnwrap(session))
    }

    func testAuditedSnapshotIsWhitelistedAndDoesNotMutateView() async throws {
        let bridge = ACTACanvasFilterBridge()
        let state = viewState()
        let cameraID = UUID()
        state.presentation = .list
        state.arrangeCameras = true
        state.cameraScope = .offline
        state.favoritesOnly = true
        state.alertsOnly = true
        state.searchText = "synthetic-secret-search"
        state.locationFilter = "synthetic-secret-location"
        state.selectedCameraIDs = [cameraID]
        bridge.attach(state)
        let revision = state.reviewRevision
        let action = ACTAScopedCanvasStateAction(bridge: bridge)
        let audit = CanvasStateAudit()
        let (broker, key, session) = try await host(action, audit: audit)
        let result = await broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
        XCTAssertTrue(result.success && result.verified)
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        XCTAssertEqual(Set(output.keys), ["presentation", "arrange_mode", "status", "favorites_only",
                                         "events_only", "search_active", "location_active", "selection_active"])
        XCTAssertEqual(output["presentation"] as? String, "list")
        XCTAssertEqual(output["status"] as? String, "offline")
        for field in ["arrange_mode", "favorites_only", "events_only", "search_active", "location_active", "selection_active"] {
            XCTAssertEqual(output[field] as? Bool, true, field)
        }
        XCTAssertFalse(result.outputJSON.contains("synthetic-secret"))
        XCTAssertFalse(result.outputJSON.contains(cameraID.uuidString))
        XCTAssertEqual(state.reviewRevision, revision)
        XCTAssertEqual(audit.events.map(\.phase), [.request, .validated, .result])
        XCTAssertEqual(audit.events.last?.outcome, "success")
        state.cameraScope = .live
        state.searchText = ""
        state.locationFilter = nil
        state.selectedCameraIDs = nil
        let next = await broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
        let nextOutput = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(next.outputJSON.utf8)) as? [String: Any])
        XCTAssertEqual(nextOutput["status"] as? String, "live")
        for field in ["search_active", "location_active", "selection_active"] {
            XCTAssertEqual(nextOutput[field] as? Bool, false, field)
        }
        await broker.closeSession(session, operatorKey: key)
    }

    func testDenialsAuditFailuresAndAmbiguousWindowWithholdOutput() async throws {
        let bridge = ACTACanvasFilterBridge()
        let state = viewState()
        state.searchText = "synthetic-secret"
        bridge.attach(state)
        let action = ACTAScopedCanvasStateAction(bridge: bridge)
        let audit = CanvasStateAudit()
        let (broker, key, session) = try await host(action, audit: audit)
        for json in [#"{"search":"synthetic-secret"}"#, "[]", "null", "{"] {
            let result = await broker.request(session: session, actionID: action.id, argumentsJSON: json)
            XCTAssertFalse(result.success)
            XCTAssertFalse(result.outputJSON.contains("synthetic-secret"))
        }
        let wrongThread = await broker.request(session: session, actionID: action.id, argumentsJSON: "{}", expectedThreadID: "other")
        XCTAssertFalse(wrongThread.success)
        let other = viewState()
        bridge.attach(other)
        let ambiguous = await broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
        XCTAssertFalse(ambiguous.success)
        XCTAssertFalse(ambiguous.outputJSON.contains("presentation"))
        bridge.detach(other)
        bridge.detach(state)
        let absent = await broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
        XCTAssertFalse(absent.success)
        XCTAssertTrue(session.invalidate(operatorKey: key))
        let revoked = await broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
        XCTAssertFalse(revoked.success)
        await broker.closeSession(session, operatorKey: key)

        bridge.attach(state)
        let (otherBroker, otherKey, unscoped) = try await host(action, audit: CanvasStateAudit(), scoped: false)
        let denied = await otherBroker.request(session: unscoped, actionID: action.id, argumentsJSON: "{}")
        XCTAssertFalse(denied.success)
        XCTAssertFalse(denied.outputJSON.contains("presentation"))
        await otherBroker.closeSession(unscoped, operatorKey: otherKey)

        for phase in 1...3 {
            let (failingBroker, failingKey, failingSession) = try await host(action, audit: CanvasStateAudit(failAt: phase))
            let result = await failingBroker.request(session: failingSession, actionID: action.id, argumentsJSON: "{}")
            XCTAssertFalse(result.success)
            XCTAssertTrue(result.error?.hasPrefix("AUDIT_FAILED:") == true)
            XCTAssertFalse(result.outputJSON.contains("presentation"))
            await failingBroker.closeSession(failingSession, operatorKey: failingKey)
        }
    }

    func testRevocationAtResultAuditAndCancellationWithholdSnapshot() async throws {
        let bridge = ACTACanvasFilterBridge()
        let state = viewState()
        bridge.attach(state)
        let action = ACTAScopedCanvasStateAction(bridge: bridge)
        let revoker = CanvasStateRevoker()
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id],
                                                     audit: { revoker.record($0) })
        let brokerHost = try XCTUnwrap(made)
        let issued = await brokerHost.broker.openSession(operatorKey: brokerHost.operatorKey, input: .chat,
                                                          threadID: "fixture", actionIDs: [action.id])
        let session = try XCTUnwrap(issued)
        revoker.set(session, brokerHost.operatorKey)
        let revoked = await brokerHost.broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
        XCTAssertFalse(revoked.success)
        XCTAssertFalse(revoked.outputJSON.contains("presentation"))
        await brokerHost.broker.closeSession(session, operatorKey: brokerHost.operatorKey)

        let task = Task { try await action.execute(parameters: [:], context: ACTAActionContext()) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled inspection must not return a snapshot")
        } catch is CancellationError {
        }
    }

    func testSyntheticChatReceivesAuditedSnapshotOnly() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".canvas-state-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ACTACanvasFilterBridge()
        let state = viewState()
        state.presentation = .list
        state.searchText = "synthetic-secret-search"
        state.locationFilter = "synthetic-secret-location"
        let cameraID = UUID()
        state.selectedCameraIDs = [cameraID]
        bridge.attach(state)
        let action = ACTAScopedCanvasStateAction(bridge: bridge)
        let audit = CanvasStateAudit()
        let scopes = ACTAAnalyticsCoordinator.localInspectionIDs
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id],
            allowedInspectionIDs: scopes, audit: { try audit.record($0) })
        let brokerHost = try XCTUnwrap(made)
        let broker = brokerHost.broker
        let key = brokerHost.operatorKey
        let issued = await broker.openSession(operatorKey: key, input: .chat, threadID: "fixture",
                                               actionIDs: [action.id], inspectionIDs: scopes)
        let session = try XCTUnwrap(issued)
        let script = CanvasStateScript()
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .mlxInProcess), transport: { _ in
            XCTFail("Unexpected network request")
            throw URLError(.notConnectedToInternet)
        }, keyProvider: { _ in XCTFail("Unexpected Keychain access"); return nil },
            localAgentInference: { prompt, _ in await script.reply(prompt) })
        let store = try LocalTrackingStore(url: root.appendingPathComponent("chat.sqlite"))
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        _ = await coordinator.askACTAChatAgent(question: "Inspect canvas", threadID: "fixture",
                                              broker: broker, brokerSession: session)
        let prompts = await script.prompts
        XCTAssertTrue(prompts.first?.contains("acta__canvas__get_state") == true)
        XCTAssertTrue(prompts.dropFirst().contains { $0.contains("action_output") && $0.contains("presentation") && $0.contains("list") })
        XCTAssertTrue(prompts.allSatisfy { !$0.contains("synthetic-secret") && !$0.contains(cameraID.uuidString) })
        XCTAssertEqual(audit.events.filter { $0.actionID == action.id }.map(\.phase), [.request, .validated, .result])
        await broker.closeSession(session, operatorKey: key)
    }
}
