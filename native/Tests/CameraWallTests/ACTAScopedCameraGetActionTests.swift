import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
private final class CameraGetFixture {
    var cameras: [Camera]
    var calls = 0
    var onRead: (() throws -> Void)?

    init(_ cameras: [Camera]) { self.cameras = cameras }
    func read() throws -> [Camera] {
        calls += 1
        try onRead?()
        return cameras
    }
}

private final class CameraGetAudit: @unchecked Sendable {
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

private actor CameraGetScript {
    let id: UUID
    private(set) var prompts: [String] = []
    init(id: UUID) { self.id = id }
    func reply(_ prompt: String) -> String {
        prompts.append(prompt)
        if prompts.count == 1 {
            return #"{"tool_calls":[{"name":"acta__camera__get","arguments":{"camera_id":"\#(id.uuidString)"}}]}"#
        }
        return #"{"answerMarkdown":"Camera settings inspected.","confidence":0.5}"#
    }
}

@MainActor
final class ACTAScopedCameraGetActionTests: XCTestCase {
    private struct Output: Decodable {
        struct Settings: Decodable {
            let id: UUID
            let enabled: Bool
            let yolo_enabled: Bool
            let ai_chat_enabled: Bool
            let isapi_events_enabled: Bool
        }
        let camera: Settings
    }

    private func camera(id: UUID = UUID()) -> Camera {
        Camera(id: id, name: "secret-name", location: "secret-location",
               substream: "rtsp://secret-user:secret-password@secret-host/secret-path?secret-token",
               mainstream: "secret-mainstream", enabled: false, localDeviceID: "secret-device-id",
               screenDisplayID: "secret-display-id", fileURL: URL(fileURLWithPath: "/secret-file"),
               fileBookmarkData: Data("secret-bookmark".utf8),
               yoloEnabled: true, aiChatEnabled: false, isapiEventsEnabled: true,
               isapiHTTPS: true, isapiPort: 12345)
    }

