import XCTest
import Combine
import CameraCore
@testable import CameraWall

@MainActor
final class LocalVoiceInputLifecycleTests: XCTestCase {
    @MainActor private final class PermissionGate {
        private(set) var requests: [CheckedContinuation<Bool, Never>?] = []
        private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

        func request() async -> Bool {
            await withCheckedContinuation { continuation in
                requests.append(continuation)
                let ready = waiters.filter { requests.count >= $0.0 }
                waiters.removeAll { requests.count >= $0.0 }
                ready.forEach { $0.1.resume() }
            }
        }

        func waitForRequests(_ count: Int) async {
            if requests.count >= count { return }
            await withCheckedContinuation { waiters.append((count, $0)) }
        }

        func resolve(_ index: Int, _ value: Bool) {
            let continuation = requests[index]
            requests[index] = nil
            continuation?.resume(returning: value)
        }
    }

    private final class Capture: LocalVoiceCapture {
        let callback: @MainActor (LocalVoiceEvent) -> Void
        var finishes = 0
        var cancels = 0

        init(callback: @escaping @MainActor (LocalVoiceEvent) -> Void) { self.callback = callback }
        func finish() { finishes += 1 }
        func cancel() { cancels += 1 }
    }

    @MainActor private final class Hardware {
        var captures: [Capture] = []
        func make(_ locale: String, _ callback: @escaping @MainActor (LocalVoiceEvent) -> Void) -> any LocalVoiceCapture {
            let capture = Capture(callback: callback)
            captures.append(capture)
            return capture
        }
    }

    func testCancelledDictationRestoresDraftWithoutDiscardingManualEdits() async throws {
        let hardware = Hardware()
        let voice = LocalVoiceInput(speechPermission: { true },
            microphonePermission: { true }, makeCapture: hardware.make)
        let task = try XCTUnwrap(voice.start(localeIdentifier: "en"))
        await task.value
        let capture = try XCTUnwrap(hardware.captures.first)
        var draft = LocalVoiceDraft(originalText: "Original question", originallyUsedVoice: true)
        capture.callback(.transcript("partial speech", isFinal: false))
        let rendered = draft.render(voice.transcript)
        XCTAssertEqual(rendered, "Original question partial speech")
        XCTAssertTrue(draft.canRestore(rendered))
        XCTAssertTrue(draft.originallyUsedVoice)
        XCTAssertFalse(draft.canRestore(rendered + " manually edited"))

        voice.cancel()
        capture.callback(.transcript("late speech", isFinal: true))
        XCTAssertEqual(capture.cancels, 1)
        XCTAssertFalse(voice.isBusy)
        XCTAssertEqual(voice.transcript, "partial speech")
    }

    func testFinalTranscriptKeepsItsOwnerUntilNewAttemptOrCancellation() async throws {
        let hardware = Hardware()
        let voice = LocalVoiceInput(speechPermission: { true },
            microphonePermission: { true }, makeCapture: hardware.make)
        let firstOwner = UUID(), secondOwner = UUID()
        let first = try XCTUnwrap(voice.start(localeIdentifier: "en", owner: firstOwner))
        await first.value
        let oldCapture = try XCTUnwrap(hardware.captures.first)
        oldCapture.callback(.transcript("final words", isFinal: true))
        XCTAssertFalse(voice.isRecording)
        XCTAssertEqual(voice.transcript, "final words")
        XCTAssertEqual(voice.transcriptOwner, firstOwner)

        let second = try XCTUnwrap(voice.start(localeIdentifier: "en", owner: secondOwner))
        await second.value
        XCTAssertNil(voice.transcriptOwner)
        oldCapture.callback(.transcript("late", isFinal: true))
        XCTAssertNil(voice.transcriptOwner)
        let newCapture = try XCTUnwrap(hardware.captures.last)
        newCapture.callback(.transcript("partial", isFinal: false))
        XCTAssertEqual(voice.transcriptOwner, secondOwner)
        voice.cancel()
        XCTAssertNil(voice.transcriptOwner)
    }

