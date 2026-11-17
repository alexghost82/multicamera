import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTAIncidentNoteActionTests: XCTestCase {
    private struct CredentialsFake: CameraCredentialStore {
        func read(_ id: UUID) throws -> Credentials? { XCTFail("Unexpected credential access"); return nil }
        func save(_ credentials: Credentials, for id: UUID) throws { XCTFail("Unexpected credential access") }
        func remove(_ id: UUID) throws { XCTFail("Unexpected credential access") }
    }

    private func fixture() throws -> (URL, WallModel, SafetyIncident) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let analytics = root.appendingPathComponent("analytics")
        try FileManager.default.createDirectory(at: analytics, withIntermediateDirectories: true)
        try ConfigurationStore.save(WallConfiguration(), to: root.appendingPathComponent("cameras.json"))
        var incident = SafetyIncident(cameraID: UUID(), cameraName: "synthetic", trackIDs: [UUID()],
            zoneID: UUID(), zoneName: "zone", type: .restrictedZoneIntrusion, severity: .high,
            status: .resolved, confidence: 0.75, createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 101), acknowledgedAt: Date(timeIntervalSince1970: 102),
            resolvedAt: Date(timeIntervalSince1970: 103), title: "title", explanation: "explanation",
            detectorSource: "synthetic", metrics: ["metric": 2], clipID: UUID(),
            snapshotRelativePath: "snapshot", secondaryVLMStatus: .confirmed,
            secondaryVLMSummary: "summary", operatorNotes: "old", escalationCount: 2)
        incident.suppressedUntil = Date(timeIntervalSince1970: 104)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([incident]).write(to: analytics.appendingPathComponent(UnifiedIncidentManager.defaultURL.lastPathComponent))
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .dryRun), transport: { _ in
            XCTFail("Network access is forbidden")
            throw URLError(.notConnectedToInternet)
        })
        let model = WallModel(configURL: root.appendingPathComponent("cameras.json"),
            trackingStoreURL: root.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: root.appendingPathComponent("features.json"),
                databaseURL: root.appendingPathComponent("features.sqlite")),
            analyticsDirectoryURL: analytics, agentClient: client,
            cameraMemoryStore: CameraMemoryStore(url: root.appendingPathComponent("frames")),
            operationsWatchURL: root.appendingPathComponent("watches.json"),
            missionStoreURL: root.appendingPathComponent("missions.json"),
            cameraCredentialStore: CredentialsFake(),
            operationsPreferencesURL: root.appendingPathComponent("operations.json"),
            alertClipStore: CriticalAlertClipStore(url: root.appendingPathComponent("clips")))
        return (root, model, incident)
    }

    private func registry(_ model: WallModel) async -> ACTAActionRegistry {
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        return registry
    }

    func testReviewPersistsNoteAndPreservesAllOtherFields() async throws {
        let (root, model, original) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = await registry(model)
        let tools = try await ACTAAnalyticsCoordinator.registryTools(registry: registry)
        XCTAssertTrue(tools.contains { $0.name == "acta__incident__update_note" })
        let args = ["incident_id": original.id.uuidString, "note": "  private synthetic note  "]
        let pending = try await registry.execute(actionID: "incident.update_note", parameters: args)
        XCTAssertTrue(pending.requiresOperatorConfirmation)
        XCTAssertFalse(pending.success)
        XCTAssertEqual(model.localAnalyticsEngine.incidentManager.incident(id: original.id), original)
        let result = try await registry.confirmAndExecute(token: XCTUnwrap(pending.confirmationToken), confirmed: true)
        XCTAssertTrue(result.success, result.summary)
        XCTAssertTrue(result.verified)
        XCTAssertFalse(result.outputJSON.contains("private synthetic note"))
        let manager = model.localAnalyticsEngine.incidentManager
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try XCTUnwrap(decoder.decode([SafetyIncident].self, from: Data(contentsOf: manager.storageURL)).first)
        var expected = original
        expected.operatorNotes = "private synthetic note"
        expected.updatedAt = saved.updatedAt
        XCTAssertEqual(saved, expected)
        XCTAssertEqual(model.localAnalyticsEngine.incidents.first?.operatorNotes, expected.operatorNotes)
        let audit = try decoder.decode([OperatorAuditEntry].self, from: Data(contentsOf: manager.auditLog.url))
        XCTAssertEqual(audit.first?.action, .incidentNoteUpdated)
        XCTAssertEqual(audit.first?.incidentID, original.id)
        XCTAssertEqual(audit.first?.details, expected.operatorNotes)

        let clear = try await registry.execute(actionID: "incident.update_note",
            parameters: ["incident_id": original.id.uuidString, "note": ""])
        let cleared = try await registry.confirmAndExecute(token: XCTUnwrap(clear.confirmationToken), confirmed: true)
        XCTAssertTrue(cleared.success, cleared.summary)
        XCTAssertEqual(manager.incident(id: original.id)?.operatorNotes, "")
        XCTAssertEqual(manager.incident(id: original.id)?.status, original.status)
    }

    func testInvalidOrUnconfirmedRequestsDoNotWrite() async throws {
        let (root, model, original) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = await registry(model)
        for args in [
            ["incident_id": "bad", "note": "note"],
            ["incident_id": original.id.uuidString],
            ["incident_id": original.id.uuidString, "note": String(repeating: "x", count: 4001)],
            ["incident_id": original.id.uuidString, "note": "note", "extra": "value"]
        ] {
            let result = try await registry.execute(actionID: "incident.update_note", parameters: args)
            XCTAssertFalse(result.success)
            XCTAssertFalse(result.requiresOperatorConfirmation)
        }
        let action = WallOperationalAction(specification: IncidentUpdateNoteAction(), model: model)
        do {
            _ = try await action.execute(parameters: ["incident_id": original.id.uuidString, "note": "note"],
                                         context: ACTAActionContext())
            XCTFail("Direct unconfirmed execution must fail")
        } catch {}
        let pending = try await registry.execute(actionID: action.id,
            parameters: ["incident_id": original.id.uuidString, "note": "note"])
        let declined = try await registry.confirmAndExecute(token: XCTUnwrap(pending.confirmationToken), confirmed: false)
        XCTAssertFalse(declined.success)
        XCTAssertEqual(model.localAnalyticsEngine.incidentManager.incident(id: original.id), original)
        XCTAssertFalse(model.localAnalyticsEngine.auditLog.recentEntries(limit: 200).contains {
            $0.action == .incidentNoteUpdated && $0.incidentID == original.id
        })
    }

    func testMissingAndCorruptStorageNeverReportSuccess() async throws {
        let (root, model, original) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = await registry(model)
        let missing = try await registry.execute(actionID: "incident.update_note",
            parameters: ["incident_id": UUID().uuidString, "note": "note"])
        let missingResult = try await registry.confirmAndExecute(token: XCTUnwrap(missing.confirmationToken), confirmed: true)
        XCTAssertFalse(missingResult.success)
        let manager = model.localAnalyticsEngine.incidentManager
        let corrupt = Data("{corrupt".utf8)
        try corrupt.write(to: manager.storageURL)
        let pending = try await registry.execute(actionID: "incident.update_note",
            parameters: ["incident_id": original.id.uuidString, "note": "note"])
        let result = try await registry.confirmAndExecute(token: XCTUnwrap(pending.confirmationToken), confirmed: true)
        XCTAssertFalse(result.success)
        XCTAssertFalse(result.verified)
        XCTAssertEqual(try Data(contentsOf: manager.storageURL), corrupt)
        XCTAssertEqual(manager.incident(id: original.id), original)
    }

    func testCorruptOrDivergentAuditDoesNotGetOverwritten() async throws {
        let (root, model, original) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = await registry(model)
        let auditURL = model.localAnalyticsEngine.auditLog.url
        let decoder = JSONEncoder()
        decoder.dateEncodingStrategy = .iso8601
        let foreign = OperatorAuditEntry(action: .incidentNoteUpdated, incidentID: original.id,
                                         summary: "other writer")
        for contents in [Data("{corrupt".utf8), try decoder.encode([foreign])] {
            try contents.write(to: auditURL)
            let pending = try await registry.execute(actionID: "incident.update_note",
                parameters: ["incident_id": original.id.uuidString, "note": "note"])
            let result = try await registry.confirmAndExecute(token: XCTUnwrap(pending.confirmationToken), confirmed: true)
            XCTAssertFalse(result.success)
            XCTAssertFalse(result.verified)
            XCTAssertEqual(try Data(contentsOf: auditURL), contents)
            XCTAssertEqual(model.localAnalyticsEngine.incidentManager.incident(id: original.id), original)
        }
    }
}
