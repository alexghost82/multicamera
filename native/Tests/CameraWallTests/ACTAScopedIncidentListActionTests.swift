import CameraCore
import Foundation
import XCTest
@testable import CameraWall

private actor IncidentListFixture: ACTAIncidentListReadProvider {
    let rows: [SafetyIncident]
    private(set) var reads = 0
    init(_ rows: [SafetyIncident]) { self.rows = rows }
    func incidents() throws -> [SafetyIncident] {
        reads += 1
        return rows
    }
}

private struct UnavailableIncidentList: ACTAIncidentListReadProvider {
    func incidents() throws -> [SafetyIncident] {
        throw ACTAIncidentReadProviderError.unavailable
    }
}

private actor IncidentListScript {
    private(set) var prompts: [String] = []
    func reply(_ prompt: String) -> String {
        prompts.append(prompt)
        if prompts.count == 1 {
            return #"{"tool_calls":[{"name":"acta__incident__list","arguments":{"open_only":true,"limit":1}}]}"#
        }
        return #"{"answerMarkdown":"Reviewed incidents.","confidence":0.5}"#
    }
}

final class ACTAScopedIncidentListActionTests: XCTestCase {
    private func fixture() -> SafetyIncident {
        SafetyIncident(cameraID: UUID(), cameraName: "synthetic-secret-camera",
            trackIDs: [UUID()], type: .fallConfirmed, severity: .critical, status: .active,
            confidence: 0.9, createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 120), title: "synthetic-secret-title",
            explanation: "synthetic-secret-explanation", detectorSource: "synthetic-secret-device")
    }

    func testChatLoopExposesOnlyAuditedOpenMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acta-incident-list-\(UUID().uuidString)", isDirectory: true)
        let store = try LocalTrackingStore(url: root.appendingPathComponent("tracking.sqlite"))
        defer { try? FileManager.default.removeItem(at: root) }
        let incident = fixture()
        var closed = fixture()
        closed.status = .resolved
        let provider = IncidentListFixture([closed, incident, fixture()])
        let action = ACTAScopedIncidentListAction(provider: provider)
        let scopes = ACTAAnalyticsCoordinator.localInspectionIDs
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id],
                                                     allowedInspectionIDs: scopes, audit: { _ in })
        let host = try XCTUnwrap(made)
        let issued = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
            threadID: "fixture", actionIDs: [action.id], inspectionIDs: scopes)
        let session = try XCTUnwrap(issued)
        let script = IncidentListScript()
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .mlxInProcess), transport: { _ in
            XCTFail("Unexpected network request")
            throw URLError(.notConnectedToInternet)
        }, keyProvider: { _ in XCTFail("Unexpected Keychain access"); return nil },
            localAgentInference: { prompt, _ in await script.reply(prompt) })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        _ = await coordinator.askACTAChatAgent(question: "List open incidents", threadID: "fixture",
                                              broker: host.broker, brokerSession: session)
        let prompts = await script.prompts
        XCTAssertTrue(prompts.first?.contains("acta__incident__list") == true)
        XCTAssertTrue(prompts.dropFirst().contains { $0.contains(incident.id.uuidString) && $0.contains("action_output") })
        XCTAssertTrue(prompts.allSatisfy {
            !$0.contains("synthetic-secret") && !$0.contains(incident.cameraID.uuidString) && !$0.contains(closed.id.uuidString)
        })
        await host.broker.closeSession(session, operatorKey: host.operatorKey)
    }

    func testInvalidRequestsAndAuditFailureReleaseNoData() async throws {
        let incident = fixture()
        let provider = IncidentListFixture([incident])
        let action = ACTAScopedIncidentListAction(provider: provider)
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id], audit: { event in
            if event.phase == .result && event.outcome == "success" { throw CocoaError(.fileWriteUnknown) }
        })
        let host = try XCTUnwrap(made)
        let issued = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
                                                   threadID: "fixture", actionIDs: [action.id])
        let session = try XCTUnwrap(issued)
        for arguments in [#"{"limit":0}"#, #"{"limit":51}"#, #"{"open_only":"yes"}"#,
                          #"{"query":"synthetic-secret"}"#] {
            let result = await host.broker.request(session: session, actionID: action.id, argumentsJSON: arguments)
            XCTAssertFalse(result.success)
            XCTAssertFalse(result.outputJSON.contains("synthetic-secret"))
        }
        let reads = await provider.reads
        XCTAssertEqual(reads, 0)
        let denied = await host.broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
        XCTAssertTrue(denied.error?.hasPrefix("AUDIT_FAILED:") == true)
        XCTAssertFalse(denied.outputJSON.contains(incident.id.uuidString))
        await host.broker.closeSession(session, operatorKey: host.operatorKey)
    }

    func testUnavailableServiceDoesNotReturnAnEmptyList() async throws {
        let action = ACTAScopedIncidentListAction(provider: UnavailableIncidentList())
        let result = try await action.execute(parameters: [:], context: ACTAActionContext())
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.hasPrefix("UNAVAILABLE:") == true)
        XCTAssertFalse(result.outputJSON.contains("incidents"))
    }

    @MainActor
    func testEngineProviderReadsCurrentDomainIncidents() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acta-incident-list-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LocalVideoAnalyticsEngine(
            settingsURL: root.appendingPathComponent("settings.json"),
            incidentsURL: root.appendingPathComponent("incidents.json"),
            evidenceDirectoryURL: root.appendingPathComponent("evidence"),
            auditLogURL: root.appendingPathComponent("audit.json"),
            modelDiscovery: AnalyticsModelDiscovery(modelURL: { _ in nil }, integrity: { _ in
                XCTFail("Unexpected model access")
                throw ACTAIncidentReadProviderError.unavailable
            }))
        let candidate = BehaviorSafetyCandidate(cameraID: UUID(), trackIDs: [], type: .fallConfirmed,
            confidence: 0.9, monotonicTimestamp: 1, occurredAt: Date(timeIntervalSince1970: 0),
            title: "synthetic-secret-title", explanation: "synthetic-secret-explanation",
            detectorSource: "synthetic-secret-source", requiresSecondaryVLMVerification: true)
        let incident = try XCTUnwrap(engine.incidentManager.ingest(
            candidate: candidate, cameraName: "synthetic-secret-camera",
            clipID: nil, snapshotRelativePath: nil))
        let action = ACTAScopedIncidentListAction(provider: ACTAEngineIncidentListReadProvider(engine: engine))
        let result = try await action.execute(parameters: [:], context: ACTAActionContext())
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.outputJSON.contains(incident.id.uuidString))
        XCTAssertFalse(result.outputJSON.contains("synthetic-secret"))
        XCTAssertFalse(result.outputJSON.contains(incident.cameraID.uuidString))
    }

    @MainActor
    func testEngineProviderRejectsCorruptIncidentStorage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acta-incident-list-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let incidentsURL = root.appendingPathComponent("incidents.json")
        try Data("invalid synthetic JSON".utf8).write(to: incidentsURL)
        let engine = LocalVideoAnalyticsEngine(
            settingsURL: root.appendingPathComponent("settings.json"), incidentsURL: incidentsURL,
            evidenceDirectoryURL: root.appendingPathComponent("evidence"),
            auditLogURL: root.appendingPathComponent("audit.json"),
            modelDiscovery: AnalyticsModelDiscovery(modelURL: { _ in nil }, integrity: { _ in
                XCTFail("Unexpected model access")
                throw ACTAIncidentReadProviderError.unavailable
            }))
        let action = ACTAScopedIncidentListAction(provider: ACTAEngineIncidentListReadProvider(engine: engine))
        let result = try await action.execute(parameters: [:], context: ACTAActionContext())
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.hasPrefix("STORAGE_ERROR:") == true)
        XCTAssertFalse(result.outputJSON.contains("incidents"))
    }
}