    func testManualStopWaitsForFinalTranscriptAndAllowsCancellation() async throws {
        let hardware = Hardware()
        let voice = LocalVoiceInput(speechPermission: { true },
            microphonePermission: { true }, makeCapture: hardware.make)
        let owner = UUID()
        let first = try XCTUnwrap(voice.start(localeIdentifier: "en", owner: owner))
        await first.value
        let capture = try XCTUnwrap(hardware.captures.first)
        capture.callback(.transcript("partial", isFinal: false))
        voice.finishAndWaitForFinal(owner: UUID())
        XCTAssertTrue(voice.isRecording)
        voice.finishAndWaitForFinal(owner: owner)
        XCTAssertTrue(voice.isBusy)
        XCTAssertTrue(voice.isFinalizing)
        XCTAssertFalse(voice.isRecording)
        XCTAssertEqual(capture.finishes, 1)
        capture.callback(.transcript("final result", isFinal: true))
        XCTAssertFalse(voice.isBusy)
        XCTAssertFalse(voice.isFinalizing)
        XCTAssertEqual(voice.transcript, "final result")
        XCTAssertEqual(voice.transcriptOwner, owner)
        XCTAssertEqual(capture.finishes, 1)

        let second = try XCTUnwrap(voice.start(localeIdentifier: "en", owner: owner))
        await second.value
        let secondCapture = try XCTUnwrap(hardware.captures.last)
        voice.finishAndWaitForFinal(owner: owner)
        voice.cancel()
        XCTAssertEqual(secondCapture.cancels, 1)
        secondCapture.callback(.transcript("late", isFinal: true))
        XCTAssertFalse(voice.isBusy)
        XCTAssertNil(voice.transcriptOwner)
        XCTAssertEqual(voice.transcript, "")

        let third = try XCTUnwrap(voice.start(localeIdentifier: "en", owner: owner))
        await third.value
        let thirdCapture = try XCTUnwrap(hardware.captures.last)
        voice.finishAndWaitForFinal(owner: owner)
        voice.stop(owner: owner)
        XCTAssertEqual(thirdCapture.cancels, 1)
        XCTAssertFalse(voice.isBusy)
    }

    func testManualStopTimeoutKeepsPartialAndReportsFailure() async throws {
        let hardware = Hardware()
        let voice = LocalVoiceInput(speechPermission: { true },
            microphonePermission: { true }, makeCapture: hardware.make)
        let owner = UUID()
        let task = try XCTUnwrap(voice.start(localeIdentifier: "en", owner: owner))
        await task.value
        let capture = try XCTUnwrap(hardware.captures.first)
        capture.callback(.transcript("partial", isFinal: false))
        voice.finishAndWaitForFinal(owner: owner)
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while voice.isBusy && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(voice.isBusy)
        XCTAssertEqual(voice.transcript, "partial")
        XCTAssertEqual(capture.cancels, 1)
        XCTAssertEqual(voice.errorMessage, "Final speech result timed out; check the partial transcript.")
    }

    func testLeavingChatCancelsPendingSpeechPermission() async throws {
        let speech = PermissionGate(), mic = PermissionGate(), hardware = Hardware()
        let voice = LocalVoiceInput(speechPermission: { await speech.request() },
            microphonePermission: { await mic.request() }, makeCapture: hardware.make)
        let state = ACTACanvasFilterState(analysisVoiceInput: voice)
        let task = try XCTUnwrap(voice.start(localeIdentifier: "en"))
        await speech.waitForRequests(1)
        XCTAssertTrue(state.analysisVoiceBusy)

        state.selectAnalysisSectionFromGUI(.alerts)
        XCTAssertFalse(state.analysisVoiceBusy)
        speech.resolve(0, true)
        await task.value
        XCTAssertEqual(state.analysisSection, .alerts)
        XCTAssertEqual(mic.requests.count, 0)
        XCTAssertTrue(hardware.captures.isEmpty)
        XCTAssertNil(voice.errorMessage)
    }

