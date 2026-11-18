import AVFoundation
import Combine
import Foundation
import Speech

enum LocalVoiceEvent {
    case transcript(String, isFinal: Bool)
    case error(String)
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
    @Published private(set) var transcript = ""
    @Published private(set) var errorMessage: String?

    private let speechPermission: @MainActor () async -> Bool
    private let microphonePermission: @MainActor () async -> Bool
    private let makeCapture: @MainActor (String, @escaping @MainActor (LocalVoiceEvent) -> Void) throws -> any LocalVoiceCapture
    private var attempt: UUID?
    private var owner: UUID?
    private var startTask: Task<Void, Never>?
    private var capture: (any LocalVoiceCapture)?

    init(
        speechPermission: @escaping @MainActor () async -> Bool = { await LocalVoiceInput.requestSpeechAuthorization() },
        microphonePermission: @escaping @MainActor () async -> Bool = { await LocalVoiceInput.requestMicrophoneAccess() },
        makeCapture: @escaping @MainActor (String, @escaping @MainActor (LocalVoiceEvent) -> Void) throws -> any LocalVoiceCapture = {
            try SystemVoiceCapture(localeIdentifier: $0, onEvent: $1)
        }
    ) {
        self.speechPermission = speechPermission
        self.microphonePermission = microphonePermission
        self.makeCapture = makeCapture
    }

    @discardableResult
    func start(localeIdentifier: String, owner: UUID = UUID()) -> Task<Void, Never>? {
        guard !isBusy else { return nil }
        let id = UUID()
        attempt = id
        self.owner = owner
        isBusy = true
        transcript = ""
        errorMessage = nil
        let speechPermission = speechPermission
        let microphonePermission = microphonePermission
        startTask = Task { [weak self] in
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
            do {
                self.capture = try self.makeCapture(localeIdentifier) { [weak self] event in
                    self?.receive(event, for: id)
                }
                self.isRecording = true
                self.startTask = nil
            } catch {
                self.fail(id, message: error.localizedDescription)
            }
        }
        return startTask
    }

    func stop() {
        endAttempt(cancelCapture: false)
    }

    func stop(owner: UUID) {
        guard self.owner == owner else { return }
        stop()
    }

    func cancel() {
        endAttempt(cancelCapture: true)
    }

    private func isCurrent(_ id: UUID) -> Bool {
        attempt == id && !Task.isCancelled
    }

    private func fail(_ id: UUID, message: String) {
        guard attempt == id else { return }
        errorMessage = message
        endAttempt(cancelCapture: true)
    }

    private func receive(_ event: LocalVoiceEvent, for id: UUID) {
        guard attempt == id, isRecording else { return }
        switch event {
        case let .transcript(text, isFinal):
            transcript = text
            if isFinal { endAttempt(cancelCapture: false) }
        case let .error(message):
            errorMessage = message
            endAttempt(cancelCapture: true)
        }
    }

    private func endAttempt(cancelCapture: Bool) {
        attempt = nil
        owner = nil
        startTask?.cancel()
        startTask = nil
        let currentCapture = capture
        capture = nil
        isRecording = false
        isBusy = false
        if cancelCapture { currentCapture?.cancel() }
        else { currentCapture?.finish() }
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

    init(localeIdentifier: String, onEvent: @escaping @MainActor (LocalVoiceEvent) -> Void) throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw LocalVoiceCaptureError(message: "On-device speech recognition is unavailable for this language.")
        }
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
                if let text { onEvent(.transcript(text, isFinal: isFinal)) }
                if let message { onEvent(.error(message)) }
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
        if cancel { task?.cancel() } else { task?.finish() }
        engine = nil
        request = nil
        task = nil
    }
}
