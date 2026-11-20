import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTAPhase2VoiceConversationTests: XCTestCase {
    private final class MockVoiceProcess: LocalVoiceOutputProcess {
        var stopCount = 0
        let completion: @MainActor (String?) -> Void
        init(completion: @escaping @MainActor (String?) -> Void) {
            self.completion = completion
        }
        func stop() { stopCount += 1 }
        func finish(error: String? = nil) { completion(error) }
    }

    private final class MockVoiceCapture: LocalVoiceCapture {
        let onEvent: @MainActor (LocalVoiceEvent) -> Void
        var finishCount = 0
        var cancelCount = 0
        init(onEvent: @escaping @MainActor (LocalVoiceEvent) -> Void) {
            self.onEvent = onEvent
        }
        func finish() { finishCount += 1 }
        func cancel() { cancelCount += 1 }
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("acta-phase2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testNoisySpeechGuardAndSpeechSanitizer() {
        // Noise-only and empty transcripts are rejected cleanly
        XCTAssertEqual(LocalVoiceTranscriptGuard.evaluate(""), .rejectedEmpty)
        XCTAssertEqual(LocalVoiceTranscriptGuard.evaluate("   \u{200B}\n\t  "), .rejectedEmpty)
        XCTAssertEqual(LocalVoiceTranscriptGuard.evaluate("... , ?!"), .rejectedNoise)
        XCTAssertEqual(LocalVoiceTranscriptGuard.evaluate("uh um hmm"), .rejectedNoise)
        XCTAssertEqual(LocalVoiceTranscriptGuard.evaluate("эээ мм гм"), .rejectedNoise)
        XCTAssertEqual(LocalVoiceTranscriptGuard.evaluate("אה אממ"), .rejectedNoise)

        // Valid utterances across EN / RU / HE are normalized and accepted
        XCTAssertEqual(
            LocalVoiceTranscriptGuard.evaluate("  Show\u{200B}  cameras   at Entrance  ", durationSeconds: 1.4),
            .accepted("Show cameras at Entrance")
        )
        XCTAssertEqual(
            LocalVoiceTranscriptGuard.evaluate("Покажи события на входе", durationSeconds: 1.2),
            .accepted("Покажи события на входе")
        )
        XCTAssertEqual(
            LocalVoiceTranscriptGuard.evaluate("הצג מצלמות בכניסה", durationSeconds: 1.2),
            .accepted("הצג מצלמות בכניסה")
        )

        // Speech sanitizer strips markdown, code blocks, and secret-bearing URLs
        let markdown = """
        ## Status Report
        **Entrance North** is online. Check [dashboard](https://secret.example/token?k=123).
        Stream: rtsp://admin:hunter2@10.0.0.5:554/ch1
        ```json
        {"secret": "do-not-read"}
        ```
        > Confirmed by `operator`.\u{200B}
        """
        let spoken = LocalVoiceSpeechSanitizer.sanitize(markdown)
        XCTAssertTrue(spoken.contains("Status Report"))
        XCTAssertTrue(spoken.contains("Entrance North is online."))
        XCTAssertTrue(spoken.contains("Check dashboard."))
        XCTAssertTrue(spoken.contains("Confirmed by operator."))
        XCTAssertFalse(spoken.contains("**"))
        XCTAssertFalse(spoken.contains("```"))
        XCTAssertFalse(spoken.contains("hunter2"))
        XCTAssertFalse(spoken.contains("secret.example"))
        XCTAssertFalse(spoken.contains("do-not-read"))
        XCTAssertFalse(spoken.contains("\u{200B}"))

        // UTF-8 byte cap never exceeds 8000 bytes even for multi-byte Cyrillic text
        let longRussian = String(repeating: "Проверка ", count: 1000)
        let truncated = LocalVoiceSpeechSanitizer.sanitize(longRussian)
        XCTAssertLessThanOrEqual(truncated.utf8.count, LocalVoiceSpeechSanitizer.maxUTF8Bytes)
        XCTAssertFalse(truncated.isEmpty)
    }

    func testAccidentalActivationGuardAndStatusDescriptor() {
        // Brief accidental mic taps with 1-2 chars are rejected
        XCTAssertEqual(LocalVoiceTranscriptGuard.evaluate("a", durationSeconds: 0.10), .rejectedAccidentalActivation)
        XCTAssertEqual(LocalVoiceTranscriptGuard.evaluate("ok", durationSeconds: 0.12), .rejectedAccidentalActivation)
        XCTAssertEqual(LocalVoiceTranscriptGuard.evaluate("x", durationSeconds: 1.5), .rejectedAccidentalActivation)
        // Deliberate short command (>= 0.25s, >= 2 chars) is accepted
        XCTAssertEqual(LocalVoiceTranscriptGuard.evaluate("ok", durationSeconds: 0.5), .accepted("ok"))

        // Status descriptor reflects permissions & offline states accurately
        XCTAssertEqual(
            LocalVoiceStatusDescriptor.resolve(allowVoiceInput: false, isRecording: false, isFinalizing: false, isSpeaking: false),
            .disabledByPermission
        )
        XCTAssertEqual(
            LocalVoiceStatusDescriptor.resolve(allowVoiceInput: true, isRecording: false, isFinalizing: false, isSpeaking: false, microphoneAuthorized: false),
            .microphoneDenied
        )
        XCTAssertEqual(
            LocalVoiceStatusDescriptor.resolve(allowVoiceInput: true, isRecording: false, isFinalizing: false, isSpeaking: false, speechAuthorized: false),
            .speechDenied
        )
        XCTAssertEqual(
            LocalVoiceStatusDescriptor.resolve(allowVoiceInput: true, isRecording: true, isFinalizing: false, isSpeaking: false),
            .listening
        )
        XCTAssertEqual(
            LocalVoiceStatusDescriptor.resolve(allowVoiceInput: true, isRecording: false, isFinalizing: true, isSpeaking: false),
            .finalizing
        )
        XCTAssertEqual(
            LocalVoiceStatusDescriptor.resolve(allowVoiceInput: true, isRecording: false, isFinalizing: false, isSpeaking: true),
            .speaking
        )
        XCTAssertEqual(
            LocalVoiceStatusDescriptor.resolve(allowVoiceInput: true, isRecording: false, isFinalizing: false, isSpeaking: false),
            .readyOffline
        )
    }

    func testAmbiguousCameraNamesInVoiceConversation() async throws {
        let dir = try tempDir()
        let camNorth = UUID()
        let camSouth = UUID()
        let names: [UUID: String] = [
            camNorth: "Entrance North",
            camSouth: "Entrance South"
        ]

        // Direct camera resolver detects ambiguity on partial spoken name
        let ambiguous = ACTAAnalyticsCoordinator.resolveAgentCamera("Entrance", cameraNames: names)
        XCTAssertNil(ambiguous.uuid)
        XCTAssertTrue(ambiguous.ambiguous)

        let exact = ACTAAnalyticsCoordinator.resolveAgentCamera("Entrance North", cameraNames: names)
        XCTAssertEqual(exact.uuid, camNorth)
        XCTAssertFalse(exact.ambiguous)

        // End-to-end voice broker session tool call with ambiguous spoken camera name fails closed cleanly
        let store = try LocalTrackingStore(url: dir.appendingPathComponent("tracks.sqlite"))
        let coordinator = ACTAAnalyticsCoordinator(aiClient: IsolatedWallFixtureSupport.client(), trackingStore: store)
        let made = await ACTALocalActionBroker.make(
            actions: [],
            allowedActionIDs: [],
            allowedInspectionIDs: ACTAAnalyticsCoordinator.localInspectionIDs,
            audit: { _ in }
        )
        let host = try XCTUnwrap(made)
        let opened = await host.broker.openSession(
            operatorKey: host.operatorKey,
            input: .voice,
            threadID: "voice-ambig",
            actionIDs: [],
            inspectionIDs: ACTAAnalyticsCoordinator.localInspectionIDs,
            historyCameraIDs: [camNorth, camSouth]
        )
        let session = try XCTUnwrap(opened)

        let call = ACTAAgentFunctionCall(
            callID: "voice-who",
            name: "who_was_present",
            argumentsJSON: #"{"camera_id":"Entrance"}"#
        )
        let output = await coordinator.executeModelGeneratedAgentTool(
            call,
            threadID: "voice-ambig",
            requestToolNames: ["who_was_present"],
            cameraNames: names,
            broker: host.broker,
            brokerSession: session
        )
        XCTAssertTrue(output.outputJSON.contains("AMBIGUOUS_CAMERA"), output.outputJSON)
    }

    func testBargeInInterruptionReleasesLeaseBeforeStartingDictation() async throws {
        let dir = try tempDir()
        let lockURL = dir.appendingPathComponent("voice-audio.lock")

        var activeProcess: MockVoiceProcess?
        var spokenTexts: [String] = []
        let output = LocalVoiceOutput(
            acquireAudioLease: { try LocalVoiceAudioLease.acquire(url: lockURL) },
            startProcess: { text, _, completion in
                spokenTexts.append(text)
                let proc = MockVoiceProcess(completion: completion)
                activeProcess = proc
                return proc
            }
        )

        var captures: [MockVoiceCapture] = []
        let input = LocalVoiceInput(
            speechPermission: { true },
            microphonePermission: { true },
            makeCapture: { _, onEvent in
                let cap = MockVoiceCapture(onEvent: onEvent)
                captures.append(cap)
                return cap
            },
            acquireAudioLease: { try LocalVoiceAudioLease.acquire(url: lockURL) }
        )

        let coordinator = LocalVoiceBargeInCoordinator()
        let owner = UUID()

        // 1. Start TTS holding the real flock audio lease
        output.speak("First response", localeIdentifier: "en-US", owner: owner)
        XCTAssertTrue(output.isBusy)
        let firstProc = try XCTUnwrap(activeProcess)

        // 2. Operator presses mic (barge-in) while TTS is speaking
        var startedResult: Bool?
        var beforeStartCalled = false
        coordinator.bargeInToDictation(
            voiceOutput: output,
            voiceInput: input,
            localeIdentifier: "en-US",
            owner: owner,
            onBeforeStart: { beforeStartCalled = true },
            onStarted: { startedResult = $0 }
        )
        XCTAssertEqual(firstProc.stopCount, 1)
        XCTAssertTrue(coordinator.hasPendingBargeIn)
        XCTAssertFalse(beforeStartCalled, "Must wait until speech exits and releases audio lease")
        XCTAssertFalse(input.isAttemptActive)

        // 3. Speech child finishes -> lease released -> dictation starts cleanly!
        firstProc.finish(error: nil)
        XCTAssertFalse(output.isBusy)
        XCTAssertFalse(coordinator.hasPendingBargeIn)
        XCTAssertTrue(beforeStartCalled)
        XCTAssertEqual(startedResult, true)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(input.isRecording)
        XCTAssertEqual(captures.count, 1)
        input.cancel(owner: owner)

        // 4. Test interruptAndSpeak replaces active speech cleanly after lease release
        output.speak("Old announcement", localeIdentifier: "en-US", owner: owner)
        let oldProc = try XCTUnwrap(activeProcess)
        output.interruptAndSpeak("New urgent status", localeIdentifier: "en-US", owner: owner)
        XCTAssertEqual(oldProc.stopCount, 1)
        XCTAssertEqual(spokenTexts, ["First response", "Old announcement"])
        oldProc.finish(error: nil)
        XCTAssertEqual(spokenTexts, ["First response", "Old announcement", "New urgent status"])
        XCTAssertTrue(output.isBusy)
        let newProc = try XCTUnwrap(activeProcess)
        newProc.finish(error: nil)
        XCTAssertFalse(output.isBusy)

        // 5. Cancelled pending barge-in never starts late dictation when speech exits
        output.speak("Another message", localeIdentifier: "en-US", owner: owner)
        let lateProc = try XCTUnwrap(activeProcess)
        var lateStarted = false
        coordinator.bargeInToDictation(
            voiceOutput: output,
            voiceInput: input,
            localeIdentifier: "en-US",
            owner: owner,
            onStarted: { if $0 { lateStarted = true } }
        )
        coordinator.cancelPending()
        lateProc.finish(error: nil)
        XCTAssertFalse(lateStarted)
        XCTAssertFalse(input.isAttemptActive)
    }

    func testCancelledOperationsAndStreamingDraftNeverSpeakLate() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let dir = try tempDir()

        // Gate that suspends scripted local inference until explicitly resumed
        let gate = SuspendedVoiceInference()
        let client = ACTAAIClient(
            config: ACTAAIConfiguration(mode: .mlxInProcess),
            transport: { _ in
                XCTFail("Voice conversation must stay 100% local without network fallback")
                throw URLError(.notConnectedToInternet)
            },
            keyProvider: { _ in nil },
            localAgentInference: { _, _ in
                await gate.waitForReply()
            }
        )

        var config = WallConfiguration()
        config.cameras = [Camera(name: "Front", substream: "rtsp://127.0.0.1:8554/front", enabled: false)]
        try ConfigurationStore.save(config, to: dir.appendingPathComponent("cameras.json"))
        try ModelSelectionPreferences(enabled: []).save(to: dir.appendingPathComponent("model-preferences.json"))
        var prefs = CameraFeaturePreferences(enabledFeatures: [])
        prefs.allowVoiceInput = true
        try CameraFeaturePreferencesStore.save(prefs, to: dir.appendingPathComponent("features.json"))
        var ai = VLMPreferences()
        ai.actaBackendMode = .mlxInProcess
        try VLMStore.save(ai, to: dir.appendingPathComponent("vlm.json"))

        let model = WallModel(
            configURL: dir.appendingPathComponent("cameras.json"),
            workerMode: false,
            poseModelURL: dir.appendingPathComponent("fake-pose.mlmodel"),
            trackingStoreURL: dir.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(
                preferencesURL: dir.appendingPathComponent("features.json"),
                databaseURL: dir.appendingPathComponent("features.sqlite")
            ),
            analyticsDirectoryURL: dir.appendingPathComponent("analytics"),
            agentClient: client,
            cameraMemoryStore: CameraMemoryStore(url: dir.appendingPathComponent("frames")),
            operationsWatchURL: dir.appendingPathComponent("watches.json"),
            missionStoreURL: dir.appendingPathComponent("missions.json"),
            cameraCredentialStore: ACTAIsolatedCredentials(),
            operationsPreferencesURL: dir.appendingPathComponent("operations.json"),
            alertClipStore: CriticalAlertClipStore(url: dir.appendingPathComponent("clips")),
            languageSettings: LanguageSettings(storage: InMemoryLanguageStorage()),
            monitorHistoryURL: dir.appendingPathComponent("monitor.json"),
            analyticsModelDiscovery: AnalyticsModelDiscovery(
                modelURL: { _ in nil },
                integrity: { _ in (hash: "synthetic", sizeBytes: 0) }
            )
        )
        defer { model.shutdown() }

        let voiceOwner = UUID()
        let submitted = model.askACTAAgent(question: "Status of all cameras", input: .voice, voiceAnswerOwner: voiceOwner)
        XCTAssertTrue(submitted)
        XCTAssertTrue(model.actaAgentBusy)
        XCTAssertNil(model.actaVoiceAnswer, "Streaming / in-flight request must never emit a spoken answer before completion")

        // Wait until inference is suspended inside the agent loop, then cancel
        let deadline = Date().addingTimeInterval(3)
        while !(await gate.isWaiting), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        model.cancelACTAAgent()
        XCTAssertFalse(model.actaAgentBusy)
        XCTAssertNil(model.actaAnswerPreview)

        // Release late response and confirm it is fenced and never emitted as actaVoiceAnswer
        await gate.resume(with: #"{"answerMarkdown":"Late unrequested speech","confidence":0.9}"#)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(model.actaVoiceAnswer, "Cancelled voice request must never speak a late arrival")
    }

    func testConfirmationDialogueFourOutcomesAndTraceableOperationID() async throws {
        let opID = UUID()
        for locale in ["en-US", "ru-RU", "he-IL"] {
            let messages = [
                LocalVoiceReviewStatus.message(outcome: .executedVerified, operationID: opID, localeIdentifier: locale),
                LocalVoiceReviewStatus.message(outcome: .executedUnverified, operationID: opID, localeIdentifier: locale),
                LocalVoiceReviewStatus.message(outcome: .rejected, operationID: opID, localeIdentifier: locale),
                LocalVoiceReviewStatus.message(outcome: .failed, operationID: opID, localeIdentifier: locale)
            ]
            // All 4 outcomes are distinct and carry the exact traceable operation UUID
            XCTAssertEqual(Set(messages).count, 4, "All 4 outcomes must have distinct spoken messages for \(locale)")
            for msg in messages {
                XCTAssertTrue(msg.contains(opID.uuidString), "Missing operation ID in \(locale): \(msg)")
            }

            let prompt = LocalVoiceReviewStatus.promptAnnouncement(
                actionID: "camera.remove",
                operationID: opID,
                localeIdentifier: locale
            )
            XCTAssertTrue(prompt.contains(String(opID.uuidString.prefix(8))))
            XCTAssertTrue(prompt.contains("camera remove"))
        }

        // Verify outcome classification matches executedVerified / executedUnverified / rejected / failed
        XCTAssertEqual(
            LocalVoiceReviewOutcome.classify(result: ACTAActionResult(actionID: "a", success: true, summary: "ok", verified: true), approved: true),
            .executedVerified
        )
        XCTAssertEqual(
            LocalVoiceReviewOutcome.classify(result: ACTAActionResult(actionID: "a", success: true, summary: "ok", verified: false), approved: true),
            .executedUnverified
        )
        XCTAssertEqual(
            LocalVoiceReviewOutcome.classify(result: ACTAActionResult(actionID: "a", success: false, summary: "rej", error: "OPERATOR_REJECTED"), approved: false),
            .rejected
        )
        XCTAssertEqual(
            LocalVoiceReviewOutcome.classify(result: ACTAActionResult(actionID: "a", success: false, summary: "fail", error: "FAILED"), approved: true),
            .failed
        )
    }

    func testDictationLanguagePersistenceAcrossNavigationBridgeReload() {
        let storage = InMemoryLocalVoiceLanguageStorage()
        let firstBridge = ACTANavigationBridge(voiceLanguageStorage: storage)
        XCTAssertEqual(firstBridge.voiceDictationLanguage, .interface)

        firstBridge.voiceDictationLanguage = .russian
        XCTAssertEqual(storage.readRawLanguage(), "russian")

        let reloadedBridge = ACTANavigationBridge(voiceLanguageStorage: storage)
        XCTAssertEqual(reloadedBridge.voiceDictationLanguage, .russian)

        reloadedBridge.voiceDictationLanguage = .hebrew
        let thirdBridge = ACTANavigationBridge(voiceLanguageStorage: storage)
        XCTAssertEqual(thirdBridge.voiceDictationLanguage, .hebrew)
    }
}

private actor SuspendedVoiceInference {
    private var continuation: CheckedContinuation<String, Never>?
    var isWaiting: Bool { continuation != nil }

    func waitForReply() async -> String {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume(with reply: String) {
        continuation?.resume(returning: reply)
        continuation = nil
    }
}