    func testCloseDuringMicrophonePermissionCannotClobberNewAttempt() async throws {
        let mic = PermissionGate(), hardware = Hardware()
        let voice = LocalVoiceInput(speechPermission: { true },
            microphonePermission: { await mic.request() }, makeCapture: hardware.make)
        let state = ACTACanvasFilterState(analysisVoiceInput: voice)
        let oldOwner = UUID(), newOwner = UUID()
        let old = try XCTUnwrap(voice.start(localeIdentifier: "en", owner: oldOwner))
        await mic.waitForRequests(1)
        state.stopAnalysisVoice()
        XCTAssertFalse(state.analysisVoiceBusy)
        let current = try XCTUnwrap(voice.start(localeIdentifier: "en", owner: newOwner))
        await mic.waitForRequests(2)
        voice.stop(owner: oldOwner)
        XCTAssertTrue(state.analysisVoiceBusy)

        mic.resolve(0, false)
        await old.value
        XCTAssertTrue(state.analysisVoiceBusy)
        XCTAssertNil(voice.errorMessage)
        XCTAssertTrue(hardware.captures.isEmpty)
        mic.resolve(1, true)
        await current.value
        XCTAssertTrue(voice.isRecording)
        XCTAssertTrue(state.analysisVoiceBusy)
        XCTAssertEqual(hardware.captures.count, 1)
        voice.stop(owner: newOwner)
        XCTAssertFalse(state.analysisVoiceBusy)
        XCTAssertEqual(hardware.captures[0].finishes, 1)
    }

    func testDelayedChatDisappearanceAfterReviewedSectionRoundTrip() async throws {
        let mic = PermissionGate(), hardware = Hardware()
        let voice = LocalVoiceInput(speechPermission: { true },
            microphonePermission: { await mic.request() }, makeCapture: hardware.make)
        let state = ACTACanvasFilterState(analysisVoiceInput: voice), bridge = ACTACanvasFilterBridge(voiceInputAllowed: true)
        bridge.attach(state)
        let oldOwner = state.analysisChatLifecycle
        let action = ACTAAnalysisSetSectionAction(bridge: bridge), context = ACTAActionContext(isConfirmed: true)
        let parameters = ["section": "alerts"]
        let review = try await action.prepareConfirmation(parameters: parameters, context: context)
        let result = try await action.executeConfirmed(parameters: parameters, context: context, snapshot: review.snapshot)
        XCTAssertTrue(result.success)

        state.selectAnalysisSectionFromGUI(.ask)
        let newOwner = state.analysisChatLifecycle
        XCTAssertNotEqual(oldOwner, newOwner)
        let task = try XCTUnwrap(voice.start(localeIdentifier: "en", owner: newOwner))
        await mic.waitForRequests(1)
        voice.stop(owner: oldOwner)
        XCTAssertTrue(voice.isAttemptActive)
        mic.resolve(0, true)
        await task.value
        XCTAssertTrue(voice.isRecording)
        XCTAssertEqual(hardware.captures.count, 1)
        voice.stop(owner: newOwner)
        XCTAssertEqual(hardware.captures[0].finishes, 1)
    }

    func testDelayedPanelDisappearanceCannotStopReopenedPanel() async throws {
        let hardware = Hardware()
        let voice = LocalVoiceInput(speechPermission: { true },
            microphonePermission: { true }, makeCapture: hardware.make)
        let state = ACTACanvasFilterState(analysisVoiceInput: voice)
        let oldOwner = state.analysisChatLifecycle
        state.invalidateAnalysisChatLifecycle()
        state.stopAnalysisVoice()
        let newOwner = state.analysisChatLifecycle
        XCTAssertNotEqual(oldOwner, newOwner)
        let task = try XCTUnwrap(voice.start(localeIdentifier: "en", owner: newOwner))
        await task.value
        voice.stop(owner: oldOwner)
        XCTAssertTrue(voice.isRecording)
        XCTAssertEqual(hardware.captures[0].finishes, 0)
        voice.stop(owner: newOwner)
        XCTAssertFalse(voice.isBusy)
        XCTAssertEqual(hardware.captures[0].finishes, 1)
    }

