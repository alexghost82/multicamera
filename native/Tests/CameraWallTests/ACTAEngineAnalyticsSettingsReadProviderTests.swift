import CameraCore
import Foundation
import XCTest
@testable import CameraWall

private actor AnalyticsSettingsScript {
    private(set) var prompts: [String] = []
    func reply(_ prompt: String) -> String {
        prompts.append(prompt)
        if prompts.count == 1 {
            return #"{"tool_calls":[{"name":"acta__analytics__get_settings","arguments":{}}]}"#
        }
        return #"{"answerMarkdown":"Reviewed analytics settings.","confidence":0.5}"#
    }
}

@MainActor
final class ACTAEngineAnalyticsSettingsReadProviderTests: XCTestCase {
    private func fixture() throws -> (URL, WallModel) {
        let root = IsolatedWallFixtureSupport.root()
        try IsolatedWallFixtureSupport.prepare(root)
        try CameraFeaturePreferencesStore.save(CameraFeaturePreferences(enabledFeatures: []),
                                               to: root.appendingPathComponent("features.json"))
        let model = WallModel(
            configURL: root.appendingPathComponent("cameras.json"),
            poseModelURL: root.appendingPathComponent("unused-pose.mlmodel"),
            trackingStoreURL: root.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: root.appendingPathComponent("features.json"),
                                                         databaseURL: root.appendingPathComponent("features.sqlite")),
            analyticsDirectoryURL: root.appendingPathComponent("analytics"),
            agentClient: IsolatedWallFixtureSupport.client(),
            cameraMemoryStore: CameraMemoryStore(url: root.appendingPathComponent("frames")),
            operationsWatchURL: root.appendingPathComponent("watches.json"),
            missionStoreURL: root.appendingPathComponent("missions.json"),
            cameraCredentialStore: ACTAIsolatedCredentials(),
            operationsPreferencesURL: root.appendingPathComponent("operations.json"),
            alertClipStore: CriticalAlertClipStore(url: root.appendingPathComponent("clips")),
            languageSettings: LanguageSettings(storage: InMemoryLanguageStorage()),
            monitorHistoryURL: root.appendingPathComponent("monitor.json"),
            analyticsModelDiscovery: IsolatedWallFixtureSupport.modelDiscovery)
        IsolatedWallFixtureSupport.assertSafe(model)
        return (root, model)
    }

    func testReviewedAnalyticsActionsUseEngineAndRejectCrossInstanceABA() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let engine = model.localAnalyticsEngine
        let domain = ACTAEngineAnalyticsMutationDomain(engine: engine)
        let actions = ACTAPreparedAnalyticsSettingsAction.Kind.productionCases.map {
            ACTAPreparedAnalyticsSettingsAction(kind: $0, domain: domain)
        }
        let ids = WallModel.modelFacingActionIDs(actions)
        let made = await ACTALocalActionBroker.make(actions: actions, allowedActionIDs: ids, audit: { _ in })
        let host = try XCTUnwrap(made)
        let issued = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
                                                   threadID: "fixture", actionIDs: ids)
        let session = try XCTUnwrap(issued)
        let coordinator = ACTAAnalyticsCoordinator(aiClient: IsolatedWallFixtureSupport.client())
        let calls: [(String, String)] = [
            ("acta__analytics__set_global_toggle", #"{"feature":"sound","enabled":true}"#),
            ("acta__analytics__set_threshold", #"{"parameter":"personConfidenceThreshold","value":0.6}"#),
            ("acta__analytics__set_sampling_fps", #"{"fps":5,"idle_fps":2,"boost_fps":10}"#),
            ("acta__analytics__set_overlay", #"{"layer":"showTrackID","enabled":false}"#),
            ("acta__analytics__set_sensitivity_profile", #"{"profile":"Conservative","apply_values":false}"#),
            ("acta__analytics__set_execution_mode", #"{"mode":"DISTRIBUTED"}"#),
            ("acta__analytics__set_execution_mode", #"{"mode":"LOCAL"}"#)
        ]
        for (name, arguments) in calls {
            let call = ACTAAgentFunctionCall(callID: name, name: name, argumentsJSON: arguments)
            let pending = await coordinator.executeModelGeneratedAgentTool(call, threadID: "fixture",
                requestToolNames: [name], broker: host.broker, brokerSession: session)
            XCTAssertTrue(pending.outputJSON.contains("requires_operator_confirmation"), name)
            let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
            let review = try XCTUnwrap(reviews.first)
            let result = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                    reviewed: review, approved: true)
            XCTAssertTrue(result.success && result.verified, "\(name): \(result.error ?? "")")
            XCTAssertEqual(try VideoAnalyticsSettingsStore.load(from: engine.settingsURL), engine.settings)
        }
        let name = "acta__analytics__set_overlay"
        let call = ACTAAgentFunctionCall(callID: "stale", name: name,
                                         argumentsJSON: #"{"layer":"showTrackID","enabled":true}"#)
        _ = await coordinator.executeModelGeneratedAgentTool(call, threadID: "fixture",
            requestToolNames: [name], broker: host.broker, brokerSession: session)
        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let review = try XCTUnwrap(reviews.first)
        let before = engine.settings
        var changed = before
        changed.enableSoundAlert.toggle()
        try VideoAnalyticsSettingsStore.save(changed, to: engine.settingsURL)
        try VideoAnalyticsSettingsStore.save(before, to: engine.settingsURL)
        let stale = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                               reviewed: review, approved: true)
        XCTAssertFalse(stale.success)
        XCTAssertEqual(engine.settings, before)
        await host.broker.closeSession(session, operatorKey: host.operatorKey)
    }

    func testAuditedChatUsesAppliedSettingsAndExcludesCameraData() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let action = ACTAScopedAnalyticsSettingsAction(provider: ACTAEngineAnalyticsSettingsReadProvider(model: model))
        let modeAction = ACTAPreparedAnalyticsSettingsAction(
            kind: .executionMode, domain: ACTAEngineAnalyticsMutationDomain(engine: model.localAnalyticsEngine))
        let scopes = ACTAAnalyticsCoordinator.localInspectionIDs
        let made = await ACTALocalActionBroker.make(actions: [action, modeAction], allowedActionIDs: [action.id, modeAction.id],
                                                     allowedInspectionIDs: scopes, audit: { _ in })
        let host = try XCTUnwrap(made)
        let issued = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
            threadID: "fixture", actionIDs: [action.id, modeAction.id], inspectionIDs: scopes)
        let session = try XCTUnwrap(issued)
        let script = AnalyticsSettingsScript()
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .mlxInProcess), transport: { _ in
            XCTFail("Unexpected network request")
            throw URLError(.notConnectedToInternet)
        }, keyProvider: { _ in XCTFail("Unexpected Keychain access"); return nil },
            localAgentInference: { prompt, _ in await script.reply(prompt) })
        let store = try LocalTrackingStore(url: root.appendingPathComponent("chat.sqlite"))
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        _ = await coordinator.askACTAChatAgent(question: "Show analytics settings", threadID: "fixture",
                                              broker: host.broker, brokerSession: session)
        let prompts = await script.prompts
        XCTAssertTrue(prompts.first?.contains("acta__analytics__get_settings") == true)
        XCTAssertTrue(prompts.first?.contains("acta__analytics__set_execution_mode") == true)
        XCTAssertTrue(prompts.first?.contains("does not switch routing") == true)
        XCTAssertTrue(prompts.dropFirst().contains {
            $0.contains("action_output") && $0.contains("globalEnabled") &&
                $0.contains("analyticsSamplingFPS") && $0.contains("showBoundingBoxes")
        })
        XCTAssertTrue(prompts.allSatisfy { !$0.contains("cameraOverrides") })
        await host.broker.closeSession(session, operatorKey: host.operatorKey)
    }

    func testCorruptOrChangedSettingsAreNotReportedAsApplied() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let action = ACTAScopedAnalyticsSettingsAction(provider: ACTAEngineAnalyticsSettingsReadProvider(model: model))
        let url = model.localAnalyticsEngine.settingsURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid synthetic settings".utf8).write(to: url)
        let corrupt = try await action.execute(parameters: [:], context: ACTAActionContext())
        XCTAssertFalse(corrupt.success)
        XCTAssertTrue(corrupt.error?.hasPrefix("READ_ERROR:") == true)
        var changed = model.localAnalyticsEngine.settings
        changed.globalEnabled.toggle()
        try VideoAnalyticsSettingsStore.save(changed, to: url)
        let stale = try await action.execute(parameters: [:], context: ACTAActionContext())
        XCTAssertFalse(stale.success)
        XCTAssertTrue(stale.error?.hasPrefix("UNAVAILABLE:") == true)
        XCTAssertFalse(stale.outputJSON.contains("globalEnabled"))
    }

    func testInvalidInitialSettingsDisableEngineAndKeepErrorVisible() throws {
        let root = IsolatedWallFixtureSupport.root()
        try IsolatedWallFixtureSupport.prepare(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsURL = root.appendingPathComponent("settings.json")
        try Data("invalid synthetic settings".utf8).write(to: settingsURL)
        let engine = LocalVideoAnalyticsEngine(
            settingsURL: settingsURL,
            incidentsURL: root.appendingPathComponent("incidents.json"),
            evidenceDirectoryURL: root.appendingPathComponent("evidence"),
            auditLogURL: root.appendingPathComponent("audit.json"),
            modelDiscovery: IsolatedWallFixtureSupport.modelDiscovery
        )
        XCTAssertNotNil(engine.persistenceError)
        engine.startIfEnabled(activeCameraCount: 0)
        XCTAssertEqual(engine.engineState, .error)
        engine.recoverInterruptedVerifications()
        XCTAssertNotNil(engine.persistenceError)
        XCTAssertThrowsError(try engine.updateSettings(.safeDefaults))
        XCTAssertEqual(try Data(contentsOf: settingsURL), Data("invalid synthetic settings".utf8))
    }

    func testModelRouteWithholdsSettingsWhenResultAuditFails() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let action = ACTAScopedAnalyticsSettingsAction(provider: ACTAEngineAnalyticsSettingsReadProvider(model: model))
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id], audit: { event in
            if event.phase == .result && event.outcome == "success" { throw CocoaError(.fileWriteUnknown) }
        })
        let host = try XCTUnwrap(made)
        let issued = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
            threadID: "fixture", actionIDs: [action.id])
        let session = try XCTUnwrap(issued)
        let store = try LocalTrackingStore(url: root.appendingPathComponent("chat.sqlite"))
        let coordinator = ACTAAnalyticsCoordinator(aiClient: IsolatedWallFixtureSupport.client(), trackingStore: store)
        let name = "acta__analytics__get_settings"
        let call = ACTAAgentFunctionCall(callID: "analytics", name: name, argumentsJSON: "{}")
        let result = await coordinator.executeModelGeneratedAgentTool(call, threadID: "fixture",
            requestToolNames: [name], broker: host.broker, brokerSession: session)
        XCTAssertTrue(result.outputJSON.contains("AUDIT_FAILED"))
        XCTAssertFalse(result.outputJSON.contains("action_output"))
        XCTAssertFalse(result.outputJSON.contains("globalEnabled"))
        await host.broker.closeSession(session, operatorKey: host.operatorKey)
    }

    func testProjectsAppliedGlobalSettingsWithoutCameraData() throws {
        var settings = VideoAnalyticsSettings()
        settings.globalEnabled = false
        settings.executionMode = .distributed
        settings.sensitivityProfile = .highSensitivity
        settings.enablePersonDetection = false
        settings.enablePoseEstimation = true
        settings.enableFallDetection = false
        settings.enableBehaviorAnalysis = true
        settings.enableProlongedInactivity = false
        settings.enableLoiteringDetection = true
        settings.enableZoneMonitoring = false
        settings.enableUnusualMovement = true
        settings.enableCrowdActivity = false
        settings.enableFightDetection = true
        settings.enableSecondaryVLMVerification = false
        settings.enableSoundAlert = true
        settings.enableVisualAlertBanner = false
        settings.enableEvidenceRecording = true
        settings.analyticsSamplingFPS = 5
        settings.minimumVisibleKeypoints = 9
        settings.overlaySettings.showTrackID = false
        let cameraID = UUID()
        var override = CameraAnalyticsOverride(cameraID: cameraID)
        override.restrictedZones = [.rectangle(name: "synthetic-secret", x: 0.1, y: 0.1, width: 0.5, height: 0.5)]
        settings.cameraOverrides[cameraID] = override
        let data = try JSONEncoder().encode(ACTAEngineAnalyticsSettingsReadProvider.project(settings))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["executionMode"] as? String, "distributed")
        XCTAssertEqual(object["sensitivity"] as? String, "highSensitivity")
        let advanced = try XCTUnwrap(object["advanced"] as? [String: Any])
        XCTAssertEqual(advanced["analyticsSamplingFPS"] as? Double, 5)
        XCTAssertEqual(advanced["minimumVisibleKeypoints"] as? Int, 9)
        let overlays = try XCTUnwrap(object["overlays"] as? [String: Any])
        XCTAssertEqual(overlays["showTrackID"] as? Bool, false)
        for key in ["globalEnabled", "personDetection", "fallDetection", "inactivityDetection",
                    "zoneMonitoring", "crowdActivity", "secondaryVerification", "visualAlert"] {
            XCTAssertEqual(object[key] as? Bool, false, key)
        }
        for key in ["poseEstimation", "behaviorAnalysis", "loiteringDetection", "unusualMovement",
                    "fightDetection", "soundAlert", "evidenceRecording"] {
            XCTAssertEqual(object[key] as? Bool, true, key)
        }
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("synthetic-secret"))
        XCTAssertFalse(json.contains(cameraID.uuidString))
        XCTAssertFalse(json.contains("override"))
    }

    func testEveryModeAndSensitivityIsMapped() {
        var settings = VideoAnalyticsSettings()
        for (mode, expected) in [(AnalyticsExecutionMode.local, "local"), (.distributed, "distributed")] {
            settings.executionMode = mode
            XCTAssertEqual(ACTAEngineAnalyticsSettingsReadProvider.project(settings).executionMode.rawValue, expected)
        }
        for (profile, expected) in [(AnalyticsSensitivityProfile.conservative, "conservative"),
                                    (.balanced, "balanced"), (.highSensitivity, "highSensitivity"), (.custom, "custom")] {
            settings.sensitivityProfile = profile
            XCTAssertEqual(ACTAEngineAnalyticsSettingsReadProvider.project(settings).sensitivity.rawValue, expected)
        }
    }
}
