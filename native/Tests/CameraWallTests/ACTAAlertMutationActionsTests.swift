import CameraCore
import Foundation
import SQLite3
import XCTest
@testable import CameraWall

@MainActor
final class ACTAAlertMutationActionsTests: XCTestCase {
    private enum Failure: Error { case synthetic }

    private final class Provider: ACTAAlertMutationProvider {
        let alert: VLMAlert
        var gui: ACTAAlertReadSnapshot
        var disk: ACTAAlertReadSnapshot
        var history: [OperationsAlertReview] = []
        var writes = 0
        var reads = 0
        var failWrite = false
        var failAfterWrite = false
        var noOp = false
        var omitAudit = false
        var divergeAfterWrite = false
        var failOnRead: Int?

        init() {
            alert = VLMAlert(createdAt: Date(timeIntervalSince1970: 100), cameraID: UUID(),
                             cameraName: "synthetic", condition: "synthetic", evidence: "synthetic",
                             priority: .critical)
            gui = ACTAAlertReadSnapshot(alerts: [alert], reviews: [:], acknowledgements: [:])
            disk = gui
        }

        func readAlertSnapshot() throws -> ACTAAlertReadSnapshot {
            reads += 1
            if reads == failOnRead { throw Failure.synthetic }
            guard gui.alerts == disk.alerts, gui.reviews == disk.reviews,
                  gui.acknowledgements == disk.acknowledgements else {
                throw ACTAAlertReadProviderError.unavailable
            }
            return gui
        }

        func reviewHistory(id: UUID) throws -> [OperationsAlertReview] { history.filter { $0.alertID == id } }

        func reviewAlert(id: UUID, priority: OperationsAlertReview.Priority?,
                         status: OperationsAlertReview.Status, note: String?) throws {
            writes += 1
            if failWrite { throw Failure.synthetic }
            if noOp { return }
            let previous = disk.reviews[id]
            let review = OperationsAlertReview(alertID: id, priority: priority ?? previous?.priority ?? alert.priority,
                status: status, note: (note ?? previous?.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                updatedAt: Date(timeIntervalSince1970: Double(1000 + writes)))
            var reviews = disk.reviews
            var acknowledgements = disk.acknowledgements
            reviews[id] = review
            acknowledgements[id] = status == .open ? nil : review.updatedAt
            disk = ACTAAlertReadSnapshot(alerts: disk.alerts, reviews: reviews, acknowledgements: acknowledgements)
            if !divergeAfterWrite { gui = disk }
            if !omitAudit { history.append(review) }
            if failAfterWrite { throw Failure.synthetic }
        }
    }

    private func registry(_ provider: Provider) async -> ACTAActionRegistry {
        let registry = ACTAActionRegistry()
        await registry.register(ACTAAlertMutationAction(kind: .acknowledge, provider: provider))
        await registry.register(ACTAAlertMutationAction(kind: .review, provider: provider))
        return registry
    }

    private func review(_ registry: ACTAActionRegistry, _ parameters: [String: String]) async throws -> ACTAActionResult {
        let pending = try await registry.execute(actionID: "alert.vlm_review", parameters: parameters)
        XCTAssertTrue(pending.requiresOperatorConfirmation)
        return try await registry.confirmAndExecute(token: XCTUnwrap(pending.confirmationToken), confirmed: true)
    }