    func testStopBeforeTaskRunsAndCancelPendingPermission() async throws {
        let speech = PermissionGate(), hardware = Hardware()
        let voice = LocalVoiceInput(speechPermission: { await speech.request() },
            microphonePermission: { XCTFail("Unexpected microphone permission"); return true }, makeCapture: hardware.make)
        let first = try XCTUnwrap(voice.start(localeIdentifier: "en"))
        voice.stop()
        await first.value
        XCTAssertEqual(speech.requests.count, 0)
        XCTAssertFalse(voice.isBusy)

        let second = try XCTUnwrap(voice.start(localeIdentifier: "en"))
        await speech.waitForRequests(1)
        voice.cancel()
        speech.resolve(0, true)
        await second.value
        XCTAssertFalse(voice.isBusy)
        XCTAssertFalse(voice.isRecording)
        XCTAssertTrue(hardware.captures.isEmpty)
    }

    func testStopDuringMicrophonePermissionRejectsLateGrant() async throws {
        let mic = PermissionGate(), hardware = Hardware()
        let voice = LocalVoiceInput(speechPermission: { true },
            microphonePermission: { await mic.request() }, makeCapture: hardware.make)
        let state = ACTACanvasFilterState(analysisVoiceInput: voice)
        let task = try XCTUnwrap(voice.start(localeIdentifier: "en"))
        await mic.waitForRequests(1)
        state.stopAnalysisVoice()
        mic.resolve(0, true)
        await task.value
        XCTAssertFalse(state.analysisVoiceBusy)
        XCTAssertFalse(voice.isRecording)
        XCTAssertTrue(hardware.captures.isEmpty)
    }

    func testRevokingPreferenceCancelsPendingPermissionsAndBlocksRestart() async throws {
        for awaitingSpeech in [true, false] {
            let speech = PermissionGate(), mic = PermissionGate(), hardware = Hardware()
            let voice = LocalVoiceInput(speechPermission: {
                awaitingSpeech ? await speech.request() : true
            }, microphonePermission: { await mic.request() }, makeCapture: hardware.make)
            let bridge = ACTACanvasFilterBridge(voiceInputAllowed: true)
            let state = ACTACanvasFilterState(analysisVoiceInput: voice)
            bridge.attach(state)
            let task = try XCTUnwrap(voice.start(localeIdentifier: "en"))
            if awaitingSpeech { await speech.waitForRequests(1) }
            else { await mic.waitForRequests(1) }
            bridge.setVoiceInputAllowed(false)
            XCTAssertFalse(voice.isBusy)
            XCTAssertNil(voice.start(localeIdentifier: "en"))
            if awaitingSpeech { speech.resolve(0, true) }
            else { mic.resolve(0, true) }
            await task.value
            XCTAssertEqual(mic.requests.count, awaitingSpeech ? 0 : 1)
            XCTAssertTrue(hardware.captures.isEmpty)
            XCTAssertNil(voice.errorMessage)
        }
    }

    func testAttachWithDisabledPreferenceCancelsExistingAttempt() async throws {
        let mic = PermissionGate(), hardware = Hardware()
        let voice = LocalVoiceInput(speechPermission: { true },
            microphonePermission: { await mic.request() }, makeCapture: hardware.make)
        let task = try XCTUnwrap(voice.start(localeIdentifier: "en"))
        await mic.waitForRequests(1)
        let bridge = ACTACanvasFilterBridge()
        let state = ACTACanvasFilterState(analysisVoiceInput: voice)
        bridge.attach(state)
        XCTAssertFalse(voice.isBusy)
        XCTAssertNil(voice.start(localeIdentifier: "en"))
        mic.resolve(0, true)
        await task.value
        XCTAssertTrue(hardware.captures.isEmpty)
    }

