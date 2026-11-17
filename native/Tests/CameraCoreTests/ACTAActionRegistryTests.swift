import Foundation
import Testing
@testable import CameraCore

struct ACTAActionRegistryTests {

    final class MockSettingsProvider: ACTASystemSettingsProvider, @unchecked Sendable {
        var config = WallConfiguration()
        func loadConfiguration() throws -> WallConfiguration { config }
        func saveConfiguration(_ config: WallConfiguration) throws { self.config = config }
    }

    final class MockFeatureProvider: ACTAFeaturePreferencesProvider, @unchecked Sendable {
        var preferences = CameraFeaturePreferences()
        func loadPreferences() throws -> CameraFeaturePreferences { preferences }
        func savePreferences(_ prefs: CameraFeaturePreferences) throws { self.preferences = prefs }
    }

    final class MockAnalyticsProvider: ACTAVideoAnalyticsSettingsProvider, @unchecked Sendable {
        var settings = VideoAnalyticsSettings()
        func loadSettings() -> VideoAnalyticsSettings { settings }
        func updateSettings(_ mutate: @Sendable (inout VideoAnalyticsSettings) -> Void) throws {
            mutate(&settings)
        }
    }

    @Test func registrationAndOpenAIToolsSchemaExport() async throws {
        let registry = ACTAActionRegistry()
        await registry.register(SettingsGetSectionAction())
        await registry.register(SettingsUpdateSystemAction())
        await registry.register(WatchCreateAction())

        let actions = await registry.allActions()
        #expect(actions.count == 3)

        let tools = await registry.openAITools()
        #expect(tools.count == 3)

        let names = Set(tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
        #expect(names.contains("settings.get_section"))
        #expect(names.contains("settings.update_system"))
        #expect(names.contains("watch.create"))

        // Validate parameter schema format
        let systemTool = tools.first { ($0["function"] as? [String: Any])?["name"] as? String == "settings.update_system" }
        let fn = try #require(systemTool?["function"] as? [String: Any])
        let params = try #require(fn["parameters"] as? [String: Any])
        #expect(params["type"] as? String == "object")
        let props = try #require(params["properties"] as? [String: Any])
        #expect(props["columns"] != nil)
        #expect(props["detection_threshold"] != nil)
    }

    @Test func inspectActionAutoExecution() async throws {
        let registry = ACTAActionRegistry()
        let settings = MockSettingsProvider()
        settings.config.columns = 6
        settings.config.detectionFPS = 3
        await registry.register(SettingsGetSectionAction(settingsProvider: settings, featureProvider: MockFeatureProvider()))

        let result = try await registry.execute(actionID: "settings.get_section", parameters: ["section": "general"])
        #expect(result.success)
        #expect(!result.requiresOperatorConfirmation)
        #expect(result.verified)
        #expect(result.summary.contains("6 cols"))
        #expect(result.outputJSON.contains("\"columns\" : 6") || result.outputJSON.contains("\"columns\":6"))
    }

    @Test func reversibleActionExecutionAndVerification() async throws {
        let registry = ACTAActionRegistry()
        let settings = MockSettingsProvider()
        settings.config.columns = 4
        settings.config.detectionFPS = 2
        await registry.register(SettingsUpdateSystemAction(settingsProvider: settings))

        let result = try await registry.execute(
            actionID: "settings.update_system",
            parameters: ["columns": "8", "detection_fps": "4"]
        )

        #expect(result.success)
        #expect(result.verified)
        #expect(!result.requiresOperatorConfirmation)
        #expect(settings.config.columns == 8)
        #expect(settings.config.detectionFPS == 4)
    }

    @Test func featureTogglesAction() async throws {
        let registry = ACTAActionRegistry()
        let features = MockFeatureProvider()
        await registry.register(SettingsUpdateFeatureTogglesAction(featureProvider: features))

        // Enable scheduled missions
        let res1 = try await registry.execute(
            actionID: "settings.update_feature_toggles",
            parameters: ["feature": "scheduledMissions", "enabled": "true"]
        )
        #expect(res1.success)
        #expect(res1.verified)
        #expect(features.preferences.enabledFeatures.contains(.scheduledMissions))

        // Disable scheduled missions
        let res2 = try await registry.execute(
            actionID: "settings.update_feature_toggles",
            parameters: ["feature": "scheduledMissions", "enabled": "0"]
        )
        #expect(res2.success)
        #expect(res2.verified)
        #expect(!features.preferences.enabledFeatures.contains(.scheduledMissions))
    }

    @Test func permissionsAction() async throws {
        let registry = ACTAActionRegistry()
        let features = MockFeatureProvider()
        await registry.register(SettingsUpdatePermissionsAction(featureProvider: features))

        let result = try await registry.execute(
            actionID: "settings.update_permissions",
            parameters: ["allow_voice_input": "true", "allow_external_ai": "false"]
        )
        #expect(!result.success)
        #expect(result.requiresOperatorConfirmation)
        #expect(!features.preferences.allowVoiceInput)
        let token = try #require(result.confirmationToken)
        let approved = try await registry.confirmAndExecute(token: token, confirmed: true)
        #expect(approved.success)
        #expect(approved.verified)
        #expect(features.preferences.allowVoiceInput)
        #expect(!features.preferences.allowExternalAI)
    }

    @Test func analyticsToggleAction() async throws {
        let registry = ACTAActionRegistry()
        let analytics = MockAnalyticsProvider()
        analytics.settings.enableFallDetection = false
        await registry.register(AnalyticsSetGlobalToggleAction(analyticsProvider: analytics))

        let result = try await registry.execute(
            actionID: "analytics.set_global_toggle",
            parameters: ["feature": "fall", "enabled": "true"]
        )
        #expect(result.success)
        #expect(result.verified)
        #expect(analytics.settings.enableFallDetection)
    }

    @Test func destructiveActionRequiresTwoPhaseConfirmation() async throws {
        let registry = ACTAActionRegistry()
        await registry.register(MemoryClearAllFramesAction())

        // 1. First execution must be intercepted and return confirmation token
        let initialResult = try await registry.execute(
            actionID: "memory.clear_all_frames",
            parameters: [:]
        )

        #expect(!initialResult.success)
        #expect(initialResult.requiresOperatorConfirmation)
        let token = try #require(initialResult.confirmationToken)
        #expect(token.hasPrefix("CONFIRM-"))
        #expect(initialResult.summary.contains("confirmation required"))

        // 2. Rejecting the confirmation must cancel execution cleanly
        let rejectResult = try await registry.confirmAndExecute(token: token, confirmed: false)
        #expect(!rejectResult.success)
        #expect(!rejectResult.requiresOperatorConfirmation)
        #expect(rejectResult.summary.contains("cancelled"))

        // Approval cannot turn an unconnected domain service into a successful deletion.
        let secondResult = try await registry.execute(
            actionID: "memory.clear_all_frames",
            parameters: [:]
        )
        let newToken = try #require(secondResult.confirmationToken)
        let confirmResult = try await registry.confirmAndExecute(token: newToken, confirmed: true)
        #expect(!confirmResult.success)
        #expect(!confirmResult.verified)
        #expect(confirmResult.error?.hasPrefix("UNSUPPORTED:") == true)
    }

    @Test func unsupportedActionReturnsCleanDiagnostic() async throws {
        let registry = ACTAActionRegistry()
        let result = try await registry.execute(actionID: "nonexistent.action", parameters: [:])
        #expect(!result.success)
        #expect(result.error?.contains("Unsupported action") == true)
    }
    @Test func disconnectedServicesNeverReportSuccess() async throws {
        let registry = ACTAActionRegistry()
        let cases: [(any ACTAActionProtocol, [String: String])] = [
            (IncidentListAction(), [:]),
            (IncidentTransitionStatusAction(), ["incident_id": "test", "status": "resolved"]),
            (IncidentDeleteEvidenceAction(), ["incident_id": "test"]),
            (MemoryDeleteFrameAction(), ["frame_id": "test"]),
            (MemoryClearAllFramesAction(), [:]),
            (WatchListAction(), [:]),
            (WatchCreateAction(), ["text": "test"]),
            (WatchCancelAction(), ["watch_id": "test"]),
            (AnalyticsGetSettingsAction(), [:]),
            (AnalyticsSetGlobalToggleAction(), ["feature": "fall", "enabled": "true"])
        ]
        for (action, parameters) in cases {
            await registry.register(action)
            let result = try await registry.execute(actionID: action.id, parameters: parameters,
                context: ACTAActionContext(isConfirmed: true))
            #expect(!result.success)
            #expect(!result.verified)
            #expect(result.error?.hasPrefix("UNSUPPORTED:") == true)
        }
    }

    @Test func invalidArgumentsDoNotMutateSettings() async throws {
        let registry = ACTAActionRegistry()
        let features = MockFeatureProvider()
        await registry.register(SettingsUpdateFeatureTogglesAction(featureProvider: features))
        for arguments in [
            ["feature": "scheduledMissions"],
            ["feature": "scheduledMissions", "enabled": "yes"],
            ["feature": "unknown", "enabled": "true"],
            ["feature": "scheduledMissions", "enabled": "true", "extra": "value"]
        ] {
            let result = try await registry.execute(actionID: "settings.update_feature_toggles", parameters: arguments)
            #expect(!result.success)
            #expect(result.error?.hasPrefix("INVALID_ARGUMENT:") == true)
        }
        #expect(features.preferences == CameraFeaturePreferences())
    }

    @Test func diagnosticsRemainValidJSON() throws {
        let result = ACTAActionResult.failed(actionID: "test", error: "invalid \"value\"\nnext line")
        let object = try JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: String]
        #expect(object?["error"] == result.error)
    }

