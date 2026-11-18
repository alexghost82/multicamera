import CameraCore
import Foundation
import XCTest
@testable import CameraWall

private struct IncidentTestCredentials: CameraCredentialStore {
    func read(_ id: UUID) throws -> Credentials? { XCTFail("Unexpected credential read"); return nil }
    func save(_ credentials: Credentials, for id: UUID) throws { XCTFail("Unexpected credential save") }
    func remove(_ id: UUID) throws { XCTFail("Unexpected credential removal") }
}

private struct IncidentAuditProbe: ACTAActionProtocol {
    let id: String
    let title = "Synthetic probe"
    let description = "Synthetic audit probe"
    let classification = ACTAActionClassification.inspect
    let parameters = [
        ACTAActionParameterSchema(name: "query", type: "string", description: "Synthetic query"),
        ACTAActionParameterSchema(name: "note", type: "string", description: "Synthetic note")
    ]

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        ACTAActionResult(actionID: id, success: true, summary: "Synthetic result")
    }
}

@MainActor
final class ACTAIncidentSearchTests: XCTestCase {
    private func incident(cameraID: UUID, cameraName: String = "Camera",
                          status: SafetyIncidentStatus = .active, title: String = "Other title",
                          explanation: String = "Other explanation", notes: String = "",
                          source: String = "test", summary: String? = nil) -> SafetyIncident {
        SafetyIncident(cameraID: cameraID, cameraName: cameraName, trackIDs: [],
                       type: .fallConfirmed, severity: .critical, status: status, confidence: 0.9,
                       createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 60),
                       title: title, explanation: explanation, detectorSource: source,
                       snapshotRelativePath: "path-only-marker", secondaryVLMSummary: summary,
                       operatorNotes: notes)
    }

    private func manager(root: URL, incidents: [SafetyIncident]) throws -> UnifiedIncidentManager {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let incidentsURL = root.appendingPathComponent("incidents.json")
        try encoder.encode(incidents).write(to: incidentsURL)
        return UnifiedIncidentManager(storageURL: incidentsURL,
                                      auditLog: OperatorAuditLog(url: root.appendingPathComponent("audit.json")))
    }

    func testFieldsLocalizationAndExactGUIQuerySemantics() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cameraID = UUID()
        let camera = incident(cameraID: cameraID, cameraName: "Gate North")
        let title = incident(cameraID: cameraID, title: "Fall Confirmed")
        let explanation = incident(cameraID: cameraID, explanation: "Slippery FLOOR")
        let notes = incident(cameraID: cameraID, notes: "Reviewed by OPERATOR")
        let hidden = incident(cameraID: cameraID, source: "source-only-marker", summary: "summary-only-marker")
        let entries = [camera, title, explanation, notes, hidden]
        let manager = try manager(root: root, incidents: entries)
        func search(_ query: String, language: AppLanguage = .english) throws -> [UUID] {
            try WallOperationalAction.listIncidents(parameters: ["query": query], manager: manager,
                persistenceError: manager.lastPersistenceError,
                localizeTitle: language.localizedMessage).map(\.id)
        }

        XCTAssertEqual(try search("gate NORTH"), [camera.id])
        XCTAssertEqual(try search("fall confirmed"), [title.id])
        XCTAssertEqual(try search("падение подтверждено", language: .russian), [title.id])
        XCTAssertEqual(try search("floor"), [explanation.id])
        XCTAssertEqual(try search("operator"), [notes.id])
        XCTAssertEqual(try search(""), entries.map(\.id))
        XCTAssertTrue(try search(" gate ").isEmpty, "Do not trim the GUI query")
        XCTAssertTrue(try search("source-only-marker").isEmpty)
        XCTAssertTrue(try search("summary-only-marker").isEmpty)
        XCTAssertTrue(try search("path-only-marker").isEmpty)
        XCTAssertTrue(try search("fall confirmed", language: .russian).isEmpty,
                      "The GUI searches the localized title, not both title variants")
    }

    func testFiltersLimitOrderingAndUnchangedRecords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let selectedCamera = UUID()
        let otherCamera = UUID()
        let closed = incident(cameraID: selectedCamera, status: .resolved, explanation: "needle")
        let wrongCamera = incident(cameraID: otherCamera, explanation: "needle")
        let first = incident(cameraID: selectedCamera, explanation: "needle", notes: "fixture note")
        let second = incident(cameraID: selectedCamera, explanation: "NEEDLE")
        let entries = [closed, wrongCamera, first, second]
        let manager = try manager(root: root, incidents: entries)
        let language = AppLanguage.english
        let result = try WallOperationalAction.listIncidents(parameters: [
            "query": "needle", "camera_id": selectedCamera.uuidString, "open_only": "true", "limit": "1"
        ], manager: manager, persistenceError: manager.lastPersistenceError, localizeTitle: language.localizedMessage)
        XCTAssertEqual(result, [first], "Apply all filters before the limit without changing records or order")
        XCTAssertEqual(try WallOperationalAction.listIncidents(parameters: [:], manager: manager,
            persistenceError: manager.lastPersistenceError, localizeTitle: language.localizedMessage), entries)
        XCTAssertEqual(try WallOperationalAction.listIncidents(parameters: ["limit": "100"], manager: manager,
            persistenceError: manager.lastPersistenceError, localizeTitle: language.localizedMessage), entries)
        XCTAssertTrue(try WallOperationalAction.listIncidents(parameters: ["camera_id": UUID().uuidString], manager: manager,
            persistenceError: manager.lastPersistenceError, localizeTitle: language.localizedMessage).isEmpty)
        XCTAssertThrowsError(try WallOperationalAction.listIncidents(parameters: ["camera_id": "bad"], manager: manager,
            persistenceError: manager.lastPersistenceError, localizeTitle: language.localizedMessage))
        for limit in ["0", "101"] {
            XCTAssertThrowsError(try WallOperationalAction.listIncidents(parameters: ["limit": limit], manager: manager,
                persistenceError: manager.lastPersistenceError, localizeTitle: language.localizedMessage))
        }
    }

    func testUnavailableIncidentStorageDoesNotReturnEmptySuccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("incidents.json")
        let broken = Data("{invalid".utf8)
        try broken.write(to: url)
        let manager = UnifiedIncidentManager(storageURL: url, auditLog: OperatorAuditLog(url: root.appendingPathComponent("audit.json")))
        let error = try XCTUnwrap(manager.lastPersistenceError)
        XCTAssertThrowsError(try WallOperationalAction.listIncidents(parameters: ["query": "fixture"],
            manager: manager, persistenceError: error, localizeTitle: AppLanguage.english.localizedMessage))
        XCTAssertEqual(try Data(contentsOf: url), broken)
    }

    func testRegistrySearchUsesLiveIncidentService() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let root = IsolatedWallFixtureSupport.root()
        try IsolatedWallFixtureSupport.prepare(root)
        let analytics = root.appendingPathComponent("analytics")
        try FileManager.default.createDirectory(at: analytics, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wanted = incident(cameraID: UUID(), cameraName: "Synthetic North")
        let other = incident(cameraID: UUID(), cameraName: "Synthetic South")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([wanted, other]).write(to: analytics.appendingPathComponent(UnifiedIncidentManager.defaultURL.lastPathComponent))
        let model = WallModel(configURL: root.appendingPathComponent("cameras.json"),
            poseModelURL: root.appendingPathComponent("fake-pose.mlmodel"),
            trackingStoreURL: root.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: root.appendingPathComponent("features.json"),
                databaseURL: root.appendingPathComponent("features.sqlite")),
            analyticsDirectoryURL: analytics, agentClient: IsolatedWallFixtureSupport.client(),
            cameraMemoryStore: CameraMemoryStore(url: root.appendingPathComponent("frames")),
            operationsWatchURL: root.appendingPathComponent("watches.json"),
            missionStoreURL: root.appendingPathComponent("missions.json"),
            cameraCredentialStore: IncidentTestCredentials(),
            operationsPreferencesURL: root.appendingPathComponent("operations.json"),
            alertClipStore: CriticalAlertClipStore(url: root.appendingPathComponent("clips")),
            languageSettings: LanguageSettings(storage: InMemoryLanguageStorage()),
            monitorHistoryURL: root.appendingPathComponent("monitor.json"),
            analyticsModelDiscovery: IsolatedWallFixtureSupport.modelDiscovery)
        defer { model.shutdown() }
        IsolatedWallFixtureSupport.assertSafe(model)
        let registry = ACTAActionRegistry()
        await registry.register(WallOperationalAction(specification: IncidentListAction(), model: model))
        let result = try await registry.execute(actionID: "incident.list", parameters: ["query": "NORTH"])
        XCTAssertTrue(result.success, result.summary)
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        let incidents = try XCTUnwrap(output["incidents"] as? [[String: Any]])
        XCTAssertEqual(incidents.count, 1)
        XCTAssertEqual(incidents.first?["id"] as? String, wanted.id.uuidString)
    }

    func testSchemaRegistryValidationAndTransportNormalization() async throws {
        let action = IncidentListAction()
        let query = try XCTUnwrap(action.parameters.first { $0.name == "query" })
        XCTAssertEqual(query.type, "string")
        XCTAssertFalse(query.isRequired)
        let registry = ACTAActionRegistry()
        await registry.register(action)
        let tools = try await ACTAAnalyticsCoordinator.registryTools(registry: registry)
        let tool = try XCTUnwrap(tools.first { $0.name == "acta__incident__list" })
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(tool.parametersSchemaJSON.utf8)) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        XCTAssertEqual(properties["query"]?["type"] as? String, "string")
        for arguments in [["query": "fixture", "unexpected": "x"], ["open_only": "yes"],
                          ["limit": "not-an-integer"]] {
            let result = try await registry.execute(actionID: "incident.list", parameters: arguments)
            XCTAssertTrue(result.error?.hasPrefix("INVALID_ARGUMENT:") == true)
        }
        let accepted = try await registry.execute(actionID: "incident.list", parameters: ["query": ""])
        XCTAssertTrue(accepted.error?.hasPrefix("UNSUPPORTED:") == true)
        let call = ACTAAgentFunctionCall(callID: "fixture", name: "acta__incident__list",
                                        argumentsJSON: #"{"query":true}"#)
        XCTAssertEqual(call.arguments["query"], "true", "The shared transport normalizes JSON values")
    }

    func testIncidentQueryIsRedactedInBothAuditRecordsWithoutChangingOtherActions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalTrackingStore(url: root.appendingPathComponent("history.sqlite"))
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .dryRun), transport: { _ in
            throw URLError(.notConnectedToInternet)
        })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        let registry = ACTAActionRegistry.shared
        let original = await registry.action(for: "incident.list")
        let originalAlert = await registry.action(for: "alert.vlm_review")
        let originalNote = await registry.action(for: "incident.update_note")
        let originalTransition = await registry.action(for: "incident.transition_status")
        let otherID = "test.incident.audit"
        let originalOther = await registry.action(for: otherID)
        await registry.register(IncidentAuditProbe(id: "incident.list"))
        await registry.register(IncidentAuditProbe(id: "alert.vlm_review"))
        await registry.register(IncidentAuditProbe(id: "incident.update_note"))
        await registry.register(IncidentAuditProbe(id: "incident.transition_status"))
        await registry.register(IncidentAuditProbe(id: otherID))
        let thread = UUID().uuidString
        let query = "synthetic-private-query"
        XCTAssertEqual(actaReviewArguments("incident.transition_status", ["note": "https://example.invalid/path"])["note"],
                       "https://example.invalid/path")
        _ = await coordinator.executeAgentTool(toolName: "acta__incident__list", arguments: ["query": query], threadID: thread)
        _ = await coordinator.executeAgentTool(toolName: "incident.list", arguments: ["query": query], threadID: thread)
        _ = await coordinator.executeAgentTool(toolName: "acta__incident.list", arguments: ["query": query], threadID: thread)
        _ = await coordinator.executeAgentTool(toolName: "acta__alert__vlm_review", arguments: ["note": query], threadID: thread)
        _ = await coordinator.executeAgentTool(toolName: "acta__incident__update_note", arguments: ["note": query], threadID: thread)
        _ = await coordinator.executeAgentTool(toolName: "acta__incident__transition_status", arguments: ["note": query], threadID: thread)
        _ = await coordinator.executeAgentTool(toolName: otherID, arguments: ["query": query], threadID: thread)
        if let original { await registry.register(original) } else { await registry.unregister(actionID: "incident.list") }
        if let originalAlert { await registry.register(originalAlert) } else { await registry.unregister(actionID: "alert.vlm_review") }
        if let originalNote { await registry.register(originalNote) } else { await registry.unregister(actionID: "incident.update_note") }
        if let originalTransition { await registry.register(originalTransition) } else { await registry.unregister(actionID: "incident.transition_status") }
        if let originalOther { await registry.register(originalOther) } else { await registry.unregister(actionID: otherID) }

        let rows = try store.executeReadOnlyACTASQL("SELECT tool_name, args_json FROM ghost_chat_tool_calls")
        let incidentRows = rows.filter { ["incident.list", "acta__incident__list", "acta__incident.list"].contains($0["tool_name"] ?? "") }
        XCTAssertEqual(incidentRows.count, 6, "Both pre-execution and final audits must be redacted")
        for row in incidentRows {
            let json = try XCTUnwrap(row["args_json"])
            XCTAssertFalse(json.contains(query))
            let args = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
            XCTAssertEqual(args["query"], "[redacted]")
        }
        let alertRows = rows.filter { ["alert.vlm_review", "acta__alert__vlm_review"].contains($0["tool_name"] ?? "") }
        XCTAssertEqual(alertRows.count, 2)
        for row in alertRows {
            let json = try XCTUnwrap(row["args_json"])
            XCTAssertFalse(json.contains(query))
            let args = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
            XCTAssertEqual(args["note"], "[redacted]")
        }
        let noteRows = rows.filter { ["incident.update_note", "acta__incident__update_note",
                                      "incident.transition_status", "acta__incident__transition_status"].contains($0["tool_name"] ?? "") }
        XCTAssertEqual(noteRows.count, 4)
        for row in noteRows {
            let json = try XCTUnwrap(row["args_json"])
            XCTAssertFalse(json.contains(query))
            let args = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
            XCTAssertEqual(args["note"], "[redacted]")
        }
        let otherRows = rows.filter { $0["tool_name"] == otherID }
        XCTAssertEqual(otherRows.count, 1)
        for row in otherRows {
            let json = try XCTUnwrap(row["args_json"])
            XCTAssertEqual(json, "{}")
        }
    }
}