    func testRevocationCancelsAllOwnedWindowsButNotAnotherModelAndIgnoresOldCallbacks() async throws {
        let firstHardware = Hardware(), secondHardware = Hardware(), otherHardware = Hardware()
        func makeVoice(_ hardware: Hardware) -> LocalVoiceInput {
            LocalVoiceInput(speechPermission: { true }, microphonePermission: { true }, makeCapture: hardware.make)
        }
        let first = makeVoice(firstHardware), second = makeVoice(secondHardware), other = makeVoice(otherHardware)
        let bridge = ACTACanvasFilterBridge(voiceInputAllowed: true)
        let otherBridge = ACTACanvasFilterBridge(voiceInputAllowed: true)
        let firstState = ACTACanvasFilterState(analysisVoiceInput: first)
        let secondState = ACTACanvasFilterState(analysisVoiceInput: second)
        let otherState = ACTACanvasFilterState(analysisVoiceInput: other)
        bridge.attach(firstState)
        bridge.attach(secondState)
        otherBridge.attach(otherState)
        let oldOwner = UUID(), newOwner = UUID()
        let firstTask = try XCTUnwrap(first.start(localeIdentifier: "en", owner: oldOwner))
        let secondTask = try XCTUnwrap(second.start(localeIdentifier: "en"))
        let otherTask = try XCTUnwrap(other.start(localeIdentifier: "en"))
        await firstTask.value
        await secondTask.value
        await otherTask.value
        let oldCapture = try XCTUnwrap(firstHardware.captures.first)
        bridge.setVoiceInputAllowed(false)
        XCTAssertFalse(first.isBusy)
        XCTAssertFalse(second.isBusy)
        XCTAssertEqual(oldCapture.cancels, 1)
        XCTAssertEqual(secondHardware.captures.first?.cancels, 1)
        XCTAssertTrue(other.isRecording)
        XCTAssertEqual(otherHardware.captures.first?.cancels, 0)
        oldCapture.callback(.transcript("late", isFinal: true))
        oldCapture.callback(.error("late"))
        XCTAssertEqual(first.transcript, "")
        XCTAssertNil(first.errorMessage)
        bridge.setVoiceInputAllowed(true)
        let newTask = try XCTUnwrap(first.start(localeIdentifier: "en", owner: newOwner))
        await newTask.value
        first.stop(owner: oldOwner)
        oldCapture.callback(.transcript("stale", isFinal: true))
        oldCapture.callback(.error("stale"))
        XCTAssertTrue(first.isRecording)
        XCTAssertEqual(first.transcript, "")
        XCTAssertNil(first.errorMessage)
        first.cancel()
        other.cancel()
    }

    func testPreferenceRevocationDuringBusyPublicationCancelsBeforePermission() async throws {
        let hardware = Hardware()
        var permissionCalls = 0
        let voice = LocalVoiceInput(speechPermission: { permissionCalls += 1; return true },
                                    microphonePermission: { true }, makeCapture: hardware.make)
        let bridge = ACTACanvasFilterBridge(voiceInputAllowed: true)
        let state = ACTACanvasFilterState(analysisVoiceInput: voice)
        bridge.attach(state)
        let subscription = voice.$isBusy.dropFirst().sink { busy in
            if busy { bridge.setVoiceInputAllowed(false) }
        }
        let task = try XCTUnwrap(voice.start(localeIdentifier: "en"))
        await task.value
        XCTAssertFalse(voice.isBusy)
        XCTAssertNil(voice.start(localeIdentifier: "en"))
        XCTAssertEqual(permissionCalls, 0)
        XCTAssertTrue(hardware.captures.isEmpty)
        withExtendedLifetime(subscription) {}
    }

