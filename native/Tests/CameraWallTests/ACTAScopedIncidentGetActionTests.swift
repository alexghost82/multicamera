import CameraCore
import Foundation
import XCTest
@testable import CameraWall

private actor ScopedIncidentProvider: ACTAIncidentReadProvider {
    enum Response {
        case incident(SafetyIncident?)
        case unavailable
        case failure
    }

    struct SecretError: LocalizedError {
        var errorDescription: String? { "synthetic-secret-error" }
    }

    let response: Response
    private(set) var requests = 0
    init(_ response: Response) { self.response = response }
    func incident(id: UUID) async throws -> SafetyIncident? {
        requests += 1
        switch response {
        case .incident(let incident): return incident
        case .unavailable: throw ACTAIncidentReadProviderError.unavailable
        case .failure: throw SecretError()
        }
    }
}

private final class ScopedIncidentAudit: @unchecked Sendable {
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

private actor IncidentModelScript {
    let incidentID: UUID
    private(set) var prompts: [String] = []
    init(incidentID: UUID) { self.incidentID = incidentID }
    func reply(_ prompt: String) -> String {
        prompts.append(prompt)
        if prompts.count == 1 {
            return #"{"tool_calls":[{"name":"acta__incident__get","arguments":{"incident_id":"\#(incidentID.uuidString)"}}]}"#
        }
        return #"{"answerMarkdown":"Reviewed incident.","confidence":0.5}"#
    }
}

final class ACTAScopedIncidentGetActionTests: XCTestCase {
    func testChatLoopReceivesOnlyAuditedIncidentMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acta-incident-chat-\(UUID().uuidString)", isDirectory: true)
        let store = try LocalTrackingStore(url: root.appendingPathComponent("tracking.sqlite"))
        defer { try? FileManager.default.removeItem(at: root) }
        let incident = fixture()
        let audit = ScopedIncidentAudit()
        let action = ACTAScopedIncidentGetAction(
            domainAction: ACTAIncidentGetAction(provider: ScopedIncidentProvider(.incident(incident))))
        let (broker, key, session) = try await makeBroker(action, audit, chatScopes: true)
        let script = IncidentModelScript(incidentID: incident.id)
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .mlxInProcess), transport: { _ in
            XCTFail("Unexpected network request")
            throw URLError(.notConnectedToInternet)
        }, keyProvider: { _ in XCTFail("Unexpected Keychain access"); return nil },
            localAgentInference: { prompt, _ in await script.reply(prompt) })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        _ = await coordinator.askACTAChatAgent(question: "Inspect this incident", threadID: "synthetic-thread",
                                              broker: broker, brokerSession: session)
        let prompts = await script.prompts
        XCTAssertTrue(prompts.first?.contains("acta__incident__get") == true)
        XCTAssertTrue(prompts.dropFirst().contains { $0.contains("FALL_CONFIRMED") && $0.contains("action_output") })
        XCTAssertTrue(prompts.allSatisfy { !$0.contains("synthetic-secret") && !$0.contains(incident.cameraID.uuidString) })
        XCTAssertTrue(audit.events.contains { $0.actionID == "incident.get" && $0.outcome == "success" })
        await broker.closeSession(session, operatorKey: key)
    }

    func testModelRouteDoesNotReleaseIncidentOnAuditFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acta-incident-audit-\(UUID().uuidString)", isDirectory: true)
        let store = try LocalTrackingStore(url: root.appendingPathComponent("tracking.sqlite"))
        defer { try? FileManager.default.removeItem(at: root) }
        let incident = fixture()
        let action = ACTAScopedIncidentGetAction(
            domainAction: ACTAIncidentGetAction(provider: ScopedIncidentProvider(.incident(incident))))
        let (broker, key, session) = try await makeBroker(action, ScopedIncidentAudit(failAt: 3))
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .dryRun), transport: { _ in
            XCTFail("Unexpected network request")
            throw URLError(.notConnectedToInternet)
        }, keyProvider: { _ in XCTFail("Unexpected Keychain access"); return nil })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        let name = "acta__incident__get"
        let call = ACTAAgentFunctionCall(callID: "get", name: name,
            argumentsJSON: #"{"incident_id":"\#(incident.id.uuidString)"}"#)
        let result = await coordinator.executeModelGeneratedAgentTool(call, threadID: "synthetic-thread",
            requestToolNames: [name], broker: broker, brokerSession: session)
        XCTAssertTrue(result.outputJSON.contains("AUDIT_FAILED"))
        XCTAssertFalse(result.outputJSON.contains("action_output"))
        XCTAssertFalse(result.outputJSON.contains("FALL_CONFIRMED"))
        await broker.closeSession(session, operatorKey: key)
    }

    private func fixture() -> SafetyIncident {
        var incident = SafetyIncident(
            cameraID: UUID(), cameraName: "synthetic-secret-camera",
            trackIDs: [UUID()], zoneID: UUID(), zoneName: "synthetic-secret-zone",
            type: .fallConfirmed, severity: .critical, status: .suppressed, confidence: 0.9,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 60),
            title: "synthetic-secret-title", explanation: "synthetic-secret-explanation",
            detectorSource: "synthetic-secret-device", clipID: UUID(),
            snapshotRelativePath: "/synthetic-secret-evidence",
            secondaryVLMSummary: "synthetic-secret-summary", operatorNotes: "synthetic-secret-notes")
        incident.suppressedUntil = Date(timeIntervalSince1970: 120)
        return incident
    }

    private func makeBroker(_ action: ACTAScopedIncidentGetAction, _ audit: ScopedIncidentAudit,
                            chatScopes: Bool = false) async throws
        -> (ACTALocalActionBroker, ACTABrokerOperator, ACTABrokerSession) {
        let scopes = chatScopes ? ACTAAnalyticsCoordinator.localInspectionIDs : []
        let creation = await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], allowedInspectionIDs: scopes,
            audit: { try audit.record($0) })
        let host = try XCTUnwrap(creation)
        let issued = await host.broker.openSession(operatorKey: host.operatorKey,
            input: .chat, threadID: "synthetic-thread", actionIDs: [action.id], inspectionIDs: scopes)
        let session = try XCTUnwrap(issued)
        return (host.broker, host.operatorKey, session)
    }

    func testAuditedBrokerReturnsOnlyWhitelistedMetadata() async throws {
        let incident = fixture()
        let provider = ScopedIncidentProvider(.incident(incident))
        let audit = ScopedIncidentAudit()
        let action = ACTAScopedIncidentGetAction(domainAction: ACTAIncidentGetAction(provider: provider))
        let (broker, key, session) = try await makeBroker(action, audit)
        let result = await broker.request(session: session, actionID: action.id,
            argumentsJSON: #"{"incident_id":"\#(incident.id.uuidString.lowercased())"}"#,
            expectedThreadID: "synthetic-thread")
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.verified)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        XCTAssertEqual(Set(root.keys), ["incident"])
        let fields = try XCTUnwrap(root["incident"] as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["id", "type", "severity", "status", "created_at", "updated_at", "suppressed_until"])
        XCTAssertEqual(fields["id"] as? String, incident.id.uuidString)
        XCTAssertEqual(fields["type"] as? String, "FALL_CONFIRMED")
        XCTAssertEqual(fields["status"] as? String, "SUPPRESSED")
        XCTAssertEqual(fields["suppressed_until"] as? String, "1970-01-01T00:02:00Z")
        for secret in ["synthetic-secret", incident.cameraID.uuidString, incident.trackIDs[0].uuidString,
                       incident.zoneID!.uuidString, incident.clipID!.uuidString, "camera_id", "evidence", "notes"] {
            XCTAssertFalse(result.outputJSON.contains(secret), secret)
        }
        XCTAssertEqual(audit.events.map(\.phase), [.request, .validated, .result])
        XCTAssertEqual(audit.events.last?.outcome, "success")
        await broker.closeSession(session, operatorKey: key)
    }

    func testInvalidAndUnauthorizedRequestsNeverReachProvider() async throws {
        let provider = ScopedIncidentProvider(.incident(fixture()))
        let audit = ScopedIncidentAudit()
        let action = ACTAScopedIncidentGetAction(domainAction: ACTAIncidentGetAction(provider: provider))
        let (broker, key, session) = try await makeBroker(action, audit)
        for arguments in ["{}", #"{"incident_id":"bad"}"#,
                          #"{"incident_id":3}"#, #"{"incident_id":"bad","extra":"synthetic-secret"}"#] {
            let result = await broker.request(session: session, actionID: action.id,
                argumentsJSON: arguments, expectedThreadID: "synthetic-thread")
            XCTAssertFalse(result.success)
            XCTAssertTrue(result.error?.hasPrefix("INVALID_ARGUMENT:") == true)
            XCTAssertFalse(result.outputJSON.contains("synthetic-secret"))
        }
        let denied = await broker.request(session: session, actionID: action.id,
            argumentsJSON: "{}", expectedThreadID: "wrong-thread")
        XCTAssertFalse(denied.success)
        XCTAssertTrue(denied.error?.hasPrefix("AUTHORIZATION_DENIED:") == true)
        session.invalidate(operatorKey: key)
        let revoked = await broker.request(session: session, actionID: action.id,
            argumentsJSON: "{}", expectedThreadID: "synthetic-thread")
        XCTAssertFalse(revoked.success)
        let requests = await provider.requests
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(audit.events.last?.outcome, "failed")
        await broker.closeSession(session, operatorKey: key)
    }

    func testMissingServiceAndErrorsFailClosedThroughBroker() async throws {
        let incident = fixture()
        let cases: [(ACTAScopedIncidentGetAction, String)] = [
            (ACTAScopedIncidentGetAction(), "UNAVAILABLE:"),
            (ACTAScopedIncidentGetAction(domainAction: ACTAIncidentGetAction(provider: ScopedIncidentProvider(.unavailable))), "UNAVAILABLE:"),
            (ACTAScopedIncidentGetAction(domainAction: ACTAIncidentGetAction(provider: ScopedIncidentProvider(.failure))), "STORAGE_ERROR:"),
            (ACTAScopedIncidentGetAction(domainAction: ACTAIncidentGetAction(provider: ScopedIncidentProvider(.incident(nil)))), "NOT_FOUND:"),
            (ACTAScopedIncidentGetAction(domainAction: ACTAIncidentGetAction(provider: ScopedIncidentProvider(.incident(fixture())))), "STORAGE_ERROR:")
        ]
        for (action, expected) in cases {
            let direct = try await action.execute(parameters: ["incident_id": incident.id.uuidString],
                                                  context: ACTAActionContext())
            XCTAssertFalse(direct.success)
            XCTAssertTrue(direct.error?.hasPrefix(expected) == true)
            XCTAssertFalse(direct.outputJSON.contains("synthetic-secret"))
            let audit = ScopedIncidentAudit()
            let (broker, key, session) = try await makeBroker(action, audit)
            let result = await broker.request(session: session, actionID: action.id,
                argumentsJSON: #"{"incident_id":"\#(incident.id.uuidString)"}"#,
                expectedThreadID: "synthetic-thread")
            XCTAssertFalse(result.success)
            XCTAssertFalse(result.verified)
            XCTAssertTrue(result.error?.hasPrefix("ACTION_FAILED:") == true)
            XCTAssertFalse(result.outputJSON.contains("synthetic-secret"))
            XCTAssertFalse(result.outputJSON.contains("\"incident\""))
            XCTAssertEqual(audit.events.last?.outcome, "failed")
            await broker.closeSession(session, operatorKey: key)
        }
    }

    func testMissingSuppressionDeadlineIsOmitted() async throws {
        var incident = fixture()
        incident.suppressedUntil = nil
        let action = ACTAScopedIncidentGetAction(
            domainAction: ACTAIncidentGetAction(provider: ScopedIncidentProvider(.incident(incident))))
        let (broker, key, session) = try await makeBroker(action, ScopedIncidentAudit())
        let result = await broker.request(session: session, actionID: action.id,
            argumentsJSON: #"{"incident_id":"\#(incident.id.uuidString)"}"#,
            expectedThreadID: "synthetic-thread")
        XCTAssertTrue(result.success)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        let fields = try XCTUnwrap(root["incident"] as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["id", "type", "severity", "status", "created_at", "updated_at"])
        await broker.closeSession(session, operatorKey: key)
    }

    func testAuditFailuresNeverReleaseIncident() async throws {
        let incident = fixture()
        for failAt in 1...3 {
            let provider = ScopedIncidentProvider(.incident(incident))
            let audit = ScopedIncidentAudit(failAt: failAt)
            let action = ACTAScopedIncidentGetAction(domainAction: ACTAIncidentGetAction(provider: provider))
            let (broker, key, session) = try await makeBroker(action, audit)
            let result = await broker.request(session: session, actionID: action.id,
                argumentsJSON: #"{"incident_id":"\#(incident.id.uuidString)"}"#,
                expectedThreadID: "synthetic-thread")
            XCTAssertFalse(result.success)
            XCTAssertTrue(result.error?.hasPrefix("AUDIT_FAILED:") == true)
            XCTAssertFalse(result.outputJSON.contains(incident.id.uuidString))
            let requests = await provider.requests
            XCTAssertEqual(requests, failAt == 3 ? 1 : 0)
            await broker.closeSession(session, operatorKey: key)
        }
    }
}
