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

    final class ConfirmationClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_000)
        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func advance(_ seconds: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            value = value.addingTimeInterval(seconds)
        }
    }

    struct ContextProbeAction: ACTAActionProtocol {
        let id = "test.context"
        let title = "Context"
        let description = "Context probe"
        let classification = ACTAActionClassification.inspect
        let parameters: [ACTAActionParameterSchema] = []
        func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
            ACTAActionResult(actionID: id, success: true, summary: context.isConfirmed ? "confirmed" : "unconfirmed")
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
        #expect(UUID(uuidString: String(token.dropFirst("CONFIRM-".count))) != nil)
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
            var result = try await registry.execute(actionID: action.id, parameters: parameters,
                context: ACTAActionContext(isConfirmed: true))
            if let token = result.confirmationToken {
                result = try await registry.confirmAndExecute(token: token, confirmed: true)
            }
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
        let clock = ConfirmationClock()
        let registry = ACTAActionRegistry(confirmationNow: { clock.now() })
        let features = MockFeatureProvider()
        await registry.register(SettingsUpdatePermissionsAction(featureProvider: features))
        let expired = try await registry.execute(actionID: "settings.update_permissions",
            parameters: ["allow_voice_input": "true"], context: ACTAActionContext(now: .distantFuture, isConfirmed: true))
        let expiredToken = try #require(expired.confirmationToken)
        clock.advance(300)
        let denied = try await registry.confirmAndExecute(token: expiredToken, confirmed: true)
        #expect(!denied.success)
        #expect(!features.preferences.allowVoiceInput)
        let expiredReplay = try await registry.confirmAndExecute(token: expiredToken, confirmed: true)
        #expect(!expiredReplay.success)
        let pending = try await registry.execute(actionID: "settings.update_permissions", parameters: ["allow_voice_input": "true"])
        #expect(pending.summary.contains("allow_voice_input=true"))
        let token = try #require(pending.confirmationToken)
        let approved = try await registry.confirmAndExecute(token: token, confirmed: true)
        #expect(approved.success)
        let replay = try await registry.confirmAndExecute(token: token, confirmed: true)
        #expect(!replay.success)
    }

    @Test func externallyConfirmedContextCannotBypassProtectedAction() async throws {
        let registry = ACTAActionRegistry()
        let features = MockFeatureProvider()
        await registry.register(SettingsUpdatePermissionsAction(featureProvider: features))

        let invalid = try await registry.execute(
            actionID: "settings.update_permissions", parameters: ["allow_voice_input": "invalid"],
            context: ACTAActionContext(isConfirmed: true)
        )
        #expect(invalid.error?.hasPrefix("INVALID_ARGUMENT:") == true)
        #expect(invalid.confirmationToken == nil)
        #expect(!features.preferences.allowVoiceInput)

        let proposed = try await registry.execute(
            actionID: "settings.update_permissions",
            parameters: ["allow_voice_input": "1"],
            context: ACTAActionContext(initiator: "operator_review", isConfirmed: true)
        )
        #expect(!proposed.success)
        #expect(proposed.requiresOperatorConfirmation)
        #expect(proposed.summary.contains("allow_voice_input=true"))
        #expect(!features.preferences.allowVoiceInput)

        let token = try #require(proposed.confirmationToken)
        let approved = try await registry.confirmAndExecute(token: token, confirmed: true)
        #expect(approved.success)
        #expect(approved.verified)
        #expect(features.preferences.allowVoiceInput)
        let replay = try await registry.confirmAndExecute(token: token, confirmed: true)
        #expect(!replay.success)
    }

    @Test func externalConfirmationIsNotForwardedToUnprotectedActions() async throws {
        let registry = ACTAActionRegistry()
        await registry.register(ContextProbeAction())
        let result = try await registry.execute(actionID: "test.context", parameters: [:],
            context: ACTAActionContext(isConfirmed: true))
        #expect(result.success)
        #expect(result.summary == "unconfirmed")
    }

    @Test func tokensExecuteOnlyTheirValidatedArguments() async throws {
        let registry = ACTAActionRegistry()
        let features = MockFeatureProvider()
        await registry.register(SettingsUpdatePermissionsAction(featureProvider: features))
        let enable = try await registry.execute(actionID: "settings.update_permissions",
            parameters: ["allow_voice_input": "1"])
        let disable = try await registry.execute(actionID: "settings.update_permissions",
            parameters: ["allow_voice_input": "0"])
        let enableToken = try #require(enable.confirmationToken)
        let disableToken = try #require(disable.confirmationToken)
        #expect(enableToken != disableToken)
        let enabled = try await registry.confirmAndExecute(token: enableToken, confirmed: true)
        #expect(enabled.success)
        #expect(features.preferences.allowVoiceInput)
        let disabled = try await registry.confirmAndExecute(token: disableToken, confirmed: true)
        #expect(disabled.success)
        #expect(!features.preferences.allowVoiceInput)
    }

    @Test func reviewedIntentMustMatchPendingConfirmation() async throws {
        let registry = ACTAActionRegistry()
        let features = MockFeatureProvider()
        await registry.register(SettingsUpdatePermissionsAction(featureProvider: features))
        let actionID = "settings.update_permissions"
        let arguments = ["allow_voice_input": "true"]
        let pending = try await registry.execute(actionID: actionID, parameters: arguments,
            context: ACTAActionContext(threadID: "review-thread"))
        let token = try #require(pending.confirmationToken)

        for (reviewedAction, reviewedArguments, reviewedThread) in [
            ("other.action", arguments, "review-thread"),
            (actionID, ["allow_voice_input": "false"], "review-thread"),
            (actionID, ["allow_voice_input": "invalid"], "review-thread"),
            (actionID, [:], "review-thread"),
            (actionID, ["allow_voice_input": "true", "extra": "value"], "review-thread"),
            (actionID, arguments, "other-thread")
        ] {
            let result = try await registry.confirmAndExecute(token: token, confirmed: true,
                expectedActionID: reviewedAction, expectedParameters: reviewedArguments, expectedThreadID: reviewedThread)
            #expect(!result.success)
            #expect(result.error?.hasPrefix("CONFIRMATION_MISMATCH:") == true)
            #expect(!features.preferences.allowVoiceInput)
        }

        let approved = try await registry.confirmAndExecute(token: token, confirmed: true,
            expectedActionID: actionID, expectedParameters: arguments, expectedThreadID: "review-thread")
        #expect(approved.success)
        #expect(features.preferences.allowVoiceInput)
        let replay = try await registry.confirmAndExecute(token: token, confirmed: true,
            expectedActionID: actionID, expectedParameters: arguments, expectedThreadID: "review-thread")
        #expect(!replay.success)
    }

    @Test func reviewedBooleanArgumentsUseCanonicalValues() async throws {
        let registry = ACTAActionRegistry()
        let features = MockFeatureProvider()
        await registry.register(SettingsUpdatePermissionsAction(featureProvider: features))
        let actionID = "settings.update_permissions"
        for (original, reviewed, expected) in [
            ("1", "true", true), ("true", "1", true),
            ("0", "false", false), ("false", "0", false)
        ] {
            let pending = try await registry.execute(actionID: actionID,
                parameters: ["allow_voice_input": original],
                context: ACTAActionContext(threadID: "review-thread"))
            let token = try #require(pending.confirmationToken)
            let result = try await registry.confirmAndExecute(token: token, confirmed: true,
                expectedActionID: actionID, expectedParameters: ["allow_voice_input": reviewed],
                expectedThreadID: "review-thread")
            #expect(result.success)
            #expect(features.preferences.allowVoiceInput == expected)
        }
    }

    @Test func reviewedConfirmationRejectsExpiredAndReplayedTokens() async throws {
        let clock = ConfirmationClock()
        let registry = ACTAActionRegistry(confirmationNow: { clock.now() })
        let features = MockFeatureProvider()
        await registry.register(SettingsUpdatePermissionsAction(featureProvider: features))
        let actionID = "settings.update_permissions"
        let arguments = ["allow_voice_input": "true"]
        let pending = try await registry.execute(actionID: actionID, parameters: arguments,
            context: ACTAActionContext(threadID: "review-thread"))
        let token = try #require(pending.confirmationToken)
        clock.advance(300)
        let expired = try await registry.confirmAndExecute(token: token, confirmed: true,
            expectedActionID: actionID, expectedParameters: arguments, expectedThreadID: "review-thread")
        #expect(!expired.success)
        #expect(!features.preferences.allowVoiceInput)
        let replay = try await registry.confirmAndExecute(token: token, confirmed: true,
            expectedActionID: actionID, expectedParameters: arguments, expectedThreadID: "review-thread")
        #expect(!replay.success)
    }

    @Test func reviewedRejectionRequiresMatchingIntentAndConsumesToken() async throws {
        let registry = ACTAActionRegistry()
        let features = MockFeatureProvider()
        await registry.register(SettingsUpdatePermissionsAction(featureProvider: features))
        let actionID = "settings.update_permissions"
        let arguments = ["allow_voice_input": "true"]
        let pending = try await registry.execute(actionID: actionID, parameters: arguments,
            context: ACTAActionContext(threadID: "review-thread"))
        let token = try #require(pending.confirmationToken)
        let mismatch = try await registry.confirmAndExecute(token: token, confirmed: false,
            expectedActionID: actionID, expectedParameters: arguments, expectedThreadID: "other-thread")
        #expect(mismatch.error?.hasPrefix("CONFIRMATION_MISMATCH:") == true)
        let rejected = try await registry.confirmAndExecute(token: token, confirmed: false,
            expectedActionID: actionID, expectedParameters: arguments, expectedThreadID: "review-thread")
        #expect(!rejected.success)
        #expect(rejected.summary.contains("cancelled"))
        let replay = try await registry.confirmAndExecute(token: token, confirmed: true)
        #expect(!replay.success)
        #expect(!features.preferences.allowVoiceInput)
    }

    @Test func rejectionAndActionReplacementInvalidateTokens() async throws {
        let registry = ACTAActionRegistry()
        let original = MockFeatureProvider()
        await registry.register(SettingsUpdatePermissionsAction(featureProvider: original))
        let first = try await registry.execute(actionID: "settings.update_permissions",
            parameters: ["allow_voice_input": "true"])
        let rejectedToken = try #require(first.confirmationToken)
        let rejected = try await registry.confirmAndExecute(token: rejectedToken, confirmed: false)
        #expect(!rejected.success)
        let replay = try await registry.confirmAndExecute(token: rejectedToken, confirmed: true)
        #expect(!replay.success)
        #expect(!original.preferences.allowVoiceInput)

        let pending = try await registry.execute(actionID: "settings.update_permissions",
            parameters: ["allow_voice_input": "true"])
        let token = try #require(pending.confirmationToken)
        let replacement = MockFeatureProvider()
        await registry.register(SettingsUpdatePermissionsAction(featureProvider: replacement))
        let stale = try await registry.confirmAndExecute(token: token, confirmed: true)
        #expect(!stale.success)
        #expect(!original.preferences.allowVoiceInput)
        #expect(!replacement.preferences.allowVoiceInput)
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
