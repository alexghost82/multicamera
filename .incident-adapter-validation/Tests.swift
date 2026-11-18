import CameraCore
import Foundation
import XCTest

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

final class ACTAScopedIncidentGetActionTests: XCTestCase {
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

    private func makeBroker(_ action: ACTAScopedIncidentGetAction, _ audit: ScopedIncidentAudit) async throws
        -> (ACTALocalActionBroker, ACTABrokerOperator, ACTABrokerSession) {
        let creation = await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], audit: { try audit.record($0) })
        let host = try XCTUnwrap(creation)
        let issued = await host.broker.openSession(operatorKey: host.operatorKey,
            input: .chat, threadID: "synthetic-thread", actionIDs: [action.id])
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
        let cases: [ACTAScopedIncidentGetAction] = [
            ACTAScopedIncidentGetAction(),
            ACTAScopedIncidentGetAction(domainAction: ACTAIncidentGetAction(provider: ScopedIncidentProvider(.unavailable))),
            ACTAScopedIncidentGetAction(domainAction: ACTAIncidentGetAction(provider: ScopedIncidentProvider(.failure))),
            ACTAScopedIncidentGetAction(domainAction: ACTAIncidentGetAction(provider: ScopedIncidentProvider(.incident(nil)))),
            ACTAScopedIncidentGetAction(domainAction: ACTAIncidentGetAction(provider: ScopedIncidentProvider(.incident(fixture()))))
        ]
        for action in cases {
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
