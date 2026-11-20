import CameraCore
import Foundation
import SQLite3
import XCTest
@testable import CameraWall

private actor ScopedAlertScript {
    private(set) var prompts: [String] = []
    func reply(_ prompt: String) -> String {
        prompts.append(prompt)
        if prompts.count == 1 {
            return #"{"tool_calls":[{"name":"acta__alert__vlm_list","arguments":{"unacknowledged_only":true,"limit":1}}]}"#
        }
        return #"{"answerMarkdown":"Reviewed alerts.","confidence":0.5}"#
    }
}

@MainActor
final class ACTAAlertReadActionsTests: XCTestCase {
    private final class Provider: ACTAAlertReadProvider {
        var snapshot: ACTAAlertReadSnapshot
        var unavailable = false
        var failed = false
        var calls = 0

        init(_ snapshot: ACTAAlertReadSnapshot) { self.snapshot = snapshot }
        func readAlertSnapshot() throws -> ACTAAlertReadSnapshot {
            calls += 1
            if unavailable { throw ACTAAlertReadProviderError.unavailable }
            if failed { throw OpenAlertStateError.unavailable }
            return snapshot
        }
    }

    private func alert(_ camera: UUID, _ time: TimeInterval, priority: OperationsAlertReview.Priority = .normal) -> VLMAlert {
        VLMAlert(createdAt: Date(timeIntervalSince1970: time), cameraID: camera, cameraName: "synthetic camera",
                 condition: "synthetic condition", evidence: "synthetic private evidence", priority: priority)
    }