    func testReviewAndAcknowledgementPreserveFieldsAndSynchronize() async throws {
        let provider = Provider()
        let registry = await registry(provider)
        let id = provider.alert.id.uuidString
        let reviewed = try await review(registry, [
            "alert_id": id, "status": "resolved", "priority": "normal", "note": "  synthetic note  "
        ])
        XCTAssertTrue(reviewed.success, reviewed.summary)
        XCTAssertTrue(reviewed.verified)
        XCTAssertFalse(reviewed.outputJSON.contains("synthetic"))
        XCTAssertEqual(provider.gui.reviews, provider.disk.reviews)
        XCTAssertEqual(provider.gui.acknowledgements, provider.disk.acknowledgements)
        XCTAssertEqual(provider.gui.reviews[provider.alert.id]?.note, "synthetic note")
        let blocked = try await registry.execute(actionID: "alert.vlm_acknowledge", parameters: ["alert_id": id, "acknowledged": "false"])
        XCTAssertFalse(blocked.success)
        XCTAssertEqual(provider.writes, 1)
        let reopened = try await review(registry, ["alert_id": id, "status": "open"])
        XCTAssertTrue(reopened.success, reopened.summary)
        XCTAssertNil(provider.disk.acknowledgements[provider.alert.id])
        let acknowledged = try await registry.execute(actionID: "alert.vlm_acknowledge", parameters: ["alert_id": id, "acknowledged": "1"])
        XCTAssertTrue(acknowledged.success, acknowledged.summary)
        XCTAssertEqual(provider.disk.reviews[provider.alert.id]?.priority, .normal)
        XCTAssertEqual(provider.disk.reviews[provider.alert.id]?.note, "synthetic note")
        XCTAssertNotNil(provider.disk.acknowledgements[provider.alert.id])
        let resolvedAgain = try await review(registry, ["alert_id": id, "status": "resolved"])
        XCTAssertTrue(resolvedAgain.success, resolvedAgain.summary)
        let reopenedAgain = try await review(registry, ["alert_id": id, "status": "open"])
        XCTAssertTrue(reopenedAgain.success, reopenedAgain.summary)
        let undone = try await registry.execute(actionID: "alert.vlm_acknowledge", parameters: ["alert_id": id, "acknowledged": "false"])
        XCTAssertTrue(undone.success, undone.summary)
        XCTAssertEqual(provider.disk.reviews[provider.alert.id]?.status, .open)
        XCTAssertNil(provider.disk.acknowledgements[provider.alert.id])
        XCTAssertEqual(provider.history.count, 6)
    }

    func testInvalidAndMissingAlertsNeverWrite() async throws {
        let provider = Provider()
        let registry = await registry(provider)
        let id = provider.alert.id.uuidString
        let cases: [(String, [String: String])] = [
            ("alert.vlm_acknowledge", ["alert_id": "bad", "acknowledged": "true"]),
            ("alert.vlm_acknowledge", ["alert_id": id, "acknowledged": "yes"]),
            ("alert.vlm_acknowledge", ["alert_id": id, "acknowledged": "true", "extra": "x"]),
            ("alert.vlm_review", ["alert_id": id, "status": "resolved", "note": "  "]),
            ("alert.vlm_review", ["alert_id": id, "status": "open", "note": String(repeating: "a", count: 2001)]),
            ("alert.vlm_review", ["alert_id": id, "status": "open", "priority": "bad"]),
            ("alert.vlm_review", ["alert_id": UUID().uuidString, "status": "open"])
        ]
        for (action, parameters) in cases {
            let result = try await registry.execute(actionID: action, parameters: parameters)
            XCTAssertFalse(result.success, "\(action) \(parameters)")
            XCTAssertFalse(result.verified)
        }
        XCTAssertEqual(provider.writes, 0)
        let pending = try await registry.execute(actionID: "alert.vlm_review", parameters: [
            "alert_id": id, "status": "open", "note": "operator decision"
        ])
        XCTAssertTrue(pending.requiresOperatorConfirmation)
        _ = try await registry.confirmAndExecute(token: XCTUnwrap(pending.confirmationToken), confirmed: false)
        XCTAssertEqual(provider.writes, 0)
        let emptyResolution = try await review(registry, ["alert_id": id, "status": "resolved"])
        XCTAssertFalse(emptyResolution.success)
        let missing = try await review(registry, ["alert_id": UUID().uuidString, "status": "open"])
        XCTAssertFalse(missing.success)
        XCTAssertEqual(provider.writes, 0)
        let direct = ACTAAlertMutationAction(kind: .review, provider: provider)
        do {
            _ = try await direct.execute(parameters: ["alert_id": id, "status": "bad"], context: ACTAActionContext())
            XCTFail("Direct execution must reject invalid input")
        } catch { XCTAssertTrue(error.localizedDescription.hasPrefix("INVALID_ARGUMENT:")) }
    }

