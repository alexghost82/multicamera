import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class LocalVoiceLanguageTests: XCTestCase {
    private final class Capture: LocalVoiceCapture {
        let callback: @MainActor (LocalVoiceEvent) -> Void
        init(callback: @escaping @MainActor (LocalVoiceEvent) -> Void) { self.callback = callback }
        func finish() {}
        func cancel() {}
    }

    func testInterfaceAndExplicitLanguageSelection() {
        XCTAssertEqual(LocalVoiceLanguage.interface.localeIdentifier(interfaceLocale: Locale(identifier: "ru")), "ru")
        XCTAssertEqual(LocalVoiceLanguage.interface.localeIdentifier(interfaceLocale: Locale(identifier: "en")), "en")
        XCTAssertEqual(LocalVoiceLanguage.english.localeIdentifier(interfaceLocale: Locale(identifier: "ru")), "en-US")
        XCTAssertEqual(LocalVoiceLanguage.russian.localeIdentifier(interfaceLocale: Locale(identifier: "en")), "ru-RU")
        XCTAssertEqual(LocalVoiceLanguage.hebrew.localeIdentifier(interfaceLocale: Locale(identifier: "en")), "he-IL")
    }

    func testSelectedLanguageReachesCapture() async throws {
        var capturedLocale: String?
        let voice = LocalVoiceInput(speechPermission: { true }, microphonePermission: { true },
                                    makeCapture: { locale, callback in
            capturedLocale = locale
            return Capture(callback: callback)
        })
        let selected = LocalVoiceLanguage.hebrew.localeIdentifier(interfaceLocale: Locale(identifier: "en"))
        let task = try XCTUnwrap(voice.start(localeIdentifier: selected))
        await task.value
        XCTAssertEqual(capturedLocale, "he-IL")
        XCTAssertTrue(voice.isRecording)
        voice.cancel()
    }

    func testUnavailableOfflineLanguageFailsBeforeRequestingPermissions() async throws {
        var checkedLocale: String?
        var permissionRequests = 0
        var captureRequests = 0
        let voice = LocalVoiceInput(
            speechPermission: { permissionRequests += 1; return true },
            microphonePermission: { permissionRequests += 1; return true },
            makeCapture: { _, callback in
                captureRequests += 1
                return Capture(callback: callback)
            },
            checkLanguageAvailability: { locale in
                checkedLocale = locale
                throw NSError(domain: "SyntheticOfflineAvailability", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Offline language unavailable"])
            })
        let task = try XCTUnwrap(voice.start(localeIdentifier: "he-IL"))
        await task.value
        XCTAssertEqual(checkedLocale, "he-IL")
        XCTAssertEqual(permissionRequests, 0)
        XCTAssertEqual(captureRequests, 0)
        XCTAssertEqual(voice.errorMessage, "Offline language unavailable")
        XCTAssertFalse(voice.isBusy)
    }

    func testVoiceReviewRequiresExplicitStopOwnerAndExactChallenge() async throws {
        var capture: Capture?
        let voice = LocalVoiceInput(speechPermission: { true }, microphonePermission: { true },
                                    makeCapture: { _, callback in
            let current = Capture(callback: callback)
            capture = current
            return current
        })
        let challenge = LocalVoiceReviewChallenge(localeIdentifier: "en-US", permissionRevision: voice.permissionRevision)
        let expected = "\(challenge.phrase) \(challenge.code)"
        let task = try XCTUnwrap(voice.start(localeIdentifier: "en-US", owner: challenge.owner))
        await task.value
        let source = try XCTUnwrap(capture)
        source.callback(.transcript(expected, isFinal: false))
        XCTAssertNil(voice.finalTranscript)
        voice.finishAndWaitForFinal(owner: challenge.owner)
        source.callback(.transcript(expected, isFinal: true))
        let final = try XCTUnwrap(voice.finalTranscript)
        XCTAssertTrue(challenge.matches(final))
        XCTAssertFalse(challenge.matches(LocalVoiceFinalTranscript(owner: UUID(), text: expected, manuallyFinished: true)))
        XCTAssertFalse(challenge.matches(LocalVoiceFinalTranscript(owner: challenge.owner, text: expected, manuallyFinished: false)))
        XCTAssertFalse(challenge.matches(LocalVoiceFinalTranscript(owner: challenge.owner, text: "confirm 0000", manuallyFinished: true)))
        XCTAssertFalse(challenge.matches(LocalVoiceFinalTranscript(owner: challenge.owner, text: "yes \(challenge.code)", manuallyFinished: true)))

        let next = LocalVoiceReviewChallenge(localeIdentifier: "ru-RU", permissionRevision: voice.permissionRevision)
        let second = try XCTUnwrap(voice.start(localeIdentifier: "ru-RU", owner: next.owner))
        await second.value
        voice.cancel(owner: next.owner)
        capture?.callback(.transcript("\(next.phrase) \(next.code)", isFinal: true))
        XCTAssertNil(voice.finalTranscript)
    }

    func testNoiseAndAmbiguousPhrasesCannotMatchAConfirmation() {
        for locale in ["en-US", "ru-RU", "he-IL"] {
            let challenge = LocalVoiceReviewChallenge(localeIdentifier: locale, permissionRevision: UUID())
            func matches(_ text: String) -> Bool {
                challenge.matches(LocalVoiceFinalTranscript(owner: challenge.owner, text: text, manuallyFinished: true))
            }
            XCTAssertTrue(matches("  \(challenge.phrase.uppercased())  \(challenge.code)  "))
            for text in [
                "noise \(challenge.phrase) \(challenge.code)",
                "\(challenge.phrase) \(challenge.code) noise",
                "\(challenge.phrase) \(challenge.code) \(challenge.code)",
                "\(challenge.phrase), \(challenge.code)",
                "\(challenge.phrase) \(challenge.code.dropLast())",
                "\(challenge.phrase)\u{200B} \(challenge.code)"
            ] {
                XCTAssertFalse(matches(text), "\(locale): \(text)")
            }
        }
    }

    func testCancellationAndPanelStopInvalidateFinishedTranscript() async throws {
        var capture: Capture?
        let voice = LocalVoiceInput(speechPermission: { true }, microphonePermission: { true },
                                    makeCapture: { _, callback in
            let source = Capture(callback: callback)
            capture = source
            return source
        })
        let owner = UUID()
        let task = try XCTUnwrap(voice.start(localeIdentifier: "en", owner: owner))
        await task.value
        voice.finishAndWaitForFinal(owner: owner)
        try XCTUnwrap(capture).callback(.transcript("confirm 1234", isFinal: true))
        XCTAssertNotNil(voice.finalTranscript)
        voice.cancel(owner: UUID())
        XCTAssertNotNil(voice.finalTranscript)
        voice.cancel(owner: owner)
        XCTAssertNil(voice.finalTranscript)

        let second = try XCTUnwrap(voice.start(localeIdentifier: "en", owner: owner))
        await second.value
        voice.finishAndWaitForFinal(owner: owner)
        try XCTUnwrap(capture).callback(.transcript("confirm 5678", isFinal: true))
        XCTAssertNotNil(voice.finalTranscript)
        voice.stop()
        XCTAssertNil(voice.finalTranscript)
    }

    func testRecognitionErrorTakesPrecedenceOverSimultaneousFinalResult() async throws {
        var capture: Capture?
        let voice = LocalVoiceInput(speechPermission: { true }, microphonePermission: { true },
                                    makeCapture: { _, callback in
            let source = Capture(callback: callback)
            capture = source
            return source
        })
        let owner = UUID()
        let task = try XCTUnwrap(voice.start(localeIdentifier: "en", owner: owner))
        await task.value
        voice.finishAndWaitForFinal(owner: owner)
        let event = try XCTUnwrap(LocalVoiceEvent.recognitionResult(
            text: "confirm 1234", isFinal: true, error: "recognition failed"))
        try XCTUnwrap(capture).callback(event)
        XCTAssertEqual(voice.errorMessage, "recognition failed")
        XCTAssertNil(voice.finalTranscript)
        XCTAssertFalse(voice.isBusy)
        XCTAssertNil(LocalVoiceEvent.recognitionResult(text: nil, isFinal: false, error: nil))
    }
}
