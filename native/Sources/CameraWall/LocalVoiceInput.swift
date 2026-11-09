import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class LocalVoiceInput: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var transcript = ""
    @Published private(set) var errorMessage: String?

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    func start(localeIdentifier: String) async {
        guard !isRecording else { return }
        transcript = ""
        errorMessage = nil

        let speechAuthorization = await requestSpeechAuthorization()
        guard speechAuthorization == .authorized else {
            errorMessage = "Speech recognition permission is required for local dictation."
            return
        }
        guard await requestMicrophoneAccess() else {
            errorMessage = "Microphone permission is required for local dictation."
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            errorMessage = "On-device speech recognition is unavailable for this language."
            return
        }

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            errorMessage = "The selected microphone has no audio input."
            return
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
            errorMessage = "Could not install the microphone input tap."
            return
        }

        audioEngine = engine
        recognitionRequest = request
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal { self.finishRecognition() }
                }
                if let error, self.isRecording {
                    self.errorMessage = error.localizedDescription
                    self.finishRecognition()
                }
            }
        }

        engine.prepare()
        do {
            try engine.start()
            isRecording = true
        } catch {
            input.removeTap(onBus: 0)
            recognitionTask?.cancel()
            audioEngine = nil
            recognitionRequest = nil
            recognitionTask = nil
            errorMessage = "Could not start the microphone. Check its permission and input device."
        }
    }

    func stop() {
        guard isRecording else { return }
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        audioEngine = nil
        recognitionRequest = nil
        isRecording = false
    }

    func cancel() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
    }

    nonisolated static func mergeTranscript(_ transcript: String, with draft: String) -> String {
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return String(draft.prefix(2000)) }
        let prefix = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = prefix.isEmpty ? spoken : "\(prefix) \(spoken)"
        return String(combined.prefix(2000))
    }

    private func finishRecognition() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private func requestMicrophoneAccess() async -> Bool {
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