    func testRevocationClosesAllWindowGatesBeforePublishingCancellation() async throws {
        let firstHardware = Hardware(), secondHardware = Hardware(), thirdHardware = Hardware()
        func makeVoice(_ hardware: Hardware) -> LocalVoiceInput {
            LocalVoiceInput(speechPermission: { true }, microphonePermission: { true }, makeCapture: hardware.make)
        }
        let first = makeVoice(firstHardware), second = makeVoice(secondHardware), third = makeVoice(thirdHardware)
        let bridge = ACTACanvasFilterBridge(voiceInputAllowed: true)
        let firstState = ACTACanvasFilterState(analysisVoiceInput: first)
        let secondState = ACTACanvasFilterState(analysisVoiceInput: second)
        let thirdState = ACTACanvasFilterState(analysisVoiceInput: third)
        bridge.attach(firstState)
        bridge.attach(secondState)
        bridge.attach(thirdState)
        let firstTask = try XCTUnwrap(first.start(localeIdentifier: "en"))
        let secondTask = try XCTUnwrap(second.start(localeIdentifier: "en"))
        await firstTask.value
        await secondTask.value
        let secondCapture = try XCTUnwrap(secondHardware.captures.first)
        var attempted = false
        let subscription = first.$isRecording.dropFirst().sink { recording in
            if !recording {
                attempted = true
                secondCapture.callback(.transcript("late", isFinal: true))
                XCTAssertNil(third.start(localeIdentifier: "en"))
            }
        }
        bridge.setVoiceInputAllowed(false)
        XCTAssertTrue(attempted)
        XCTAssertEqual(second.transcript, "")
        XCTAssertEqual(secondCapture.cancels, 1)
        XCTAssertTrue(thirdHardware.captures.isEmpty)
        withExtendedLifetime(subscription) {}
    }

    func testOldRevocationDoesNotCancelNewAttemptAfterReenable() async throws {
        let firstHardware = Hardware(), secondHardware = Hardware()
        let first = LocalVoiceInput(speechPermission: { true }, microphonePermission: { true }, makeCapture: firstHardware.make)
        let second = LocalVoiceInput(speechPermission: { true }, microphonePermission: { true }, makeCapture: secondHardware.make)
        let bridge = ACTACanvasFilterBridge(voiceInputAllowed: true)
        let firstState = ACTACanvasFilterState(analysisVoiceInput: first)
        let secondState = ACTACanvasFilterState(analysisVoiceInput: second)
        bridge.attach(firstState)
        bridge.attach(secondState)
        let oldTask = try XCTUnwrap(first.start(localeIdentifier: "en"))
        await oldTask.value
        var newTask: Task<Void, Never>?
        let subscription = first.$isRecording.dropFirst().sink { recording in
            if !recording {
                bridge.setVoiceInputAllowed(true)
                newTask = second.start(localeIdentifier: "en")
            }
        }
        bridge.setVoiceInputAllowed(false)
        await newTask?.value
        XCTAssertNotNil(newTask)
        XCTAssertTrue(second.isRecording)
        XCTAssertEqual(secondHardware.captures.first?.cancels, 0)
        subscription.cancel()
        second.cancel()
    }

    func testMicrophoneDenialAndCaptureFailureClearBusyForRetry() async throws {
        let mic = PermissionGate()
        var captureCalls = 0
        let voice = LocalVoiceInput(speechPermission: { true },
            microphonePermission: { await mic.request() }, makeCapture: { _, _ in
                captureCalls += 1
                throw NSError(domain: "SyntheticCaptureFailure", code: 1)
            })
        let denied = try XCTUnwrap(voice.start(localeIdentifier: "en"))
        await mic.waitForRequests(1)
        XCTAssertNil(voice.start(localeIdentifier: "en"))
        mic.resolve(0, false)
        await denied.value
        XCTAssertFalse(voice.isBusy)
        XCTAssertNotNil(voice.errorMessage)
        XCTAssertEqual(captureCalls, 0)

        let failed = try XCTUnwrap(voice.start(localeIdentifier: "en"))
        await mic.waitForRequests(2)
        mic.resolve(1, true)
        await failed.value
        XCTAssertFalse(voice.isBusy)
        XCTAssertFalse(voice.isRecording)
        XCTAssertNotNil(voice.errorMessage)
        XCTAssertEqual(captureCalls, 1)
    }