    @Test func unknownAnalyticsFeatureDoesNotReportSuccess() async throws {
        let registry = ACTAActionRegistry()
        let analytics = MockAnalyticsProvider()
        await registry.register(AnalyticsSetGlobalToggleAction(analyticsProvider: analytics))
        let result = try await registry.execute(actionID: "analytics.set_global_toggle",
            parameters: ["feature": "unknown", "enabled": "true"])
        #expect(!result.success)
    }

    actor MutationLatch {
        private var started = false
        private var startedWaiters: [CheckedContinuation<Void, Never>] = []
        private var finish: CheckedContinuation<Void, Never>?
        func hold() async {
            await withCheckedContinuation { continuation in
                finish = continuation
                started = true
                startedWaiters.forEach { $0.resume() }
                startedWaiters.removeAll()
            }
        }
        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startedWaiters.append($0) }
        }
        func release() { finish?.resume(); finish = nil }
    }

    struct SuspendedMutation: ACTAActionProtocol {
        let id = "test.mutation"
        let title = "Test"
        let description = "Test mutation"
        let classification = ACTAActionClassification.reversible
        let parameters: [ACTAActionParameterSchema] = []
        let latch: MutationLatch
        func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
            await latch.hold()
            return ACTAActionResult(actionID: id, success: true, summary: "Applied")
        }
        func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool { true }
    }

    @Test func overlappingMutationsCannotInterleaveAcrossAwait() async throws {
        let registry = ACTAActionRegistry()
        let latch = MutationLatch()
        await registry.register(SuspendedMutation(latch: latch))
        let first = Task { try await registry.execute(actionID: "test.mutation", parameters: [:]) }
        await latch.waitUntilStarted()
        let second = try await registry.execute(actionID: "test.mutation", parameters: [:])
        await latch.release()
        let completed = try await first.value
        #expect(completed.success)
        #expect(!second.success)
        #expect(second.error?.hasPrefix("ACTION_BUSY:") == true)
    }

    @Test func confirmationTokenIsSingleUseAndExpires() async throws {
        let registry = ACTAActionRegistry()
        let features = MockFeatureProvider()
        await registry.register(SettingsUpdatePermissionsAction(featureProvider: features))
        let expired = try await registry.execute(actionID: "settings.update_permissions",
            parameters: ["allow_voice_input": "true"], context: ACTAActionContext(now: Date().addingTimeInterval(-301)))
        let expiredToken = try #require(expired.confirmationToken)
        let denied = try await registry.confirmAndExecute(token: expiredToken, confirmed: true)
        #expect(!denied.success)
        #expect(!features.preferences.allowVoiceInput)
        let pending = try await registry.execute(actionID: "settings.update_permissions", parameters: ["allow_voice_input": "true"])
        #expect(pending.summary.contains("allow_voice_input=true"))
        let token = try #require(pending.confirmationToken)
        let approved = try await registry.confirmAndExecute(token: token, confirmed: true)
        #expect(approved.success)
        let replay = try await registry.confirmAndExecute(token: token, confirmed: true)
        #expect(!replay.success)
    }

    @Test func privacyFeatureChangesRequireConfirmation() async throws {
        let registry = ACTAActionRegistry()
        let features = MockFeatureProvider()
        await registry.register(SettingsUpdateFeatureTogglesAction(featureProvider: features))
        for feature in ["publicShowcase", "accessControl", "independentWatcher", "chronologicalMemory",
                        "crossCameraIdentity", "plateRecognition", "operatorActions"] {
            let result = try await registry.execute(actionID: "settings.update_feature_toggles",
                parameters: ["feature": feature, "enabled": "true"])
            #expect(result.requiresOperatorConfirmation)
            #expect(!result.success)
        }
        #expect(features.preferences.enabledFeatures.isEmpty)
    }

}
