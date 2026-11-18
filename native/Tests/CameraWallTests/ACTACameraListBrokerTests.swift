import CameraCore
import Foundation
import XCTest
@testable import CameraWall

private final class CameraListAudit: @unchecked Sendable {
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

private actor CameraListModelScript {
    private(set) var prompts: [String] = []
    func reply(_ prompt: String) -> String {
        prompts.append(prompt)
        if prompts.count == 1 {
            return #"{"tool_calls":[{"name":"acta__camera__list","arguments":{"include_disabled":false}}]}"#
        }
        return #"{"answerMarkdown":"Reviewed camera list.","confidence":0.5}"#
    }
}

final class ACTACameraListBrokerTests: XCTestCase {
    func testChatLoopReceivesAuditedMinimalCameraList() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acta-camera-list-chat-\(UUID().uuidString)", isDirectory: true)
        let store = try LocalTrackingStore(url: root.appendingPathComponent("tracking.sqlite"))
        defer { try? FileManager.default.removeItem(at: root) }
        let cameras = fixture()
        let scopes = ACTAAnalyticsCoordinator.localInspectionIDs
        let action = ACTAScopedCameraListAction(snapshot: { cameras })
        let audit = CameraListAudit()
        let creation = await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], allowedInspectionIDs: scopes,
            audit: { try audit.record($0) })
        let host = try XCTUnwrap(creation)
        let issued = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
            threadID: "fixture", actionIDs: [action.id], inspectionIDs: scopes)
        let session = try XCTUnwrap(issued)
        let script = CameraListModelScript()
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .mlxInProcess), transport: { _ in
            XCTFail("Unexpected network request")
            throw URLError(.notConnectedToInternet)
        }, keyProvider: { _ in XCTFail("Unexpected Keychain access"); return nil },
            localAgentInference: { prompt, _ in await script.reply(prompt) })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        _ = await coordinator.askACTAChatAgent(question: "List cameras", threadID: "fixture",
                                               broker: host.broker, brokerSession: session)
        let prompts = await script.prompts
        XCTAssertTrue(prompts.first?.contains("acta__camera__list") == true)
        XCTAssertTrue(prompts.dropFirst().contains { $0.contains("Network") && $0.contains("action_output") })
        XCTAssertTrue(prompts.allSatisfy { !$0.contains("private-host") && !$0.contains("private-token") })
        XCTAssertTrue(audit.events.contains { $0.actionID == "camera.list" && $0.outcome == "success" })
        await host.broker.closeSession(session, operatorKey: host.operatorKey)
    }

    func testModelRouteReleasesOnlyAuditedScopedCameraList() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acta-camera-list-\(UUID().uuidString)", isDirectory: true)
        let store = try LocalTrackingStore(url: root.appendingPathComponent("tracking.sqlite"))
        defer { try? FileManager.default.removeItem(at: root) }
        let cameras = fixture()
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .dryRun), transport: { _ in
            XCTFail("Unexpected network request")
            throw URLError(.notConnectedToInternet)
        }, keyProvider: { _ in XCTFail("Unexpected Keychain access"); return nil })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        let name = "acta__camera__list"
        let call = ACTAAgentFunctionCall(callID: "list", name: name, argumentsJSON: #"{"include_disabled":false}"#)
        let audit = CameraListAudit()
        let (broker, key, session) = try await makeBroker(action: ACTAScopedCameraListAction(snapshot: { cameras }), audit: audit)
        let denied = await coordinator.executeModelGeneratedAgentTool(call, threadID: "fixture",
            requestToolNames: [], broker: broker, brokerSession: session)
        XCTAssertFalse(denied.outputJSON.contains("Network"))
        XCTAssertTrue(denied.outputJSON.contains("TOOL_NOT_ADVERTISED"))
        let allowed = await coordinator.executeModelGeneratedAgentTool(call, threadID: "fixture",
            requestToolNames: [name], broker: broker, brokerSession: session)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(allowed.outputJSON.utf8)) as? [String: Any])
        let output = try XCTUnwrap(response["action_output"] as? [String: Any])
        let rows = try XCTUnwrap(output["cameras"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { Set($0.keys) == ["id", "name", "enabled", "type"] })
        XCTAssertFalse(allowed.outputJSON.contains("private-"))
        XCTAssertEqual(audit.events.last?.outcome, "success")
        await broker.closeSession(session, operatorKey: key)

        let failedAudit = CameraListAudit(failAt: 3)
        let (failingBroker, failingKey, failingSession) = try await makeBroker(
            action: ACTAScopedCameraListAction(snapshot: { cameras }), audit: failedAudit)
        let failed = await coordinator.executeModelGeneratedAgentTool(call, threadID: "fixture",
            requestToolNames: [name], broker: failingBroker, brokerSession: failingSession)
        XCTAssertTrue(failed.outputJSON.contains("AUDIT_FAILED"))
        XCTAssertFalse(failed.outputJSON.contains("Network"))
        await failingBroker.closeSession(failingSession, operatorKey: failingKey)
    }

    private func fixture() -> [Camera] {
        [
            Camera(name: "Network", location: "private-location",
                   substream: "rtsp://user:password@private-host/private-path?token=private-token",
                   mainstream: "rtsp://private-main/main", enabled: true),
            Camera(name: "USB", substream: "", enabled: false, localDeviceID: "private-device-id"),
            Camera(name: "Display", substream: "", screenDisplayID: "private-display-id"),
            Camera(name: "File", substream: "", fileURL: URL(fileURLWithPath: "/private/local/movie.mp4"),
                   fileBookmarkData: Data("private-bookmark".utf8))
        ]
    }

    private func makeBroker(
        action: ACTAScopedCameraListAction, audit: CameraListAudit
    ) async throws -> (ACTALocalActionBroker, ACTABrokerOperator, ACTABrokerSession) {
        let created = await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: ["camera.list"], audit: { try audit.record($0) })
        let host = try XCTUnwrap(created)
        let issued = await host.broker.openSession(operatorKey: host.operatorKey,
            input: .chat, threadID: "fixture", actionIDs: ["camera.list"])
        let session = try XCTUnwrap(issued)
        return (host.broker, host.operatorKey, session)
    }

    func testBrokerReturnsOnlyWhitelistedFieldsAndFiltersDisabled() async throws {
        let cameras = fixture()
        let audit = CameraListAudit()
        let (broker, key, session) = try await makeBroker(action: ACTAScopedCameraListAction(snapshot: { cameras }), audit: audit)
        for (arguments, expected) in [(#"{}"#, 4), (#"{"include_disabled":false}"#, 3)] {
            let result = await broker.request(session: session, actionID: "camera.list",
                                              argumentsJSON: arguments, expectedThreadID: "fixture")
            XCTAssertTrue(result.success)
            XCTAssertTrue(result.verified)
            let output = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
            XCTAssertEqual(Set(output.keys), ["cameras"])
            let rows = try XCTUnwrap(output["cameras"] as? [[String: Any]])
            XCTAssertEqual(rows.count, expected)
            XCTAssertTrue(rows.allSatisfy { Set($0.keys) == ["id", "name", "enabled", "type"] })
            if expected == 4 {
                XCTAssertEqual(rows.compactMap { $0["type"] as? String }, ["network_rtsp", "local_usb", "screen", "file"])
                XCTAssertEqual(rows.compactMap { $0["id"] as? String }, cameras.map { $0.id.uuidString })
            }
            for secret in ["private-", "password", "rtsp", "/private", "token", "bookmark", "device_id", "substream"] {
                // network_rtsp is an allowed source type, not a URL.
                if secret != "rtsp" { XCTAssertFalse(result.outputJSON.contains(secret), secret) }
            }
        }
        XCTAssertEqual(audit.events.count, 6)
        for group in stride(from: 0, to: 6, by: 3) {
            XCTAssertEqual(audit.events[group].phase, .request)
            XCTAssertEqual(audit.events[group + 1].phase, .validated)
            XCTAssertEqual(audit.events[group + 2].phase, .result)
            XCTAssertEqual(audit.events[group + 2].outcome, "success")
            XCTAssertTrue(audit.events[group...group + 2].allSatisfy { $0.actionID == "camera.list" })
        }
        await broker.closeSession(session, operatorKey: key)
    }

    func testInvalidArgumentsAndUnauthorizedRequestsAreAuditedAsFailures() async throws {
        let audit = CameraListAudit()
        let cameras = fixture()
        let (broker, key, session) = try await makeBroker(action: ACTAScopedCameraListAction(snapshot: { cameras }), audit: audit)
        for arguments in [#"{"include_disabled":"false"}"#, #"{"unexpected":"private-token"}"#, "not json"] {
            let before = audit.events.count
            let result = await broker.request(session: session, actionID: "camera.list",
                                              argumentsJSON: arguments, expectedThreadID: "fixture")
            XCTAssertFalse(result.success)
            XCTAssertTrue(result.error?.hasPrefix("INVALID_ARGUMENT:") == true)
            XCTAssertFalse(result.outputJSON.contains("private-token"))
            let events = Array(audit.events.dropFirst(before))
            XCTAssertEqual(events.count, 2)
            XCTAssertEqual(events.first?.phase, .request)
            XCTAssertEqual(events.last?.phase, .result)
            XCTAssertEqual(events.last?.outcome, "failed")
        }
        for thread in ["wrong-thread"] {
            let before = audit.events.count
            let denied = await broker.request(session: session, actionID: "camera.list",
                                               argumentsJSON: "{}", expectedThreadID: thread)
            XCTAssertFalse(denied.success)
            XCTAssertTrue(denied.error?.hasPrefix("AUTHORIZATION_DENIED:") == true)
            XCTAssertEqual(audit.events.count, before + 2)
            XCTAssertEqual(audit.events.last?.outcome, "failed")
        }
        session.invalidate(operatorKey: key)
        let before = audit.events.count
        let revoked = await broker.request(session: session, actionID: "camera.list",
                                           argumentsJSON: "{}", expectedThreadID: "fixture")
        XCTAssertFalse(revoked.success)
        XCTAssertTrue(revoked.error?.hasPrefix("AUTHORIZATION_DENIED:") == true)
        XCTAssertEqual(audit.events.count, before + 2)
        XCTAssertEqual(audit.events.last?.outcome, "failed")
        await broker.closeSession(session, operatorKey: key)
    }

    func testNamesCannotEchoPathsURLsOrConfiguredDeviceIdentifiers() async throws {
        let cameras = [
            Camera(name: "rtsp://secret.example/stream", substream: ""),
            Camera(name: "/private/path/movie", substream: ""),
            Camera(name: "Device private-device-id", substream: "", localDeviceID: "private-device-id"),
            Camera(name: "Known private-device-id", substream: ""),
            Camera(name: "Windows C:\\private\\video", substream: "")
        ]
        let audit = CameraListAudit()
        let (broker, key, session) = try await makeBroker(action: ACTAScopedCameraListAction(snapshot: { cameras }), audit: audit)
        let result = await broker.request(session: session, actionID: "camera.list",
                                          argumentsJSON: "{}", expectedThreadID: "fixture")
        XCTAssertTrue(result.success)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        let rows = try XCTUnwrap(object["cameras"] as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["name"] as? String }, Array(repeating: "[redacted]", count: cameras.count))
        XCTAssertEqual(audit.events.last?.outcome, "success")
        await broker.closeSession(session, operatorKey: key)
    }

    func testForeignAndOutOfScopeSessionsAreDeniedAndAudited() async throws {
        let cameras = fixture()
        let audit = CameraListAudit()
        let action = ACTAScopedCameraListAction(snapshot: { cameras })
        let created = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: ["camera.list"],
            allowedInspectionIDs: ["other"], audit: { try audit.record($0) })
        let host = try XCTUnwrap(created)
        let issued = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
            threadID: "fixture", actionIDs: [], inspectionIDs: ["other"])
        let unscoped = try XCTUnwrap(issued)
        let (other, otherKey, foreign) = try await makeBroker(action: action, audit: CameraListAudit())
        for session in [unscoped, foreign] {
            let before = audit.events.count
            let result = await host.broker.request(session: session, actionID: "camera.list",
                argumentsJSON: "{}", expectedThreadID: "fixture")
            XCTAssertFalse(result.success)
            XCTAssertTrue(result.error?.hasPrefix("AUTHORIZATION_DENIED:") == true)
            let events = Array(audit.events.dropFirst(before))
            XCTAssertEqual(events.count, 2)
            XCTAssertEqual(events.first?.phase, .request)
            XCTAssertEqual(events.last?.phase, .result)
            XCTAssertEqual(events.last?.outcome, "failed")
            XCTAssertFalse(result.outputJSON.contains("Network"))
        }
        await host.broker.closeSession(unscoped, operatorKey: host.operatorKey)
        await other.closeSession(foreign, operatorKey: otherKey)
    }

    func testAuditFailuresAndSnapshotFailureNeverReturnCameraData() async throws {
        let cameras = fixture()
        for failAt in 1...3 {
            let audit = CameraListAudit(failAt: failAt)
            let (broker, key, session) = try await makeBroker(action: ACTAScopedCameraListAction(snapshot: { cameras }), audit: audit)
            let result = await broker.request(session: session, actionID: "camera.list",
                                              argumentsJSON: "{}", expectedThreadID: "fixture")
            XCTAssertFalse(result.success, "audit failure \(failAt)")
            XCTAssertTrue(result.error?.hasPrefix("AUDIT_FAILED:") == true)
            XCTAssertFalse(result.outputJSON.contains("Network"))
            if failAt == 2 { XCTAssertEqual(audit.events.last?.outcome, "failed") }
            await broker.closeSession(session, operatorKey: key)
        }
        for failAt in 1...2 {
            let audit = CameraListAudit(failAt: failAt)
            let (broker, key, session) = try await makeBroker(action: ACTAScopedCameraListAction(snapshot: { cameras }), audit: audit)
            let denied = await broker.request(session: session, actionID: "camera.list",
                                              argumentsJSON: "{}", expectedThreadID: "wrong-thread")
            XCTAssertFalse(denied.success)
            XCTAssertTrue(denied.error?.hasPrefix("AUDIT_FAILED:") == true)
            XCTAssertFalse(denied.outputJSON.contains("Network"))
            await broker.closeSession(session, operatorKey: key)
        }
        let audit = CameraListAudit()
        let (broker, key, session) = try await makeBroker(action: ACTAScopedCameraListAction(snapshot: {
            throw CocoaError(.fileReadUnknown)
        }), audit: audit)
        let result = await broker.request(session: session, actionID: "camera.list",
                                          argumentsJSON: "{}", expectedThreadID: "fixture")
        XCTAssertFalse(result.success)
        XCTAssertFalse(result.outputJSON.contains("cameras"))
        XCTAssertEqual(audit.events.last?.outcome, "failed")
        await broker.closeSession(session, operatorKey: key)
    }
}
