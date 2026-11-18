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

    @Test func parameterSchemasDecodeBeforeEmptyStringSupport() throws {
        let legacy = Data(#"{"name":"name","type":"string","description":"Name","isRequired":true}"#.utf8)
        let schema = try JSONDecoder().decode(ACTAActionParameterSchema.self, from: legacy)
        #expect(!schema.allowsEmpty)
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

    @Test func reviewedTitleMustMatchExactTokenSummaryForApprovalAndRejection() async throws {
        let registry = ACTAActionRegistry()
        let state = SnapshotState()
        await registry.register(SnapshotAction(state: state))
        let arguments = ["value": "fake"]
        let context = ACTAActionContext(threadID: "review-thread")
        let first = try await registry.execute(actionID: "test.snapshot", parameters: arguments, context: context)
        let second = try await registry.execute(actionID: "test.snapshot", parameters: arguments, context: context)
        let token = try #require(first.confirmationToken)
        #expect(await registry.confirmationMatches(token: token, actionID: "test.snapshot", parameters: arguments,
                                                   threadID: "review-thread", expectedReviewTitle: first.summary))
        for alteredTitle in [first.summary + " ", second.summary, "Snapshot"] {
            #expect(!(await registry.confirmationMatches(token: token, actionID: "test.snapshot", parameters: arguments,
                                                        threadID: "review-thread", expectedReviewTitle: alteredTitle)))
            for confirmed in [true, false] {
                let result = try await registry.confirmAndExecute(token: token, confirmed: confirmed,
                    expectedActionID: "test.snapshot", expectedParameters: arguments,
                    expectedThreadID: "review-thread", expectedReviewTitle: alteredTitle)
                #expect(result.error?.hasPrefix("CONFIRMATION_MISMATCH:") == true)
            }
        }
        #expect(await state.confirmedCalls == 0)
        let approved = try await registry.confirmAndExecute(token: token, confirmed: true,
            expectedActionID: "test.snapshot", expectedParameters: arguments,
            expectedThreadID: "review-thread", expectedReviewTitle: first.summary)
        #expect(approved.success)
        #expect(await state.confirmedCalls == 1)
        let replay = try await registry.confirmAndExecute(token: token, confirmed: true,
            expectedActionID: "test.snapshot", expectedParameters: arguments,
            expectedThreadID: "review-thread", expectedReviewTitle: first.summary)
        #expect(!replay.success)
        let rejection = try await registry.confirmAndExecute(token: try #require(second.confirmationToken), confirmed: false,
            expectedActionID: "test.snapshot", expectedParameters: arguments,
            expectedThreadID: "review-thread", expectedReviewTitle: second.summary)
        #expect(rejection.summary.contains("cancelled"))
        #expect(await state.confirmedCalls == 1)
    }

    @Test func preparedApprovalRequiresTitleButLegacyRejectionIsAllowed() async throws {
        let registry = ACTAActionRegistry()
        let state = SnapshotState()
        await registry.register(SnapshotAction(state: state))
        let arguments = ["value": "fake"]
        let context = ACTAActionContext(threadID: "review-thread")
        let proposed = try await registry.execute(actionID: "test.snapshot", parameters: arguments, context: context)
        let token = try #require(proposed.confirmationToken)
        let tokenOnly = try await registry.confirmAndExecute(token: token, confirmed: true)
        #expect(tokenOnly.error?.hasPrefix("CONFIRMATION_MISMATCH:") == true)
        let intentOnly = try await registry.confirmAndExecute(token: token, confirmed: true,
            expectedActionID: "test.snapshot", expectedParameters: arguments, expectedThreadID: "review-thread")
        #expect(intentOnly.error?.hasPrefix("CONFIRMATION_MISMATCH:") == true)
        let wrongTitle = try await registry.confirmAndExecute(token: token, confirmed: true,
            expectedActionID: "test.snapshot", expectedParameters: arguments,
            expectedThreadID: "review-thread", expectedReviewTitle: proposed.summary + " altered")
        #expect(wrongTitle.error?.hasPrefix("CONFIRMATION_MISMATCH:") == true)
        #expect(await state.confirmedCalls == 0)
        let approved = try await registry.confirmAndExecute(token: token, confirmed: true,
            expectedActionID: "test.snapshot", expectedParameters: arguments,
            expectedThreadID: "review-thread", expectedReviewTitle: proposed.summary)
        #expect(approved.success)
        #expect(await state.confirmedCalls == 1)

        let first = try await registry.execute(actionID: "test.snapshot", parameters: arguments, context: context)
        let rejected = try await registry.confirmAndExecute(token: try #require(first.confirmationToken), confirmed: false)
        #expect(rejected.summary.contains("cancelled"))
        let second = try await registry.execute(actionID: "test.snapshot", parameters: arguments, context: context)
        let secondToken = try #require(second.confirmationToken)
        let intentRejected = try await registry.confirmAndExecute(token: secondToken, confirmed: false,
            expectedActionID: "test.snapshot", expectedParameters: arguments, expectedThreadID: "review-thread")
        #expect(intentRejected.summary.contains("cancelled"))
        let replay = try await registry.confirmAndExecute(token: secondToken, confirmed: true,
            expectedActionID: "test.snapshot", expectedParameters: arguments,
            expectedThreadID: "review-thread", expectedReviewTitle: second.summary)
        #expect(!replay.success)
        #expect(await state.confirmedCalls == 1)
    }

    @Test func titleBoundMatchingStillRejectsExpiredAndReplacedTokens() async throws {
        let clock = ConfirmationClock()
        let registry = ACTAActionRegistry(confirmationNow: { clock.now() })
        let state = SnapshotState()
        await registry.register(SnapshotAction(state: state))
        let arguments = ["value": "fake"]
        let expired = try await registry.execute(actionID: "test.snapshot", parameters: arguments)
        let expiredToken = try #require(expired.confirmationToken)
        clock.advance(300)
        #expect(!(await registry.confirmationMatches(token: expiredToken, actionID: "test.snapshot", parameters: arguments,
                                                    threadID: "default", expectedReviewTitle: expired.summary)))
        let expiredResult = try await registry.confirmAndExecute(token: expiredToken, confirmed: true,
            expectedActionID: "test.snapshot", expectedParameters: arguments,
            expectedThreadID: "default", expectedReviewTitle: expired.summary)
        #expect(!expiredResult.success)
        let replaced = try await registry.execute(actionID: "test.snapshot", parameters: arguments)
        let replacedToken = try #require(replaced.confirmationToken)
        await registry.register(SnapshotAction(state: state))
        #expect(!(await registry.confirmationMatches(token: replacedToken, actionID: "test.snapshot", parameters: arguments,
                                                    threadID: "default", expectedReviewTitle: replaced.summary)))
        let replacedResult = try await registry.confirmAndExecute(token: replacedToken, confirmed: true,
            expectedActionID: "test.snapshot", expectedParameters: arguments,
            expectedThreadID: "default", expectedReviewTitle: replaced.summary)
        #expect(!replacedResult.success)
        #expect(await state.confirmedCalls == 0)
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

    actor SnapshotState {
        private var revision = 1
        private(set) var confirmedCalls = 0

        func currentRevision() -> Int { revision }
        func advance() { revision += 1 }
        func check(_ expected: Int) -> Bool {
            confirmedCalls += 1
            return revision == expected
        }
    }

    struct SnapshotAction: ACTAPreparedConfirmationAction {
        struct Snapshot: Sendable {
            let value: String
            let revision: Int
            let thread: String
            let initiator: String
        }

        var id = "test.snapshot"
        let title = "Snapshot"
        let description = "Fake snapshot action"
        let classification = ACTAActionClassification.destructive
        let parameters = [ACTAActionParameterSchema(name: "value", type: "string", description: "Fake value", isRequired: true)]
        let state: SnapshotState
        var latch: MutationLatch? = nil
        var protected = true
        var failPreparation = false
        var reviewSummary: String? = nil

        func requiresConfirmation(parameters: [String: String]) -> Bool { protected }

        func prepareConfirmation(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAPreparedConfirmation<Snapshot> {
            if let latch { await latch.hold() }
            if failPreparation || context.isConfirmed { throw PreparationError() }
            let snapshot = Snapshot(value: parameters["value"]!, revision: await state.currentRevision(),
                                    thread: context.threadID, initiator: context.initiator)
            return ACTAPreparedConfirmation(snapshot: snapshot, reviewSummary: reviewSummary ?? "Review fake item at revision \(snapshot.revision)")
        }

        struct PreparationError: LocalizedError {
            var errorDescription: String? { "fake-secret-in-error" }
        }

        func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
            ACTAActionResult(actionID: id, success: true, summary: context.isConfirmed ? "unexpected confirmation" : "ordinary execution")
        }

        func executeConfirmed(parameters: [String: String], context: ACTAActionContext, snapshot: Snapshot) async throws -> ACTAActionResult {
            guard context.isConfirmed, parameters["value"] == snapshot.value,
                  context.threadID == snapshot.thread, context.initiator == snapshot.initiator,
                  await state.check(snapshot.revision) else {
                return .failed(actionID: id, error: "STALE_SNAPSHOT")
            }
            return ACTAActionResult(actionID: id, success: true, summary: "Confirmed \(snapshot.value)")
        }

        func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool { true }
    }

    @Test func preparedSnapshotsBindToTokenAndReviewedContext() async throws {
        let registry = ACTAActionRegistry()
        let state = SnapshotState()
        await registry.register(SnapshotAction(state: state))
        let first = try await registry.execute(actionID: "test.snapshot", parameters: ["value": "fake-secret-one"],
                                               context: ACTAActionContext(threadID: "first", initiator: "review", isConfirmed: true))
        let second = try await registry.executeJSON(actionID: "test.snapshot", argumentsJSON: #"{"value":"fake-secret-two"}"#,
                                                    context: ACTAActionContext(threadID: "second", initiator: "other"))
        #expect(first.summary.contains("Review fake item at revision 1"))
        #expect(!first.summary.contains("fake-secret-one"))
        #expect(!first.outputJSON.contains("fake-secret-one"))
        let firstToken = try #require(first.confirmationToken)
        let secondToken = try #require(second.confirmationToken)
        let mismatch = try await registry.confirmAndExecute(token: firstToken, confirmed: true,
            expectedActionID: "test.snapshot", expectedParameters: ["value": "fake-secret-two"], expectedThreadID: "second")
        #expect(mismatch.error?.hasPrefix("CONFIRMATION_MISMATCH:") == true)
        let secondResult = try await registry.confirmAndExecute(token: secondToken, confirmed: true,
            expectedActionID: "test.snapshot", expectedParameters: ["value": "fake-secret-two"],
            expectedThreadID: "second", expectedReviewTitle: second.summary)
        let firstResult = try await registry.confirmAndExecute(token: firstToken, confirmed: true,
            expectedActionID: "test.snapshot", expectedParameters: ["value": "fake-secret-one"],
            expectedThreadID: "first", expectedReviewTitle: first.summary)
        #expect(secondResult.summary == "Confirmed fake-secret-two")
        #expect(firstResult.summary == "Confirmed fake-secret-one")
        #expect(await state.confirmedCalls == 2)
        let replay = try await registry.confirmAndExecute(token: firstToken, confirmed: true)
        #expect(!replay.success)
    }

    @Test func preparedSnapshotCanRejectStaleStateAndNeverRunsOnRejectionExpiryOrReplacement() async throws {
        let clock = ConfirmationClock()
        let registry = ACTAActionRegistry(confirmationNow: { clock.now() })
        let state = SnapshotState()
        await registry.register(SnapshotAction(state: state))
        let actionID = "test.snapshot"
        let params = ["value": "fake"]
        let stale = try await registry.execute(actionID: actionID, parameters: params)
        await state.advance()
        let staleResult = try await registry.confirmAndExecute(token: try #require(stale.confirmationToken), confirmed: true,
            expectedActionID: actionID, expectedParameters: params, expectedThreadID: "default",
            expectedReviewTitle: stale.summary)
        #expect(staleResult.error == "STALE_SNAPSHOT")
        let rejected = try await registry.execute(actionID: actionID, parameters: params)
        _ = try await registry.confirmAndExecute(token: try #require(rejected.confirmationToken), confirmed: false)
        let expired = try await registry.execute(actionID: actionID, parameters: params)
        clock.advance(300)
        let expiredResult = try await registry.confirmAndExecute(token: try #require(expired.confirmationToken), confirmed: true)
        #expect(!expiredResult.success)
        let replaced = try await registry.execute(actionID: actionID, parameters: params)
        let replacementState = SnapshotState()
        await registry.register(SnapshotAction(state: replacementState))
        let replacedResult = try await registry.confirmAndExecute(token: try #require(replaced.confirmationToken), confirmed: true)
        #expect(!replacedResult.success)
        let unregistered = try await registry.execute(actionID: actionID, parameters: params)
        await registry.unregister(actionID: actionID)
        let unregisteredResult = try await registry.confirmAndExecute(token: try #require(unregistered.confirmationToken), confirmed: true)
        #expect(!unregisteredResult.success)
        #expect(await state.confirmedCalls == 1)
        #expect(await replacementState.confirmedCalls == 0)
    }

    @Test func preparationCancellationAndReplacementDoNotIssueTokens() async throws {
        for cancel in [true, false] {
            let registry = ACTAActionRegistry(confirmationNow: { Date() }, maxPendingConfirmations: 1)
            let latch = MutationLatch()
            let state = SnapshotState()
            await registry.register(SnapshotAction(state: state, latch: latch))
            await registry.register(ContextProbeAction())
            let task = Task { try await registry.execute(actionID: "test.snapshot", parameters: ["value": "fake"]) }
            await latch.waitUntilStarted()
            let unrelated = try await registry.execute(actionID: "test.context", parameters: [:])
            #expect(unrelated.summary == "unconfirmed")
            if cancel {
                task.cancel()
            } else {
                await registry.unregister(actionID: "test.snapshot")
                await registry.register(SnapshotAction(state: state))
            }
            await latch.release()
            if cancel {
                do {
                    let result = try await task.value
                    Issue.record("Cancelled preparation returned \(result)")
                } catch is CancellationError {
                }
            } else {
                let result = try await task.value
                #expect(result.confirmationToken == nil)
                #expect(result.error?.hasPrefix("CONFIRMATION_REVOKED:") == true)
            }
            #expect(await state.confirmedCalls == 0)
            await registry.register(SnapshotAction(state: state))
            let retry = try await registry.execute(actionID: "test.snapshot", parameters: ["value": "fake"])
            #expect(retry.confirmationToken != nil)
        }
    }

    @Test func preparationFailureIsRedactedAndUnprotectedActionsUseOrdinaryExecution() async throws {
        let registry = ACTAActionRegistry(confirmationNow: { Date() }, maxPendingConfirmations: 1)
        let state = SnapshotState()
        await registry.register(SnapshotAction(state: state, failPreparation: true))
        let failed = try await registry.execute(actionID: "test.snapshot", parameters: ["value": "fake-secret"])
        #expect(failed.error?.hasPrefix("CONFIRMATION_PREPARATION_FAILED:") == true)
        #expect(!failed.summary.contains("fake-secret"))
        #expect(!failed.outputJSON.contains("fake-secret"))
        #expect(failed.confirmationToken == nil)
        await registry.register(SnapshotAction(state: state))
        let retry = try await registry.execute(actionID: "test.snapshot", parameters: ["value": "fake"])
        #expect(retry.confirmationToken != nil)
        await registry.register(SnapshotAction(state: state, protected: false, failPreparation: true))
        let result = try await registry.execute(actionID: "test.snapshot", parameters: ["value": "fake"],
                                                context: ACTAActionContext(isConfirmed: true))
        #expect(result.success)
        #expect(result.summary == "ordinary execution")
        #expect(result.confirmationToken == nil)
    }

    @Test func pendingCapacityPreservesLiveTokensAndRecoversAfterRejectionAndExpiry() async throws {
        let clock = ConfirmationClock()
        let registry = ACTAActionRegistry(confirmationNow: { clock.now() }, maxPendingConfirmations: 2)
        let state = SnapshotState()
        await registry.register(SnapshotAction(state: state))
        await registry.register(SettingsUpdatePermissionsAction(featureProvider: MockFeatureProvider()))
        let arguments = ["value": "fake"]
        let first = try await registry.execute(actionID: "test.snapshot", parameters: arguments)
        let second = try await registry.execute(actionID: "settings.update_permissions", parameters: ["allow_voice_input": "true"])
        let firstToken = try #require(first.confirmationToken)
        let secondToken = try #require(second.confirmationToken)
        let full = try await registry.execute(actionID: "test.snapshot", parameters: arguments)
        #expect(full.error?.hasPrefix("CONFIRMATION_CAPACITY:") == true)
        #expect(full.confirmationToken == nil)
        #expect(await registry.confirmationMatches(token: firstToken, actionID: "test.snapshot", parameters: arguments,
                                                  threadID: "default", expectedReviewTitle: first.summary))
        let rejected = try await registry.confirmAndExecute(token: secondToken, confirmed: false)
        #expect(rejected.summary.contains("cancelled"))
        let retry = try await registry.execute(actionID: "test.snapshot", parameters: arguments)
        #expect(retry.confirmationToken != nil)
        clock.advance(300)
        let afterExpiry = try await registry.execute(actionID: "test.snapshot", parameters: arguments)
        #expect(afterExpiry.confirmationToken != nil)
        let expired = try await registry.confirmAndExecute(token: firstToken, confirmed: true,
            expectedActionID: "test.snapshot", expectedParameters: arguments, expectedThreadID: "default",
            expectedReviewTitle: first.summary)
        #expect(!expired.success)
    }

    @Test func concurrentPreparationsReserveCapacityUntilTheyFinish() async throws {
        let registry = ACTAActionRegistry(confirmationNow: { Date() }, maxPendingConfirmations: 2)
        let state = SnapshotState()
        let firstLatch = MutationLatch()
        let secondLatch = MutationLatch()
        await registry.register(SnapshotAction(state: state, latch: firstLatch))
        await registry.register(SnapshotAction(id: "test.snapshot.second", state: state, latch: secondLatch))
        await registry.register(SnapshotAction(id: "test.snapshot.third", state: state))
        let arguments = ["value": "fake"]
        let first = Task { try await registry.execute(actionID: "test.snapshot", parameters: arguments) }
        await firstLatch.waitUntilStarted()
        let second = Task { try await registry.execute(actionID: "test.snapshot.second", parameters: arguments) }
        await secondLatch.waitUntilStarted()
        let full = try await registry.execute(actionID: "test.snapshot.third", parameters: arguments)
        #expect(full.error?.hasPrefix("CONFIRMATION_CAPACITY:") == true)
        first.cancel()
        let stillFull = try await registry.execute(actionID: "test.snapshot.third", parameters: arguments)
        #expect(stillFull.error?.hasPrefix("CONFIRMATION_CAPACITY:") == true)
        await firstLatch.release()
        do {
            _ = try await first.value
            Issue.record("Cancelled preparation issued a result")
        } catch is CancellationError {
        }
        let retry = try await registry.execute(actionID: "test.snapshot.third", parameters: arguments)
        #expect(retry.confirmationToken != nil)
        await secondLatch.release()
        let secondResult = try await second.value
        #expect(secondResult.confirmationToken != nil)
        let fullAgain = try await registry.execute(actionID: "test.snapshot.third", parameters: arguments)
        #expect(fullAgain.error?.hasPrefix("CONFIRMATION_CAPACITY:") == true)
    }

    @Test func preparedReviewSummaryMustBeNonemptyAndWithinUTF8Limit() async throws {
        let registry = ACTAActionRegistry(confirmationNow: { Date() }, maxPendingConfirmations: 1)
        let state = SnapshotState()
        let limit = ACTAActionRegistry.maxPreparedReviewSummaryUTF8Bytes
        for summary in ["", " \n\t", String(repeating: "x", count: limit + 1), String(repeating: "é", count: limit / 2 + 1)] {
            await registry.register(SnapshotAction(state: state, reviewSummary: summary))
            let rejected = try await registry.execute(actionID: "test.snapshot", parameters: ["value": "fake"])
            #expect(rejected.error?.hasPrefix("CONFIRMATION_REVIEW_INVALID:") == true)
            #expect(rejected.confirmationToken == nil)
        }
        let fakeFrames = (0..<256).map { "frame \($0): id \(UUID()) camera \(UUID()) bytes 123 timestamp 2000000" }.joined(separator: "\n")
        for summary in [fakeFrames, String(repeating: "x", count: limit)] {
            await registry.register(SnapshotAction(state: state, reviewSummary: summary))
            let accepted = try await registry.execute(actionID: "test.snapshot", parameters: ["value": "fake"])
            #expect(accepted.confirmationToken != nil)
            #expect(accepted.summary.contains(summary))
        }
    }

    @Test func tokenLifetimeStartsAfterPreparationAndCancelledApprovalConsumesToken() async throws {
        let clock = ConfirmationClock()
        let registry = ACTAActionRegistry(confirmationNow: { clock.now() })
        let state = SnapshotState()
        let preparation = MutationLatch()
        await registry.register(SnapshotAction(state: state, latch: preparation))
        let pendingTask = Task { try await registry.execute(actionID: "test.snapshot", parameters: ["value": "fake"]) }
        await preparation.waitUntilStarted()
        clock.advance(600)
        await preparation.release()
        let pending = try await pendingTask.value
        let token = try #require(pending.confirmationToken)
        let valid = await registry.confirmationMatches(token: token, actionID: "test.snapshot",
                                                       parameters: ["value": "fake"], threadID: "default")
        #expect(valid)
        let approvalGate = MutationLatch()
        let approval = Task {
            await approvalGate.hold()
            return try await registry.confirmAndExecute(token: token, confirmed: true,
                expectedActionID: "test.snapshot", expectedParameters: ["value": "fake"],
                expectedThreadID: "default", expectedReviewTitle: pending.summary)
        }
        await approvalGate.waitUntilStarted()
        approval.cancel()
        await approvalGate.release()
        do {
            let result = try await approval.value
            Issue.record("Cancelled approval returned \(result)")
        } catch is CancellationError {
        }
        let replay = try await registry.confirmAndExecute(token: token, confirmed: true)
        #expect(!replay.success)
        #expect(await state.confirmedCalls == 0)
    }

}