    func testFailuresAndUnverifiedWritesNeverReportSuccess() async throws {
        for failure in 0..<7 {
            let provider = Provider()
            let registry = await registry(provider)
            switch failure {
            case 0: provider.failWrite = true
            case 1: provider.failAfterWrite = true
            case 2: provider.noOp = true
            case 3: provider.omitAudit = true
            case 4: provider.divergeAfterWrite = true
            case 5: provider.failOnRead = 2
            default: provider.failOnRead = 3
            }
            let result = try await registry.execute(actionID: "alert.vlm_acknowledge", parameters: [
                "alert_id": provider.alert.id.uuidString, "acknowledged": "true"
            ])
            XCTAssertFalse(result.success, "Failure case \(failure)")
            XCTAssertFalse(result.verified, "Failure case \(failure)")
        }
    }

    func testPreexistingDivergenceAndAmbiguousIDNeverWrite() async throws {
        let provider = Provider()
        let registry = await registry(provider)
        provider.disk = ACTAAlertReadSnapshot(alerts: [], reviews: [:], acknowledgements: [:])
        let args = ["alert_id": provider.alert.id.uuidString, "acknowledged": "true"]
        let divergent = try await registry.execute(actionID: "alert.vlm_acknowledge", parameters: args)
        XCTAssertFalse(divergent.success)
        XCTAssertEqual(provider.writes, 0)
        provider.gui = ACTAAlertReadSnapshot(alerts: [provider.alert, provider.alert], reviews: [:], acknowledgements: [:])
        provider.disk = provider.gui
        let ambiguous = try await registry.execute(actionID: "alert.vlm_acknowledge", parameters: args)
        XCTAssertFalse(ambiguous.success)
        XCTAssertEqual(provider.writes, 0)
    }

    func testAlreadyMatchingStateDoesNotHideNoOpWrite() async throws {
        let provider = Provider()
        let registry = await registry(provider)
        let args = ["alert_id": provider.alert.id.uuidString, "acknowledged": "true"]
        let first = try await registry.execute(actionID: "alert.vlm_acknowledge", parameters: args)
        XCTAssertTrue(first.success, first.summary)
        provider.noOp = true
        let second = try await registry.execute(actionID: "alert.vlm_acknowledge", parameters: args)
        XCTAssertFalse(second.success)
        XCTAssertFalse(second.verified)
        XCTAssertEqual(provider.history.count, 1)
    }

