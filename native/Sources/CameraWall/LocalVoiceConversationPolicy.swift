import AVFoundation
import CameraCore
import Foundation
import Speech

/// Four distinct review execution outcomes required by ACTA voice/agent contracts.
enum LocalVoiceReviewOutcome: Equatable, Sendable {
    case executedVerified
    case executedUnverified
    case rejected
    case failed

    static func classify(result: ACTAActionResult, approved: Bool) -> LocalVoiceReviewOutcome {
        if !approved {
            return .rejected
        }
        if result.success {
            return result.verified ? .executedVerified : .executedUnverified
        }
        return .failed
    }
}

/// Sanitizes agent markdown responses before local offline TTS so eSpeak NG never reads raw markup,
/// code blocks, URLs, or local file paths aloud.
enum LocalVoiceSpeechSanitizer {
    static let maxUTF8Bytes = 8_000

    static func sanitize(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        // Replace fenced code blocks with a concise spoken placeholder
        text = replacingRegex(in: text, pattern: "```[\\s\\S]*?```", with: " ")
        // Replace markdown links [label](url) with just label
        text = replacingRegex(in: text, pattern: "\\[([^\\]]+)\\]\\([^\\)]+\\)", with: "$1")
        // Redact raw URLs (http/https/rtsp/file) so credentials/tokens/endpoints are never spoken
        text = replacingRegex(in: text, pattern: "(?i)\\b(?:https?|rtsp|rtsps|file)://\\S+", with: " ")
        // Strip inline code backticks, markdown bold/italic/heading/list markers
        text = text.replacingOccurrences(of: "`", with: "")
        text = replacingRegex(in: text, pattern: "(?m)^\\s{0,3}#{1,6}\\s+", with: "")
        text = replacingRegex(in: text, pattern: "(?m)^\\s*>\\s?", with: "")
        text = replacingRegex(in: text, pattern: "(?m)^\\s*[-*+]\\s+", with: "")
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "__", with: "")
        text = text.replacingOccurrences(of: "~~", with: "")
        // Strip invisible / zero-width / bidi control scalars
        text = stripControlScalars(text)
        // Collapse consecutive whitespace into single spaces
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return truncateUTF8(collapsed, maxBytes: maxUTF8Bytes)
    }

    private static func replacingRegex(in input: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return input }
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: template)
    }

    private static func stripControlScalars(_ input: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in input.unicodeScalars {
            switch scalar.value {
            case 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF:
                continue
            default:
                if scalar.properties.generalCategory == .control && scalar != "\n" && scalar != "\t" {
                    continue
                }
                out.append(scalar)
            }
        }
        return String(out)
    }

    private static func truncateUTF8(_ input: String, maxBytes: Int) -> String {
        guard input.utf8.count > maxBytes else { return input }
        var end = input.startIndex
        var bytes = 0
        for index in input.indices {
            let charBytes = input[index].utf8.count
            if bytes + charBytes > maxBytes { break }
            bytes += charBytes
            end = input.index(after: index)
        }
        return String(input[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Guards against accidental microphone taps and noise-only ASR transcripts before submitting
/// a voice utterance to the agent. Does NOT relax strict confirmation challenge matching.
enum LocalVoiceTranscriptGuard {
    enum Verdict: Equatable, Sendable {
        case accepted(String)
        case rejectedEmpty
        case rejectedAccidentalActivation
        case rejectedNoise
    }

    static let minimumActivationSeconds: TimeInterval = 0.25

    private static let fillerTokens: Set<String> = [
        "uh", "um", "hm", "m", "mhm", "ah", "er", "erm", "oh",
        "а", "э", "м", "гм", "хм", "угу", "ну", "ой",
        "אה", "אמ", "המ"
    ]

    private static func collapseRepeatedCharacters(_ word: String) -> String {
        var result = ""
        var previous: Character?
        for ch in word {
            if ch != previous {
                result.append(ch)
                previous = ch
            }
        }
        return result
    }

    static func evaluate(_ raw: String, durationSeconds: TimeInterval? = nil) -> Verdict {
        let stripped = stripInvisibleAndControl(raw)
        let normalized = stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty else { return .rejectedEmpty }

        // Extract meaningful letter/number tokens ignoring surrounding punctuation
        let tokens = normalized
            .split(whereSeparator: \.isWhitespace)
            .map { token -> String in
                String(token.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }).lowercased()
            }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return .rejectedNoise }

        if tokens.allSatisfy({ fillerTokens.contains($0) || fillerTokens.contains(collapseRepeatedCharacters($0)) }) {
            return .rejectedNoise
        }

        let alphanumericCount = tokens.reduce(0) { $0 + $1.count }
        if let durationSeconds, durationSeconds < minimumActivationSeconds, alphanumericCount < 3 {
            return .rejectedAccidentalActivation
        }
        if alphanumericCount < 2 {
            return .rejectedAccidentalActivation
        }

        return .accepted(String(normalized.prefix(2000)))
    }

    private static func stripInvisibleAndControl(_ input: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in input.unicodeScalars {
            switch scalar.value {
            case 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF:
                continue
            default:
                if scalar.properties.generalCategory == .control && scalar != " " && scalar != "\n" && scalar != "\t" {
                    continue
                }
                out.append(scalar)
            }
        }
        return String(out)
    }
}

/// Computes the operator-visible offline voice and permission status indicator for VLMPanel.
enum LocalVoiceStatusDescriptor: Equatable, Sendable {
    case disabledByPermission
    case microphoneDenied
    case speechDenied
    case listening
    case finalizing
    case speaking
    case readyOffline

    var localizationKey: String {
        switch self {
        case .disabledByPermission: return "Local voice disabled in permissions"
        case .microphoneDenied: return "Microphone permission denied"
        case .speechDenied: return "Speech recognition permission denied"
        case .listening: return "Listening locally (offline)"
        case .finalizing: return "Finalizing local dictation…"
        case .speaking: return "Speaking locally (offline)"
        case .readyOffline: return "On-device voice ready (offline)"
        }
    }

    var systemImage: String {
        switch self {
        case .disabledByPermission: return "mic.slash"
        case .microphoneDenied, .speechDenied: return "exclamationmark.triangle"
        case .listening: return "waveform.circle.fill"
        case .finalizing: return "ellipsis.circle"
        case .speaking: return "speaker.wave.2.fill"
        case .readyOffline: return "lock.shield"
        }
    }

    static func resolve(
        allowVoiceInput: Bool,
        isRecording: Bool,
        isFinalizing: Bool,
        isSpeaking: Bool,
        microphoneAuthorized: Bool = true,
        speechAuthorized: Bool = true
    ) -> LocalVoiceStatusDescriptor {
        guard allowVoiceInput else { return .disabledByPermission }
        if !microphoneAuthorized { return .microphoneDenied }
        if !speechAuthorized { return .speechDenied }
        if isFinalizing { return .finalizing }
        if isRecording { return .listening }
        if isSpeaking { return .speaking }
        return .readyOffline
    }

    @MainActor
    static func currentSystemPermissions() -> (microphoneNotDenied: Bool, speechNotDenied: Bool) {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let micOK = micStatus != .denied && micStatus != .restricted
        let speechOK = speechStatus != .denied && speechStatus != .restricted
        return (micOK, speechOK)
    }
}

/// Persistent storage abstraction for the operator's selected dictation language.
protocol LocalVoiceLanguageStorage: AnyObject {
    func readRawLanguage() -> String?
    func writeRawLanguage(_ rawValue: String)
}

final class UserDefaultsLocalVoiceLanguageStorage: LocalVoiceLanguageStorage {
    static let key = "ACTA.VoiceDictationLanguage"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func readRawLanguage() -> String? {
        defaults.string(forKey: Self.key)
    }

    func writeRawLanguage(_ rawValue: String) {
        defaults.set(rawValue, forKey: Self.key)
    }
}

final class InMemoryLocalVoiceLanguageStorage: LocalVoiceLanguageStorage {
    private var stored: String?
    init(initial: String? = nil) { self.stored = initial }
    func readRawLanguage() -> String? { stored }
    func writeRawLanguage(_ rawValue: String) { stored = rawValue }
}

/// Coordinates clean interruption (barge-in) between LocalVoiceOutput (TTS) and LocalVoiceInput (ASR)
/// so active speech releases LocalVoiceAudioLease before microphone capture starts.
@MainActor
final class LocalVoiceBargeInCoordinator {
    private var generation = UUID()
    private(set) var hasPendingBargeIn = false

    func cancelPending() {
        generation = UUID()
        hasPendingBargeIn = false
    }

    /// Stops any active speech output and starts local dictation as soon as the audio lease is released.
    /// Returns immediately if speech is already idle.
    func bargeInToDictation(
        voiceOutput: LocalVoiceOutput,
        voiceInput: LocalVoiceInput,
        localeIdentifier: String,
        owner: UUID,
        onBeforeStart: (@MainActor () -> Void)? = nil,
        onStarted: (@MainActor (Bool) -> Void)? = nil
    ) {
        let token = UUID()
        generation = token
        guard voiceInput.isInputAllowed else {
            hasPendingBargeIn = false
            onStarted?(false)
            return
        }
        if !voiceOutput.isAttemptActive {
            hasPendingBargeIn = false
            onBeforeStart?()
            let started = voiceInput.start(localeIdentifier: localeIdentifier, owner: owner) != nil
            onStarted?(started)
            return
        }
        hasPendingBargeIn = true
        voiceOutput.stopAndNotifyWhenIdle { [weak self, weak voiceInput] in
            guard let self, self.generation == token else { return }
            self.hasPendingBargeIn = false
            guard let voiceInput, voiceInput.isInputAllowed, !voiceInput.isAttemptActive else {
                onStarted?(false)
                return
            }
            onBeforeStart?()
            let started = voiceInput.start(localeIdentifier: localeIdentifier, owner: owner) != nil
            onStarted?(started)
        }
    }
}