    private func makeBroker(_ action: ACTAScopedCameraGetAction, _ audit: CameraGetAudit) async throws
        -> (ACTALocalActionBroker, ACTABrokerOperator, ACTABrokerSession) {
        let creation = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id],
                                                         audit: { try audit.record($0) })
        let host = try XCTUnwrap(creation)
        let issued = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
                                                   threadID: "fixture", actionIDs: [action.id])
        return (host.broker, host.operatorKey, try XCTUnwrap(issued))
    }

    func testAuditedOutputIsStrictTypedWhitelist() async throws {
        let selected = camera()
        let other = camera()
        let fixture = CameraGetFixture([other, selected])
        let audit = CameraGetAudit()
        let action = ACTAScopedCameraGetAction(snapshot: { try fixture.read() })
        let (broker, key, session) = try await makeBroker(action, audit)
        let result = await broker.request(session: session, actionID: action.id,
            argumentsJSON: #"{"camera_id":"\#(selected.id.uuidString.lowercased())"}"#,
            expectedThreadID: "fixture")
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.verified)
        let decoded = try JSONDecoder().decode(Output.self, from: Data(result.outputJSON.utf8)).camera
        XCTAssertEqual(decoded.id, selected.id)
        XCTAssertFalse(decoded.enabled)
        XCTAssertTrue(decoded.yolo_enabled)
        XCTAssertFalse(decoded.ai_chat_enabled)
        XCTAssertTrue(decoded.isapi_events_enabled)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        XCTAssertEqual(Set(root.keys), ["camera"])
        let fields = try XCTUnwrap(root["camera"] as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["id", "enabled", "yolo_enabled", "ai_chat_enabled", "isapi_events_enabled"])
        XCTAssertEqual(fields["id"] as? String, selected.id.uuidString)
        XCTAssertEqual(fields["enabled"] as? Bool, false)
        XCTAssertEqual(fields["yolo_enabled"] as? Bool, true)
        XCTAssertEqual(fields["ai_chat_enabled"] as? Bool, false)
        XCTAssertEqual(fields["isapi_events_enabled"] as? Bool, true)
        for secret in ["secret", other.id.uuidString, "12345", "location", "device", "path", "address"] {
            XCTAssertFalse(result.outputJSON.contains(secret), secret)
            XCTAssertFalse(result.summary.contains(secret), secret)
        }
        XCTAssertTrue(result.summary.contains("not verified"))
        XCTAssertEqual(audit.events.map(\.phase), [.request, .validated, .result])
        XCTAssertEqual(audit.events.last?.outcome, "success")
        await broker.closeSession(session, operatorKey: key)
    }

    func testSyntheticChatReceivesAuditedCameraSettings() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".camera-get-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = camera()
        let fixture = CameraGetFixture([selected])
        let action = ACTAScopedCameraGetAction(snapshot: { try fixture.read() })
        let audit = CameraGetAudit()
        let scopes = ACTAAnalyticsCoordinator.localInspectionIDs
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id],
            allowedInspectionIDs: scopes, audit: { try audit.record($0) })
        let host = try XCTUnwrap(made)
        let issued = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
            threadID: "fixture", actionIDs: [action.id], inspectionIDs: scopes)
        let session = try XCTUnwrap(issued)
        let script = CameraGetScript(id: selected.id)
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .mlxInProcess), transport: { _ in
            XCTFail("Unexpected network request")
            throw URLError(.notConnectedToInternet)
        }, keyProvider: { _ in XCTFail("Unexpected Keychain access"); return nil },
            localAgentInference: { prompt, _ in await script.reply(prompt) })
        let store = try LocalTrackingStore(url: root.appendingPathComponent("tracking.sqlite"))
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        _ = await coordinator.askACTAChatAgent(question: "Inspect camera settings", threadID: "fixture",
                                               broker: host.broker, brokerSession: session)
        let prompts = await script.prompts
        XCTAssertTrue(prompts.first?.contains("acta__camera__get") == true)
        XCTAssertTrue(prompts.dropFirst().contains { $0.contains("action_output") && $0.contains("yolo_enabled") })
        XCTAssertTrue(prompts.allSatisfy { !$0.contains("secret-name") && !$0.contains("secret-password") })
        XCTAssertEqual(audit.events.filter { $0.actionID == action.id }.map(\.phase), [.request, .validated, .result])
        await host.broker.closeSession(session, operatorKey: host.operatorKey)
    }

    func testInvalidArgumentsAndDeniedRequestsDoNotRead() async throws {
        let fixture = CameraGetFixture([camera()])
        let action = ACTAScopedCameraGetAction(snapshot: { try fixture.read() })
        let (broker, key, session) = try await makeBroker(action, CameraGetAudit())
        let bad = ["{}", #"{"camera_id":"secret-name"}"#, #"{"camera_id":4}"#,
                   #"{"camera_id":true}"#, #"{"camera_id":null}"#,
                   #"{"camera_id":"\#(UUID().uuidString)","extra":"secret"}"#, "[]", "{"]
        for arguments in bad {
            let result = await broker.request(session: session, actionID: action.id,
                                              argumentsJSON: arguments, expectedThreadID: "fixture")
            XCTAssertFalse(result.success)
            XCTAssertTrue(result.error?.hasPrefix("INVALID_ARGUMENT:") == true, "\(arguments): \(result)")
            XCTAssertFalse(result.outputJSON.contains("secret"))
        }
        let direct = try await action.execute(parameters: ["camera_id": "secret-name"], context: ACTAActionContext())
        XCTAssertTrue(direct.error?.hasPrefix("INVALID_ARGUMENT:") == true)
        let denied = await broker.request(session: session, actionID: action.id,
            argumentsJSON: #"{"camera_id":"\#(UUID().uuidString)"}"#, expectedThreadID: "wrong")
        XCTAssertFalse(denied.success)
        XCTAssertEqual(fixture.calls, 0)
        await broker.closeSession(session, operatorKey: key)
    }

    func testMissingDuplicateUnavailableAndProviderErrorFailClosed() async throws {
        let selected = camera()
        let args = ["camera_id": selected.id.uuidString]
        let missing = CameraGetFixture([])
        let duplicate = CameraGetFixture([selected, camera(id: selected.id)])
        let failing = CameraGetFixture([selected])
        failing.onRead = { throw NSError(domain: "secret-provider-error", code: 1) }
        let cases: [(ACTAScopedCameraGetAction, String)] = [
            (ACTAScopedCameraGetAction(), "UNAVAILABLE:"),
            (ACTAScopedCameraGetAction(snapshot: { try missing.read() }), "NOT_FOUND:"),
            (ACTAScopedCameraGetAction(snapshot: { try duplicate.read() }), "AMBIGUOUS:"),
            (ACTAScopedCameraGetAction(snapshot: { try failing.read() }), "STORAGE_ERROR:")
        ]
        for (action, expected) in cases {
            let result = try await action.execute(parameters: args, context: ACTAActionContext())
            XCTAssertFalse(result.success)
            XCTAssertTrue(result.error?.hasPrefix(expected) == true)
            XCTAssertFalse(result.outputJSON.contains("secret"))
            XCTAssertFalse(result.outputJSON.contains(selected.id.uuidString))
            let audit = CameraGetAudit()
            let (broker, key, session) = try await makeBroker(action, audit)
            let response = await broker.request(session: session, actionID: action.id,
                argumentsJSON: #"{"camera_id":"\#(selected.id.uuidString)"}"#, expectedThreadID: "fixture")
            XCTAssertFalse(response.success)
            XCTAssertFalse(response.outputJSON.contains(selected.id.uuidString))
            XCTAssertFalse(response.outputJSON.contains("secret"))
            XCTAssertEqual(audit.events.last?.outcome, "failed")
            await broker.closeSession(session, operatorKey: key)
        }
    }

    func testCancellationBeforeAndDuringReadNeverReleasesSnapshot() async throws {
        let selected = camera()
        let fixture = CameraGetFixture([selected])
        let action = ACTAScopedCameraGetAction(snapshot: { try fixture.read() })
        let before = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await action.execute(parameters: ["camera_id": selected.id.uuidString], context: ACTAActionContext())
        }
        do {
            _ = try await before.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(fixture.calls, 0)

        fixture.onRead = { withUnsafeCurrentTask { $0?.cancel() } }
        let during = Task {
            try await action.execute(parameters: ["camera_id": selected.id.uuidString], context: ACTAActionContext())
        }
        do {
            _ = try await during.value
            XCTFail("Expected cancellation during read")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let audit = CameraGetAudit()
        let (broker, key, session) = try await makeBroker(action, audit)
        let response = await Task {
            await broker.request(session: session, actionID: action.id,
                argumentsJSON: #"{"camera_id":"\#(selected.id.uuidString)"}"#, expectedThreadID: "fixture")
        }.value
        XCTAssertFalse(response.success)
        XCTAssertTrue(response.error?.hasPrefix("ACTION_CANCELLED:") == true)
        XCTAssertFalse(response.outputJSON.contains(selected.id.uuidString))
        XCTAssertEqual(audit.events.last?.outcome, "failed")
        await broker.closeSession(session, operatorKey: key)
    }

    func testAuditFailuresAndRevocationDoNotReleaseSnapshot() async throws {
        let selected = camera()
        for failAt in 1...3 {
            let fixture = CameraGetFixture([selected])
            let action = ACTAScopedCameraGetAction(snapshot: { try fixture.read() })
            let audit = CameraGetAudit(failAt: failAt)
            let (broker, key, session) = try await makeBroker(action, audit)
            let result = await broker.request(session: session, actionID: action.id,
                argumentsJSON: #"{"camera_id":"\#(selected.id.uuidString)"}"#, expectedThreadID: "fixture")
            XCTAssertTrue(result.error?.hasPrefix("AUDIT_FAILED:") == true)
            XCTAssertFalse(result.outputJSON.contains(selected.id.uuidString))
            XCTAssertEqual(fixture.calls, failAt == 3 ? 1 : 0)
            await broker.closeSession(session, operatorKey: key)
        }

        let fixture = CameraGetFixture([selected])
        let action = ACTAScopedCameraGetAction(snapshot: { try fixture.read() })
        let audit = CameraGetAudit()
        let (broker, key, session) = try await makeBroker(action, audit)
        fixture.onRead = { session.invalidate(operatorKey: key) }
        let result = await broker.request(session: session, actionID: action.id,
            argumentsJSON: #"{"camera_id":"\#(selected.id.uuidString)"}"#, expectedThreadID: "fixture")
        XCTAssertFalse(result.success)
        XCTAssertFalse(result.outputJSON.contains(selected.id.uuidString))
        XCTAssertEqual(fixture.calls, 1)
        let revoked = await broker.request(session: session, actionID: action.id,
            argumentsJSON: #"{"camera_id":"\#(selected.id.uuidString)"}"#, expectedThreadID: "fixture")
        XCTAssertFalse(revoked.success)
        XCTAssertEqual(fixture.calls, 1)
        await broker.closeSession(session, operatorKey: key)
    }
}