    func testWallProviderUsesIsolatedGUIAndPersistentStores() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let root = IsolatedWallFixtureSupport.root()
        try IsolatedWallFixtureSupport.prepare(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferencesURL = root.appendingPathComponent("features.json")
        let databaseURL = root.appendingPathComponent("features.sqlite")
        try CameraFeaturePreferencesStore.save(CameraFeaturePreferences(enabledFeatures: [.operationalAlerts]), to: preferencesURL)
        let alert = VLMAlert(cameraID: UUID(), cameraName: "Synthetic camera",
                             condition: "Synthetic condition", evidence: "Synthetic evidence", priority: .critical)
        try VLMStore.save([alert], to: root.appendingPathComponent("vlm-alerts.json"))
        let client = IsolatedWallFixtureSupport.client()
        let language = LanguageSettings(storage: InMemoryLanguageStorage())
        let model = WallModel(configURL: root.appendingPathComponent("cameras.json"),
            poseModelURL: root.appendingPathComponent("fake-pose.mlmodel"),
            trackingStoreURL: root.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: preferencesURL, databaseURL: databaseURL),
            analyticsDirectoryURL: root.appendingPathComponent("analytics"), agentClient: client,
            cameraMemoryStore: CameraMemoryStore(url: root.appendingPathComponent("frames")),
            operationsWatchURL: root.appendingPathComponent("watches.json"),
            missionStoreURL: root.appendingPathComponent("missions.json"),
            cameraCredentialStore: AlertTestCredentials(),
            operationsPreferencesURL: root.appendingPathComponent("operations.json"),
            alertClipStore: CriticalAlertClipStore(url: root.appendingPathComponent("clips")),
            languageSettings: language,
            monitorHistoryURL: root.appendingPathComponent("monitor.json"),
            analyticsModelDiscovery: IsolatedWallFixtureSupport.modelDiscovery)
        defer { model.shutdown() }
        IsolatedWallFixtureSupport.assertSafe(model)
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model, languageSettings: language)
        let advertised = try await ACTAAnalyticsCoordinator.registryTools(registry: registry)
        let systemTool = try XCTUnwrap(advertised.first { $0.name == "acta__settings__update_system" })
        let systemSchema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(systemTool.parametersSchemaJSON.utf8)) as? [String: Any])
        let properties = try XCTUnwrap(systemSchema["properties"] as? [String: Any])
        XCTAssertNotNil(properties["language"])
        let languageResult = try await registry.execute(actionID: "settings.update_system", parameters: ["language": "ru"])
        XCTAssertTrue(languageResult.success, languageResult.summary)
        XCTAssertEqual(language.language, .russian)
        XCTAssertTrue(advertised.contains { $0.name == "acta__alert__vlm_acknowledge" })
        XCTAssertTrue(advertised.contains { $0.name == "acta__alert__vlm_review" })
        XCTAssertTrue(advertised.contains { $0.name == "acta__reid__calibrate" })
        let calibration = try await registry.execute(actionID: "reid.calibrate", parameters: ["target_precision": "0.995"])
        XCTAssertTrue(calibration.success, calibration.summary)
        let aggregate = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(calibration.outputJSON.utf8)) as? [String: Any])
        XCTAssertEqual(aggregate["positive_pairs"] as? Int, 0)
        XCTAssertEqual(aggregate["negative_pairs"] as? Int, 0)
        XCTAssertEqual(aggregate["ready"] as? Bool, false)
        let reviewed = try await review(registry, [
            "alert_id": alert.id.uuidString, "status": "resolved", "priority": "normal", "note": "synthetic note"
        ])
        XCTAssertTrue(reviewed.success, reviewed.summary)
        let reopened = try await review(registry, [
            "alert_id": alert.id.uuidString, "status": "open"
        ])
        XCTAssertTrue(reopened.success, reopened.summary)
        let acknowledged = try await registry.execute(actionID: "alert.vlm_acknowledge", parameters: [
            "alert_id": alert.id.uuidString, "acknowledged": "true"
        ])
        XCTAssertTrue(acknowledged.success, acknowledged.summary)
        let disk = CameraFeatureCoordinator(preferencesURL: preferencesURL, databaseURL: databaseURL)
        _ = try disk.preferences()
        _ = try disk.operationsAlertAcknowledgements()
        let persisted = try disk.readOpenAlertState(includeExpired: true)
        XCTAssertEqual(persisted.reviews, model.operationsAlertReviews)
        XCTAssertEqual(persisted.acknowledgements, model.operationsAlertAcknowledgements)
        XCTAssertEqual(persisted.reviews[alert.id]?.note, "synthetic note")
        XCTAssertEqual(try disk.operationsAlertReviewAudit(alertID: alert.id).count, 3)
        XCTAssertEqual(try VLMStore.loadAlerts(from: root.appendingPathComponent("vlm-alerts.json")), [alert])

        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &connection, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let database = try XCTUnwrap(connection)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        let failed = try await registry.execute(actionID: "alert.vlm_acknowledge", parameters: [
            "alert_id": alert.id.uuidString, "acknowledged": "false"
        ])
        XCTAssertFalse(failed.success)
        XCTAssertFalse(failed.verified)
        XCTAssertEqual(sqlite3_exec(database, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try disk.readOpenAlertState(includeExpired: true).reviews, persisted.reviews)
    }
}

private struct AlertTestCredentials: CameraCredentialStore {
    func read(_ id: UUID) throws -> Credentials? { XCTFail("Unexpected credential read"); return nil }
    func save(_ credentials: Credentials, for id: UUID) throws { XCTFail("Unexpected credential save") }
    func remove(_ id: UUID) throws { XCTFail("Unexpected credential removal") }
}
