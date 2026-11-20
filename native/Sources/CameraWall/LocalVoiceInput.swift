import AVFoundation
import Combine
import Foundation
import Speech

enum LocalVoiceEvent {
    case transcript(String, isFinal: Bool)
    case error(String)

    static func recognitionResult(text: String?, isFinal: Bool, error: String?) -> LocalVoiceEvent? {
        if let error { return .error(error) }
        guard let text else { return nil }
        return .transcript(text, isFinal: isFinal)
    }
}

struct LocalVoiceFinalTranscript: Equatable {
    let owner: UUID
    let text: String
    let manuallyFinished: Bool
}

struct LocalVoiceReviewChallenge {
    let owner: UUID
    let code: String
    let phrase: String
    let permissionRevision: UUID
    let reviewBinding: UUID?

    init(localeIdentifier: String, permissionRevision: UUID, reviewBinding: UUID? = nil) {
        owner = UUID()
        code = String(Int.random(in: 1000...9999))
        self.permissionRevision = permissionRevision
        self.reviewBinding = reviewBinding
        switch Locale(identifier: localeIdentifier).language.languageCode?.identifier {
        case "ru": phrase = "подтверждаю"
        case "he": phrase = "מאשר"
        default: phrase = "confirm"
        }
    }

    func matches(_ transcript: LocalVoiceFinalTranscript) -> Bool {
        guard transcript.owner == owner, transcript.manuallyFinished else { return false }
        let words = transcript.text.lowercased().split(whereSeparator: \.isWhitespace)
        return words.count == 2 && words[0] == phrase && words[1] == code
    }
}

enum LocalVoiceLanguage: String, CaseIterable, Identifiable {
    case interface, english, russian, hebrew

    var id: String { rawValue }

    var title: String {
        switch self {
        case .interface: return "Interface language"
        case .english: return "English (US)"
        case .russian: return "Russian (Russia)"
        case .hebrew: return "Hebrew (Israel)"
        }
    }

    func localeIdentifier(interfaceLocale: Locale) -> String {
        switch self {
        case .interface: return interfaceLocale.identifier
        case .english: return "en-US"
        case .russian: return "ru-RU"
        case .hebrew: return "he-IL"
        }
    }
}

struct LocalVoiceDraft {
    let originalText: String
    let originallyUsedVoice: Bool
    private(set) var lastRenderedText: String?

    init(originalText: String, originallyUsedVoice: Bool) {
        self.originalText = originalText
        self.originallyUsedVoice = originallyUsedVoice
    }

    mutating func render(_ transcript: String) -> String {
        let text = [originalText, transcript].filter { !$0.isEmpty }.joined(separator: " ")
        lastRenderedText = text
        return text
    }

    func canRestore(_ currentText: String) -> Bool {
        currentText == originalText || currentText == lastRenderedText
    }
}

@MainActor
protocol LocalVoiceCapture: AnyObject {
    func finish()
    func cancel()
}

