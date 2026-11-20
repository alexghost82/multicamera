import CameraCore
import Foundation
import XCTest
@testable import CameraWall

private actor WatchModelScript {
    private(set) var prompts: [String] = []
    func reply(_ prompt: String) -> String {
        prompts.append(prompt)
        if prompts.count == 1 {
            return #"{"tool_calls":[{"name":"acta__watch__list","arguments":{}}]}"#
        }
        return #"{"answerMarkdown":"Reviewed watch rules.","confidence":0.5}"#
    }
}

final class ACTAOperationsWatchReadProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func provider(
        enabled: Bool = true,
        gui: ACTAOperationsWatchReadProvider.RuleState,
        store: ACTAOperationsWatchReadProvider.RuleState,
        at: Date = Date(timeIntervalSince1970: 2_000_000_000)
    ) -> ACTAOperationsWatchReadProvider {
        ACTAOperationsWatchReadProvider {
            .init(enabled: enabled, gui: gui, store: store, checkedAt: at)
        }
    }

    private func execute(_ provider: ACTAOperationsWatchReadProvider) async throws -> ACTAActionResult {
        try await ACTAScopedWatchListAction(provider: provider)
            .execute(parameters: [:], context: ACTAActionContext())
    }

    func testRealRulesProjectOnlyActiveTypedMetadata() async throws {
        let all = try OperationsWatchRule(text: "synthetic red coat", createdAt: now, ttlSeconds: nil)
        let selected = try OperationsWatchRule(text: "synthetic blue coat", cameraIDs: [UUID()],
                                               createdAt: now, ttlSeconds: 120)
        let expired = try OperationsWatchRule(text: "synthetic green coat", createdAt: now.addingTimeInterval(-120),
                                              ttlSeconds: 120)
        let result = try await execute(provider(gui: .loaded([all, selected, expired]),
                                                store: .loaded([expired, selected, all])))
        XCTAssertTrue(result.success)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["watch_rules"])
        let rules = try XCTUnwrap(object["watch_rules"] as? [[String: String]])
        XCTAssertEqual(rules, [
            ["cameraScope": "all", "expiration": "indefinite"],
            ["cameraScope": "selected", "expiration": "timed"]
        ])
        XCTAssertFalse(result.outputJSON.contains("synthetic"))
        XCTAssertFalse(result.outputJSON.contains(selected.id.uuidString))
    }

    func testEmptyOnlyWhenBothSourcesSuccessfullyAgree() async throws {
        let result = try await execute(provider(gui: .loaded([]), store: .loaded([])))
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.outputJSON, #"{"watch_rules":[]}"#)
    }

    func testUnavailableFailuresAndInconsistentSnapshotsFailClosed() async throws {
        let rule = try OperationsWatchRule(text: "synthetic coat", createdAt: now)
        var changed = rule
        changed.markFired(trackID: UUID())
        let cases: [(ACTAOperationsWatchReadProvider, String)] = [
            (.init(), "UNAVAILABLE:"),
            (provider(enabled: false, gui: .loaded([]), store: .loaded([])), "UNAVAILABLE:"),
            (provider(gui: .unavailable, store: .loaded([])), "UNAVAILABLE:"),
            (provider(gui: .loaded([]), store: .unavailable), "UNAVAILABLE:"),
            (provider(gui: .failed, store: .loaded([])), "STORAGE_ERROR:"),
            (provider(gui: .loaded([]), store: .failed), "STORAGE_ERROR:"),
            (provider(gui: .loaded([]), store: .loaded([rule])), "STORAGE_ERROR:"),
            (provider(gui: .loaded([rule]), store: .loaded([changed])), "STORAGE_ERROR:"),
            (provider(gui: .loaded([rule, rule]), store: .loaded([rule, rule])), "STORAGE_ERROR:"),
            (provider(gui: .loaded([]), store: .loaded([]),
                      at: Date(timeIntervalSince1970: .nan)), "STORAGE_ERROR:"),
            (.init { throw NSError(domain: "synthetic-secret", code: 1) }, "STORAGE_ERROR:")
        ]
        for (provider, expected) in cases {
            let result = try await execute(provider)
            XCTAssertFalse(result.success)
            XCTAssertTrue(result.error?.hasPrefix(expected) == true)
            XCTAssertFalse(result.outputJSON.contains("watch_rules"))
            XCTAssertFalse(result.outputJSON.contains("synthetic-secret"))
        }
    }

    func testTooManyOrInvalidMutableRulesFailClosed() async throws {
        var invalid = try OperationsWatchRule(text: "synthetic coat", createdAt: now)
        invalid.firedTrackIDs = Array(repeating: UUID(), count: 2)
        let many = try (0...OperationsWatchRule.maximumRules).map { _ in
            try OperationsWatchRule(text: "synthetic coat", createdAt: now)
        }
        for rules in [[invalid], many] {
            let result = try await execute(provider(gui: .loaded(rules), store: .loaded(rules)))
            XCTAssertFalse(result.success)
            XCTAssertTrue(result.error?.hasPrefix("STORAGE_ERROR:") == true)
        }
    }

    @MainActor
    func testLiveWatchChatLoopUsesMatchingGUIAndStoreAndFailsClosedOnDivergence() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let root = IsolatedWallFixtureSupport.root()
        try IsolatedWallFixtureSupport.prepare(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefs = root.appendingPathComponent("features.json")
        try CameraFeaturePreferencesStore.save(CameraFeaturePreferences(enabledFeatures: [.operationalAlerts]), to: prefs)
        let rule = try OperationsWatchRule(text: "synthetic-secret-condition", cameraIDs: [UUID()], ttlSeconds: 120)
        let watchURL = root.appendingPathComponent("watches.json")
        try OperationsWatchStore.save([rule], to: watchURL)
        let model = WallModel(configURL: root.appendingPathComponent("cameras.json"),
            poseModelURL: root.appendingPathComponent("fake-pose.mlmodel"),
            trackingStoreURL: root.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: prefs, databaseURL: root.appendingPathComponent("features.sqlite")),
            analyticsDirectoryURL: root.appendingPathComponent("analytics"),
            agentClient: IsolatedWallFixtureSupport.client(),
            cameraMemoryStore: CameraMemoryStore(url: root.appendingPathComponent("frames")),
            operationsWatchURL: watchURL, missionStoreURL: root.appendingPathComponent("missions.json"),
            cameraCredentialStore: ACTAIsolatedCredentials(),
            operationsPreferencesURL: root.appendingPathComponent("operations.json"),
            alertClipStore: CriticalAlertClipStore(url: root.appendingPathComponent("clips")),
            languageSettings: LanguageSettings(storage: InMemoryLanguageStorage()),
            monitorHistoryURL: root.appendingPathComponent("monitor.json"),
            analyticsModelDiscovery: IsolatedWallFixtureSupport.modelDiscovery)
        defer { model.shutdown() }
        let action = ACTAScopedWatchListAction(provider: ACTAOperationsWatchReadProvider(model: model))
        let scopes = ACTAAnalyticsCoordinator.localInspectionIDs
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id],
                                                     allowedInspectionIDs: scopes, audit: { _ in })
        let host = try XCTUnwrap(made)
        let issued = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
            threadID: "fixture", actionIDs: [action.id], inspectionIDs: scopes)
        let session = try XCTUnwrap(issued)
        let script = WatchModelScript()
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .mlxInProcess), transport: { _ in
            XCTFail("Unexpected network request")
            throw URLError(.notConnectedToInternet)
        }, keyProvider: { _ in XCTFail("Unexpected Keychain access"); return nil },
            localAgentInference: { prompt, _ in await script.reply(prompt) })
        let store = try LocalTrackingStore(url: root.appendingPathComponent("chat.sqlite"))
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        _ = await coordinator.askACTAChatAgent(question: "List watch rules", threadID: "fixture",
                                              broker: host.broker, brokerSession: session)
        let prompts = await script.prompts
        XCTAssertTrue(prompts.first?.contains("acta__watch__list") == true)
        XCTAssertTrue(prompts.dropFirst().contains { $0.contains("action_output") && $0.contains("selected") })
        XCTAssertTrue(prompts.allSatisfy { !$0.contains("synthetic-secret") && !$0.contains(rule.id.uuidString) })
        model.operationsWatchRules = []
        let denied = await host.broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
        XCTAssertFalse(denied.success)
        XCTAssertFalse(denied.outputJSON.contains("watch_rules"))
        model.featurePreferences.enabledFeatures.remove(.operationalAlerts)
        let disabled = try await action.execute(parameters: [:], context: ACTAActionContext())
        XCTAssertFalse(disabled.success)
        XCTAssertTrue(disabled.error?.hasPrefix("UNAVAILABLE:") == true)
        await host.broker.closeSession(session, operatorKey: host.operatorKey)
    }
}