    private func rows(_ result: ACTAActionResult) throws -> [[String: Any]] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        return try XCTUnwrap(object["alerts"] as? [[String: Any]])
    }

    func testScopedAlertChatReleasesOnlyAuditedMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acta-alert-chat-\(UUID().uuidString)", isDirectory: true)
        let store = try LocalTrackingStore(url: root.appendingPathComponent("tracking.sqlite"))
        defer { try? FileManager.default.removeItem(at: root) }
        let camera = UUID()
        let open = alert(camera, 100, priority: .critical)
        let closed = alert(UUID(), 200)
        let provider = Provider(ACTAAlertReadSnapshot(alerts: [open, closed], reviews: [:],
                                                       acknowledgements: [closed.id: Date()]))
        let action = ACTAScopedAlertListAction(provider: provider)
        let scopes = ACTAAnalyticsCoordinator.localInspectionIDs
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id],
                                                     allowedInspectionIDs: scopes, audit: { _ in })
        let host = try XCTUnwrap(made)
        let issued = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
            threadID: "fixture", actionIDs: [action.id], inspectionIDs: scopes)
        let session = try XCTUnwrap(issued)
        let direct = await host.broker.request(session: session, actionID: action.id,
            argumentsJSON: #"{"unacknowledged_only":true,"limit":1}"#)
        XCTAssertTrue(direct.success)
        let metadata = try rows(direct)
        XCTAssertEqual(metadata.count, 1)
        XCTAssertEqual(Set(metadata[0].keys), ["id", "created_at", "status", "priority"])
        XCTAssertEqual(metadata[0]["id"] as? String, open.id.uuidString)
        XCTAssertEqual(metadata[0]["status"] as? String, "open")
        XCTAssertEqual(metadata[0]["priority"] as? String, "critical")
        let script = ScopedAlertScript()
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .mlxInProcess), transport: { _ in
            XCTFail("Unexpected network request")
            throw URLError(.notConnectedToInternet)
        }, keyProvider: { _ in XCTFail("Unexpected Keychain access"); return nil },
            localAgentInference: { prompt, _ in await script.reply(prompt) })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        _ = await coordinator.askACTAChatAgent(question: "List alerts", threadID: "fixture",
                                              broker: host.broker, brokerSession: session)
        let prompts = await script.prompts
        XCTAssertTrue(prompts.first?.contains("acta__alert__vlm_list") == true)
        XCTAssertTrue(prompts.dropFirst().contains { $0.contains("action_output") && $0.contains(open.id.uuidString) })
        XCTAssertTrue(prompts.allSatisfy {
            !$0.contains("synthetic private") && !$0.contains(camera.uuidString) && !$0.contains(closed.id.uuidString)
        })
        await host.broker.closeSession(session, operatorKey: host.operatorKey)
    }

    func testScopedAlertRejectsInvalidInputAndAuditFailure() async throws {
        let item = alert(UUID(), 100)
        let provider = Provider(ACTAAlertReadSnapshot(alerts: [item], reviews: [:], acknowledgements: [:]))
        let action = ACTAScopedAlertListAction(provider: provider)
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id], audit: { event in
            if event.phase == .result && event.outcome == "success" { throw CocoaError(.fileWriteUnknown) }
        })
        let host = try XCTUnwrap(made)
        let issued = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
                                                   threadID: "fixture", actionIDs: [action.id])
        let session = try XCTUnwrap(issued)
        for arguments in [#"{"limit":0}"#, #"{"limit":51}"#, #"{"camera_id":"secret"}"#,
                          #"{"unacknowledged_only":"yes"}"#] {
            let result = await host.broker.request(session: session, actionID: action.id, argumentsJSON: arguments)
            XCTAssertFalse(result.success)
        }
        XCTAssertEqual(provider.calls, 0)
        let result = await host.broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
        XCTAssertTrue(result.error?.hasPrefix("AUDIT_FAILED:") == true)
        XCTAssertFalse(result.outputJSON.contains(item.id.uuidString))
        provider.unavailable = true
        let unavailable = try await action.execute(parameters: [:], context: ACTAActionContext())
        XCTAssertTrue(unavailable.error?.hasPrefix("UNAVAILABLE:") == true)
        await host.broker.closeSession(session, operatorKey: host.operatorKey)
    }

    func testListFiltersLimitsOrderingAndMinimalFields() async throws {
        let camera = UUID(), other = UUID()
        let open = alert(camera, 100, priority: .critical)
        let reviewed = alert(camera, 200)
        let legacy = alert(camera, 300)
        let resolved = alert(camera, 400)
        let otherCamera = alert(other, 500)
        let reviews = [
            reviewed.id: OperationsAlertReview(alertID: reviewed.id, priority: .critical, status: .open,
                                               note: "synthetic private note", updatedAt: Date()),
            resolved.id: OperationsAlertReview(alertID: resolved.id, priority: .normal, status: .resolved,
                                               note: "synthetic private note", updatedAt: Date())
        ]
        let provider = Provider(ACTAAlertReadSnapshot(alerts: [resolved, legacy, open, otherCamera, reviewed],
            reviews: reviews, acknowledgements: [legacy.id: Date(), reviewed.id: Date()]))
        let registry = ACTAActionRegistry()
        await registry.register(ACTAAlertListAction(provider: provider))
        let result = try await registry.execute(actionID: "alert.vlm_list", parameters: [
            "camera_id": camera.uuidString, "unacknowledged_only": "true", "limit": "1"
        ])
        XCTAssertTrue(result.success, result.summary)
        let limited = try rows(result)
        XCTAssertEqual(limited.count, 1)
        XCTAssertEqual(limited[0]["alert_id"] as? String, reviewed.id.uuidString)
        XCTAssertEqual(Set(limited[0].keys), Set(["alert_id", "camera_id", "created_at", "status", "priority"]))
        XCTAssertEqual(limited[0]["status"] as? String, "open")
        XCTAssertEqual(limited[0]["priority"] as? String, "critical")
        XCTAssertFalse(result.outputJSON.contains("synthetic"))

        let allOpen = try await registry.execute(actionID: "alert.vlm_list", parameters: [
            "camera_id": camera.uuidString, "unacknowledged_only": "1", "limit": "100"
        ])
        XCTAssertEqual(try rows(allOpen).map { $0["alert_id"] as? String }, [reviewed.id.uuidString, open.id.uuidString])
        let all = try await registry.execute(actionID: "alert.vlm_list", parameters: ["camera_id": camera.uuidString])
        let statuses = try rows(all).map { $0["status"] as? String }
        XCTAssertEqual(statuses, ["open", "open", "acknowledged", "resolved"])
        XCTAssertEqual(provider.snapshot.alerts.count, 5)
        XCTAssertEqual(provider.snapshot.reviews, reviews)
    }

    func testInvalidArgumentsAndUnavailableDifferFromEmpty() async throws {
        let provider = Provider(ACTAAlertReadSnapshot(alerts: [], reviews: [:], acknowledgements: [:]))
        let registry = ACTAActionRegistry()
        await registry.register(ACTAAlertListAction(provider: provider))
        for arguments in [
            ["camera_id": ""], ["camera_id": "not-a-uuid"], ["unacknowledged_only": "yes"],
            ["limit": "0"], ["limit": "101"], ["limit": "bad"], ["extra": "value"]
        ] {
            let result = try await registry.execute(actionID: "alert.vlm_list", parameters: arguments)
            XCTAssertFalse(result.success)
            XCTAssertTrue(result.error?.hasPrefix("INVALID_ARGUMENT:") == true)
        }
        XCTAssertEqual(provider.calls, 0)
        let empty = try await registry.execute(actionID: "alert.vlm_list", parameters: [:])
        XCTAssertTrue(empty.success)
        XCTAssertTrue(try rows(empty).isEmpty)
        provider.unavailable = true
        let unavailable = try await registry.execute(actionID: "alert.vlm_list", parameters: [:])
        XCTAssertFalse(unavailable.success)
        XCTAssertTrue(unavailable.error?.hasPrefix("UNAVAILABLE:") == true)
        XCTAssertFalse(unavailable.verified)
        provider.unavailable = false
        provider.failed = true
        let failed = try await registry.execute(actionID: "alert.vlm_list", parameters: [:])
        XCTAssertFalse(failed.success)
        XCTAssertTrue(failed.error?.hasPrefix("SOURCE_ERROR:") == true)
        let direct = ACTAAlertListAction(provider: provider)
        do {
            _ = try await direct.execute(parameters: ["limit": "-1"], context: ACTAActionContext())
            XCTFail("Direct execution must validate input")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("INVALID_ARGUMENT:"))
        }
    }

    func testDefaultAndBoundaryLimits() async throws {
        let camera = UUID()
        let alerts = (0..<105).map { alert(camera, Double($0)) }
        let provider = Provider(ACTAAlertReadSnapshot(alerts: alerts, reviews: [:], acknowledgements: [:]))
        let registry = ACTAActionRegistry()
        await registry.register(ACTAAlertListAction(provider: provider))
        for (parameters, expected) in [([String: String](), 50), (["limit": "1"], 1), (["limit": "100"], 100)] {
            let result = try await registry.execute(actionID: "alert.vlm_list", parameters: parameters)
            XCTAssertTrue(result.success)
            XCTAssertEqual(try rows(result).count, expected)
        }
        let absent = try await registry.execute(actionID: "alert.vlm_list", parameters: ["camera_id": UUID().uuidString])
        XCTAssertTrue(absent.success)
        XCTAssertTrue(try rows(absent).isEmpty)
    }

    func testCoordinatorRequiresCachedPreferencesAndOpenStoreWithoutCreatingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let coordinator = CameraFeatureCoordinator(preferencesURL: root.appendingPathComponent("prefs.json"),
                                                   databaseURL: root.appendingPathComponent("db.sqlite"))
        XCTAssertThrowsError(try coordinator.readOpenAlertState()) { error in
            guard case OpenAlertStateError.unavailable = error else { return XCTFail("Expected unavailable") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        _ = try coordinator.preferences()
        XCTAssertThrowsError(try coordinator.readOpenAlertState()) { error in
            guard case OpenAlertStateError.featureDisabled = error else { return XCTFail("Expected disabled") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testStoreSnapshotRetentionLegacyAndNoPurge() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("db.sqlite")
        let store = try CameraFeatureStore(url: url)
        let preferences = CameraFeaturePreferences(enabledFeatures: [.operationalAlerts], retentionDays: 1)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let fresh = UUID(), expired = UUID(), boundary = UUID(), legacy = UUID()
        _ = try store.reviewOperationsAlert(alertID: fresh, status: .acknowledged, preferences: preferences, at: now)
        _ = try store.reviewOperationsAlert(alertID: boundary, status: .acknowledged, preferences: preferences,
                                            at: now.addingTimeInterval(-86_400))
        _ = try store.reviewOperationsAlert(alertID: expired, status: .acknowledged, preferences: preferences,
                                            at: now.addingTimeInterval(-86_401))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = "INSERT INTO operations_alert_acknowledgements (alert_id, acknowledged_at) VALUES ('\(legacy.uuidString)', 1)"
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)

        let snapshot = try store.readAlertState(retentionDays: 1, at: now)
        XCTAssertEqual(Set(snapshot.reviews.keys), Set([fresh, boundary]))
        XCTAssertEqual(Set(snapshot.acknowledgements.keys), Set([fresh, boundary, legacy]))
        let currentGUIState = try store.readAlertState(retentionDays: 1, at: now, includeExpired: true)
        XCTAssertEqual(Set(currentGUIState.reviews.keys), Set([fresh, boundary, expired]))
        XCTAssertEqual(Set(currentGUIState.acknowledgements.keys), Set([fresh, boundary, expired, legacy]))
        XCTAssertEqual(try store.operationsAlertReviews().count, 3)
        XCTAssertEqual(try store.operationsAlertAcknowledgements().count, 4)
        XCTAssertThrowsError(try store.readAlertState(retentionDays: 0, at: now))

        let coordinator = CameraFeatureCoordinator(preferencesURL: root.appendingPathComponent("prefs.json"), databaseURL: url)
        try coordinator.savePreferences(preferences)
        XCTAssertThrowsError(try coordinator.readOpenAlertState(at: now))
        _ = try coordinator.operationsAlertAcknowledgements() // Explicitly opens the synthetic fixture store.
        let coordinated = try coordinator.readOpenAlertState(at: now)
        XCTAssertEqual(coordinated.reviews, snapshot.reviews)
        XCTAssertEqual(coordinated.acknowledgements, snapshot.acknowledgements)
    }

    func testCorruptReviewIsNotAnEmptySnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("db.sqlite")
        let store = try CameraFeatureStore(url: url)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = "INSERT INTO operations_alert_reviews (alert_id, document_json) VALUES ('\(UUID().uuidString)', 'invalid')"
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try store.readAlertState(retentionDays: 30))
    }
}