@MainActor
final class LocalVoiceInput: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var isRecording = false
    @Published private(set) var isFinalizing = false
    @Published private(set) var transcript = ""
    @Published private(set) var finalTranscript: LocalVoiceFinalTranscript?
    @Published private(set) var errorMessage: String?
    private(set) var transcriptOwner: UUID?

    private let speechPermission: @MainActor () async -> Bool
    private let microphonePermission: @MainActor () async -> Bool
    private let makeCapture: @MainActor (String, @escaping @MainActor (LocalVoiceEvent) -> Void) throws -> any LocalVoiceCapture
    private let checkLanguageAvailability: @MainActor (String) throws -> Void
    private let acquireAudioLease: @MainActor () throws -> LocalVoiceAudioLease?
    private var audioLease: LocalVoiceAudioLease?
    private var attempt: UUID?
    private var owner: UUID?
    private var startTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var capture: (any LocalVoiceCapture)?
    private var transitioning = false
    private var pendingTransitions: [() -> Void] = []
    private var consumedReviewOwner: UUID?
    private var inputAllowed = true
    private(set) var permissionRevision = UUID()
    var isAttemptActive: Bool { attempt != nil }
    var isInputAllowed: Bool { inputAllowed }
    func isOwned(by owner: UUID) -> Bool { attempt != nil && self.owner == owner }
    private(set) var attemptRevision = UUID()

    convenience init() {
        self.init(
            speechPermission: { await LocalVoiceInput.requestSpeechAuthorization() },
            microphonePermission: { await LocalVoiceInput.requestMicrophoneAccess() },
            makeCapture: { try SystemVoiceCapture(localeIdentifier: $0, onEvent: $1) },
            checkLanguageAvailability: { _ = try SystemVoiceCapture.recognizer(localeIdentifier: $0) },
            acquireAudioLease: { try LocalVoiceAudioLease.acquire() }
        )
    }

    init(
        speechPermission: @escaping @MainActor () async -> Bool,
        microphonePermission: @escaping @MainActor () async -> Bool,
        makeCapture: @escaping @MainActor (String, @escaping @MainActor (LocalVoiceEvent) -> Void) throws -> any LocalVoiceCapture,
        checkLanguageAvailability: @escaping @MainActor (String) throws -> Void = { _ in },
        acquireAudioLease: @escaping @MainActor () throws -> LocalVoiceAudioLease? = { nil }
    ) {
        self.speechPermission = speechPermission
        self.microphonePermission = microphonePermission
        self.makeCapture = makeCapture
        self.checkLanguageAvailability = checkLanguageAvailability
        self.acquireAudioLease = acquireAudioLease
    }

    @discardableResult
    func start(localeIdentifier: String, owner: UUID = UUID()) -> Task<Void, Never>? {
        guard inputAllowed, !transitioning, attempt == nil else { return nil }
        var started: Task<Void, Never>?
        transition {
            started = self.startAttempt(localeIdentifier: localeIdentifier, owner: owner)
        }
        return started
    }

    private func startAttempt(localeIdentifier: String, owner: UUID) -> Task<Void, Never>? {
        transcriptOwner = nil
        finalTranscript = nil
        consumedReviewOwner = nil
        guard inputAllowed else { return nil }
        do {
            audioLease = try acquireAudioLease()
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
        let id = UUID()
        attempt = id
        attemptRevision = UUID()
        self.owner = owner
        isBusy = true
        transcript = ""
        errorMessage = nil
        let speechPermission = speechPermission
        let microphonePermission = microphonePermission
        let checkLanguageAvailability = checkLanguageAvailability
        startTask = Task { [weak self] in
            guard self?.isCurrent(id) == true else { return }
            do {
                try checkLanguageAvailability(localeIdentifier)
            } catch {
                self?.fail(id, message: error.localizedDescription)
                return
            }
            guard self?.isCurrent(id) == true else { return }
            let speechAllowed = await speechPermission()
            guard self?.isCurrent(id) == true else { return }
            guard speechAllowed else {
                self?.fail(id, message: "Speech recognition permission is required for local dictation.")
                return
            }
            let microphoneAllowed = await microphonePermission()
            guard let self, self.isCurrent(id) else { return }
            guard microphoneAllowed else {
                self.fail(id, message: "Microphone permission is required for local dictation.")
                return
            }
            self.transition { [self] in
                guard self.isCurrent(id) else { return }
                do {
                    self.capture = try self.makeCapture(localeIdentifier) { [weak self] event in
                        self?.receive(event, for: id)
                    }
                    self.isRecording = true
                    self.startTask = nil
                } catch {
                    self.failAttempt(id, message: error.localizedDescription)
                }
            }
        }
        return startTask!
    }

    func stop() {
        transition {
            self.endAttempt(cancelCapture: self.isFinalizing || self.attempt == nil)
        }
    }

    func stop(owner: UUID) {
        transition {
            if self.owner == owner {
                self.endAttempt(cancelCapture: self.isFinalizing)
            } else if self.attempt == nil, self.finalTranscript?.owner == owner {
                self.endAttempt(cancelCapture: true)
            }
        }
    }

    func finishAndWaitForFinal(owner: UUID) {
        transition { [self] in
            guard self.owner == owner, let id = self.attempt, !self.isFinalizing else { return }
            guard let capture = self.capture else {
                self.endAttempt(cancelCapture: true)
                return
            }
            self.isFinalizing = true
            self.isRecording = false
            capture.finish()
            self.finishTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                self?.fail(id, message: "Final speech result timed out; check the partial transcript.")
            }
        }
    }

    func cancel() {
        transition { self.endAttempt(cancelCapture: true) }
    }

    func cancel(owner: UUID) {
        transition {
            guard self.owner == owner || (self.attempt == nil && self.finalTranscript?.owner == owner) else { return }
            self.endAttempt(cancelCapture: true)
        }
    }

    func setInputAllowed(_ allowed: Bool) -> UUID? {
        inputAllowed = allowed
        if !allowed { permissionRevision = UUID() }
        return allowed ? nil : attempt
    }

    func cancelRevokedAttempt(_ id: UUID?) {
        guard let id else { return }
        transition {
            guard self.attempt == id else { return }
            self.endAttempt(cancelCapture: true)
        }
    }

    func consumeReviewTranscript(_ transcript: LocalVoiceFinalTranscript,
                                 challenge: LocalVoiceReviewChallenge) -> Bool {
        guard !transitioning, inputAllowed, permissionRevision == challenge.permissionRevision,
              finalTranscript == transcript, challenge.matches(transcript),
              consumedReviewOwner != transcript.owner else { return false }
        consumedReviewOwner = transcript.owner
        return true
    }

    private func isCurrent(_ id: UUID) -> Bool {
        inputAllowed && attempt == id && !Task.isCancelled
    }

    private func fail(_ id: UUID, message: String) {
        transition { self.failAttempt(id, message: message) }
    }

    private func failAttempt(_ id: UUID, message: String) {
        guard attempt == id else { return }
        errorMessage = message
        endAttempt(cancelCapture: true)
    }

    private func receive(_ event: LocalVoiceEvent, for id: UUID) {
        transition { self.receiveEvent(event, for: id) }
    }

    private func receiveEvent(_ event: LocalVoiceEvent, for id: UUID) {
        guard inputAllowed, attempt == id, isRecording || isFinalizing else { return }
        switch event {
        case let .transcript(text, isFinal):
            transcriptOwner = owner
            transcript = text
            if isFinal {
                let final = owner.map {
                    LocalVoiceFinalTranscript(owner: $0, text: text, manuallyFinished: isFinalizing)
                }
                finalTranscript = final
                endAttempt(cancelCapture: false)
            }
        case let .error(message):
            errorMessage = message
            endAttempt(cancelCapture: true)
        }
    }

    private func endAttempt(cancelCapture: Bool) {
        if attempt != nil { attemptRevision = UUID() }
        if cancelCapture {
            transcriptOwner = nil
            finalTranscript = nil
        }
        attempt = nil
        owner = nil
        startTask?.cancel()
        startTask = nil
        finishTask?.cancel()
        finishTask = nil
        let currentCapture = capture
        capture = nil
        let wasFinalizing = isFinalizing
        isRecording = false
        isFinalizing = false
        isBusy = false
        if cancelCapture { currentCapture?.cancel() }
        else if !wasFinalizing { currentCapture?.finish() }
        audioLease = nil
    }

    private func transition(_ operation: @escaping () -> Void) {
        if transitioning {
            pendingTransitions.append(operation)
            return
        }
        transitioning = true
        operation()
        while !pendingTransitions.isEmpty {
            pendingTransitions.removeFirst()()
        }
        transitioning = false
    }

    nonisolated static func mergeTranscript(_ transcript: String, with draft: String) -> String {
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return String(draft.prefix(2000)) }
        let prefix = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = prefix.isEmpty ? spoken : "\(prefix) \(spoken)"
        return String(combined.prefix(2000))
    }

    private static func requestSpeechAuthorization() async -> Bool {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current == .authorized }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    private static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        default:
            return false
        }
    }
}