    func testDenialsAndLateCaptureCallbacksDoNotAffectNextAttempt() async throws {
        let speech = PermissionGate(), hardware = Hardware()
        let voice = LocalVoiceInput(speechPermission: { await speech.request() },
            microphonePermission: { true }, makeCapture: hardware.make)
        let denied = try XCTUnwrap(voice.start(localeIdentifier: "en"))
        await speech.waitForRequests(1)
        speech.resolve(0, false)
        await denied.value
        XCTAssertFalse(voice.isBusy)
        XCTAssertNotNil(voice.errorMessage)
        XCTAssertTrue(hardware.captures.isEmpty)

        let first = try XCTUnwrap(voice.start(localeIdentifier: "en"))
        await speech.waitForRequests(2)
        speech.resolve(1, true)
        await first.value
        XCTAssertNil(voice.errorMessage)
        XCTAssertTrue(voice.isRecording)
        let oldCapture = try XCTUnwrap(hardware.captures.first)
        oldCapture.callback(.transcript("first", isFinal: false))
        XCTAssertEqual(voice.transcript, "first")
        voice.stop()
        XCTAssertEqual(oldCapture.finishes, 1)
        let second = try XCTUnwrap(voice.start(localeIdentifier: "en"))
        await speech.waitForRequests(3)
        oldCapture.callback(.error("late"))
        oldCapture.callback(.transcript("stale", isFinal: true))
        XCTAssertTrue(voice.isBusy)
        XCTAssertNil(voice.errorMessage)
        XCTAssertEqual(voice.transcript, "")
        speech.resolve(2, true)
        await second.value
        let newCapture = hardware.captures[1]
        oldCapture.callback(.error("later"))
        XCTAssertTrue(voice.isRecording)
        newCapture.callback(.transcript("final", isFinal: true))
        XCTAssertEqual(voice.transcript, "final")
        XCTAssertFalse(voice.isBusy)
        XCTAssertEqual(newCapture.finishes, 1)
    }

    func testStopFromBusyWillSetCancelsAttemptBeforePermissions() async throws {
        let hardware = Hardware()
        var permissionCalls = 0
        let voice = LocalVoiceInput(speechPermission: { permissionCalls += 1; return true },
                                    microphonePermission: { true }, makeCapture: hardware.make)
        let subscription = voice.$isBusy.dropFirst().sink { busy in
            if busy { voice.stop() }
        }
        let task = try XCTUnwrap(voice.start(localeIdentifier: "en"))
        await task.value
        XCTAssertFalse(voice.isBusy)
        XCTAssertFalse(voice.isRecording)
        XCTAssertFalse(voice.isAttemptActive)
        XCTAssertEqual(permissionCalls, 0)
        XCTAssertTrue(hardware.captures.isEmpty)
        withExtendedLifetime(subscription) {}
    }

    func testSynchronousCaptureCallbackAndStopAreSerialized() async throws {
        var voice: LocalVoiceInput!
        var captures: [Capture] = []
        voice = LocalVoiceInput(speechPermission: { true }, microphonePermission: { true },
                               makeCapture: { _, callback in
            let capture = Capture(callback: callback)
            captures.append(capture)
            callback(.transcript("early", isFinal: true))
            voice.stop()
            return capture
        })
        let task = try XCTUnwrap(voice.start(localeIdentifier: "en"))
        await task.value
        XCTAssertEqual(voice.transcript, "early")
        XCTAssertFalse(voice.isBusy)
        XCTAssertFalse(voice.isRecording)
        XCTAssertFalse(voice.isAttemptActive)
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures[0].finishes, 1)
        XCTAssertEqual(captures[0].cancels, 0)
    }

    func testRestartFromEndPublicationCannotOverwriteOldTransition() async throws {
        let hardware = Hardware()
        let voice = LocalVoiceInput(speechPermission: { true }, microphonePermission: { true }, makeCapture: hardware.make)
        let task = try XCTUnwrap(voice.start(localeIdentifier: "en"))
        await task.value
        var nestedStart: Task<Void, Never>?
        let subscription = voice.$isRecording.dropFirst().sink { recording in
            if !recording { nestedStart = voice.start(localeIdentifier: "en") }
        }
        voice.stop()
        XCTAssertNil(nestedStart)
        XCTAssertFalse(voice.isBusy)
        let retry = try XCTUnwrap(voice.start(localeIdentifier: "en"))
        await retry.value
        XCTAssertTrue(voice.isRecording)
        XCTAssertEqual(hardware.captures.count, 2)
        voice.cancel()
        withExtendedLifetime(subscription) {}
    }
}
