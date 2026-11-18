import XCTest
@testable import CameraWall

@MainActor
final class LocalVoiceInputLifecycleTests: XCTestCase {
    private final class PermissionGate {
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

    private final class Hardware {
        var captures: [Capture] = []
        func make(_ locale: String, _ callback: @escaping @MainActor (LocalVoiceEvent) -> Void) -> any LocalVoiceCapture {
            let capture = Capture(callback: callback)
            captures.append(capture)
            return capture
        }
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
}