private struct LocalVoiceCaptureError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
private final class SystemVoiceCapture: LocalVoiceCapture {
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    static func recognizer(localeIdentifier: String) throws -> SFSpeechRecognizer {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw LocalVoiceCaptureError(message: "On-device speech recognition is unavailable for this language.")
        }
        return recognizer
    }

    init(localeIdentifier: String, onEvent: @escaping @MainActor (LocalVoiceEvent) -> Void) throws {
        let recognizer = try Self.recognizer(localeIdentifier: localeIdentifier)
        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            throw LocalVoiceCaptureError(message: "The selected microphone has no audio input.")
        }
        do {
            if #available(macOS 27.0, *) {
                try input.__installTap(onBus: 0, bufferSize: 1024, format: format, error: ()) { buffer, _ in
                    request.append(buffer)
                }
            } else {
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                    request.append(buffer)
                }
            }
        } catch {
            throw LocalVoiceCaptureError(message: "Could not install the microphone input tap.")
        }
        let task = recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let message = error?.localizedDescription
            Task { @MainActor in
                if let event = LocalVoiceEvent.recognitionResult(text: text, isFinal: isFinal, error: message) {
                    onEvent(event)
                }
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            task.cancel()
            throw LocalVoiceCaptureError(message: "Could not start the microphone. Check its permission and input device.")
        }
        self.engine = engine
        self.request = request
        self.task = task
    }

    func finish() { cleanup(cancel: false) }
    func cancel() { cleanup(cancel: true) }

    private func cleanup(cancel: Bool) {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        if cancel {
            task?.cancel()
            task = nil
        } else {
            task?.finish()
        }
        engine = nil
        request = nil
    }
}
